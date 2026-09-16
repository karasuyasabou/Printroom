import CryptoKit
import Foundation
import XCTest
@testable import PrintroomCore

private final class RAWFixture: @unchecked Sendable {
  let lock = NSLock()
  var digestBytes: [String: Int] = [:]
  var maintenanceRuns = 0
  var conversions = 0
  var decodes = 0
  var active = 0
  var peakActive = 0
  var blocked = false
  var blockedSources: Set<String> = []
  var cancelledProducer = false
  var adobeVersion = "test-adobe-1"
  var failure: String?
  let image = LinearImage(width: 3202, height: 11,
    samples: (0..<(3202 * 11 * 3)).map { UInt16($0 % 65536) })
  func update(_ action: (RAWFixture) -> Void) { lock.lock(); defer { lock.unlock() }; action(self) }
  func count() -> Int { lock.lock(); defer { lock.unlock() }; return conversions }
  func dependencies() -> RAWSourceDependencies {
    RAWSourceDependencies(installation: { [self] in
      lock.lock(); defer { lock.unlock() }
      if failure == "missing" { throw PrintroomError.invalid("Adobe missing") }
      return AdobeRAWInstallation(executable: URL(fileURLWithPath: "/unused"), version: adobeVersion)
    }, convert: { [self] _, source, destination, cancelled in
      update { $0.conversions += 1; $0.active += 1; $0.peakActive = max($0.peakActive, $0.active) }
      defer { update { $0.active -= 1 } }
      while true {
        lock.lock(); let waiting = blocked || blockedSources.contains(source.lastPathComponent); let fail = failure; lock.unlock()
        if cancelled() {
          update { $0.cancelledProducer = true }
          throw CancellationError()
        }
        if !waiting {
          if fail == "convert" { throw PrintroomError.invalid("Adobe conversion failed") }
          if fail == "mutate" { try Data("changed raw".utf8).write(to: source) }
          try Data((fail == "cfa" ? "CFA" : "LINEAR").utf8).write(to: destination)
          return
        }
        Thread.sleep(forTimeInterval: 0.005)
      }
    }, decode: { [self] _, cancelled in
      if cancelled() { throw CancellationError() }
      update { $0.decodes += 1 }
      return image
    }, inspect: { [self] url in
      guard try Data(contentsOf: url) == Data("LINEAR".utf8) else {
        throw PrintroomError.invalid("Not Linear DNG")
      }
      return (image.width, image.height)
    }, didMaintain: { [self] in update { $0.maintenanceRuns += 1 } }, didReadDigest: { [self] url, bytes in
      update { $0.digestBytes[url.path, default: 0] += bytes }
    }, libRawVersion: "test-libraw")
  }
}

final class RAWSourceServiceTests: XCTestCase, @unchecked Sendable {
  private func fixture() throws -> (URL, URL, RAWFixture, RAWSourceService) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("raw-service-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("negative.ARW")
    try Data("original RAW".utf8).write(to: source)
    let backend = RAWFixture()
    let service = RAWSourceService(cacheRoot: directory.appendingPathComponent("cache"),
                                  byteLimit: 1_000_000_000, dependencies: backend.dependencies())
    addTeardownBlock { service.waitForMaintenance() }
    return (directory, source, backend, service)
  }
  private func waitForStart(_ backend: RAWFixture) async throws {
    for _ in 0..<200 {
      if backend.count() > 0 { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("Producer never started")
  }
  func testFreshServiceUsesDiskProxyWithoutReadingRAWContent() throws {
    let (directory, source, backend, service) = try fixture()
    try Data(repeating: 123, count: 64 * 1024 * 1024).write(to: source)
    let expected = try service.preview(url: source)
    service.waitForMaintenance()
    XCTAssertEqual(backend.lock.withLock { backend.digestBytes[source.path] }, 64 * 1024 * 1024)
    backend.update { $0.digestBytes.removeAll() }
    let restarted = RAWSourceService(cacheRoot: directory.appendingPathComponent("cache"),
      byteLimit: 1_000_000_000, dependencies: backend.dependencies())
    defer { restarted.waitForMaintenance() }
    let start = Date()
    XCTAssertEqual(try restarted.preview(url: source).samples, expected.samples)
    print("RAW cached fresh-service preview: \(Date().timeIntervalSince(start)) seconds; source bytes: 0")
    XCTAssertEqual(backend.lock.withLock { backend.digestBytes[source.path, default: 0] }, 0)
    XCTAssertGreaterThan(backend.lock.withLock { backend.digestBytes.values.reduce(0, +) }, 0,
      "Proxy integrity must still be checked after restart")
    XCTAssertEqual(backend.count(), 1)
  }

  func testLegacyContentKeyMigratesWithoutReadingRAWOrConverting() throws {
    let (directory, source, backend, service) = try fixture()
    let expected = try service.preview(url: source)
    service.waitForMaintenance()
    let cache = directory.appendingPathComponent("cache")
    let path = try XCTUnwrap(FileManager.default.subpathsOfDirectory(atPath: cache.path)
      .first { $0.hasSuffix("manifest.json") })
    let manifestURL = cache.appendingPathComponent(path)
    let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
    let identity = try XCTUnwrap(manifest["identity"] as? [String: String])
    let fields = [identity["sourceRevision"]!, manifest["sourceSHA256"] as! String,
      identity["adobeVersion"]!, identity["libRawVersion"]!, identity["strategyVersion"]!, identity["proxySamplingVersion"]!]
    let oldKey = SHA256.hash(data: Data(fields.joined(separator: "\n").utf8))
      .map { String(format: "%02x", $0) }.joined()
    let legacy = cache.appendingPathComponent(oldKey)
    try FileManager.default.moveItem(at: manifestURL.deletingLastPathComponent(), to: legacy)
    backend.update { $0.digestBytes.removeAll() }
    for _ in 0..<2 {
      let restarted = RAWSourceService(cacheRoot: cache, byteLimit: 1_000_000_000,
        dependencies: backend.dependencies())
      XCTAssertEqual(try restarted.preview(url: source).samples, expected.samples)
      restarted.waitForMaintenance()
      XCTAssertEqual(backend.lock.withLock { backend.digestBytes[source.path, default: 0] }, 0)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    XCTAssertEqual(backend.count(), 1)
  }

  func testSameSizeMutationWithRestoredMtimeInvalidatesAfterRestart() throws {
    let (directory, source, backend, service) = try fixture()
    let originalIdentity = try service.identity(url: source)
    let modified = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate] as? Date)
    _ = try service.preview(url: source)
    service.waitForMaintenance()
    try Data("modified RAW".utf8).write(to: source)
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: source.path)
    let restarted = RAWSourceService(cacheRoot: directory.appendingPathComponent("cache"),
      byteLimit: 1_000_000_000, dependencies: backend.dependencies())
    defer { restarted.waitForMaintenance() }
    XCTAssertNotEqual(try restarted.identity(url: source), originalIdentity)
    XCTAssertThrowsError(try restarted.preview(url: source, expectedIdentity: originalIdentity))
    _ = try restarted.preview(url: source)
    XCTAssertEqual(backend.count(), 2)
  }

  func testCacheHitsDoNotScheduleGlobalMaintenance() throws {
    let (_, source, backend, service) = try fixture()
    _ = try service.preview(url: source)
    service.waitForMaintenance()
    let initial = backend.lock.withLock { backend.maintenanceRuns }
    XCTAssertGreaterThan(initial, 0, "New proxies must request maintenance")
    for _ in 0..<3 {
      _ = try service.metadata(url: source)
      _ = try service.preview(url: source)
      _ = try service.preview(url: source, maxDimension: 240)
    }
    service.waitForMaintenance()
    XCTAssertEqual(backend.lock.withLock { backend.maintenanceRuns }, initial)
    service.scheduleMaintenance()
    service.waitForMaintenance()
    XCTAssertEqual(backend.lock.withLock { backend.maintenanceRuns }, initial + 1)
  }

  func testProxyFullRegionAndFrozenIdentity() throws {
    let (directory, source, backend, service) = try fixture()
    let identity = try service.identity(url: source)
    XCTAssertEqual(backend.count(), 0, "Identity must never convert")
    let preview = try service.preview(url: source)
    XCTAssertEqual(preview.width, 1600)
    XCTAssertEqual(preview.height, 5)
    XCTAssertEqual(backend.count(), 1)
    let thumbnail = try service.preview(url: source, maxDimension: 240)
    XCTAssertEqual(thumbnail.width, 240)
    XCTAssertFalse(try FileManager.default.subpathsOfDirectory(atPath: directory.path).contains { $0.hasSuffix("full.tiff") })
    let full = try service.read(url: source, expectedIdentity: identity)
    XCTAssertEqual(full.samples, backend.image.samples)
    for y in 0..<preview.height {
      for x in 0..<preview.width {
        XCTAssertEqual(preview.pixel(x: x, y: y), full.pixel(x: x * full.width / preview.width, y: y * full.height / preview.height))
      }
    }
    let region = try service.region(url: source, rect: PixelRect(x: 51, y: 2, width: 11, height: 7))
    XCTAssertEqual(region.pixel(x: 4, y: 3), preview.pixel(x: 55 * preview.width / full.width, y: 5 * preview.height / full.height))
    XCTAssertEqual(backend.count(), 2)
    _ = try service.preview(url: source, maxDimension: 3200)
    _ = try service.preview(url: source, maxDimension: 800)
    XCTAssertEqual(backend.count(), 2, "Every editing size must use cached proxies")
    let paths = try FileManager.default.subpathsOfDirectory(atPath: directory.path)
    XCTAssertFalse(paths.contains { $0.hasSuffix("source.dng") || $0.hasSuffix("full.tiff") || $0.contains(".preparing-") })
    backend.update { $0.adobeVersion = "test-adobe-2" }
    XCTAssertThrowsError(try service.read(url: source, expectedIdentity: identity))
    _ = try service.preview(url: source)
    XCTAssertEqual(backend.count(), 3)
  }
  func testLegacyLargeFilesAreRemovedWithoutRebuildingProxies() throws {
    let (directory, source, backend, service) = try fixture()
    let expected = try service.preview(url: source)
    service.waitForMaintenance()
    let path = try XCTUnwrap(FileManager.default.subpathsOfDirectory(atPath: directory.path).first { $0.hasSuffix("manifest.json") })
    let entry = directory.appendingPathComponent(path).deletingLastPathComponent()
    for name in ["source.dng", "full.tiff", "user-note.txt"] {
      try Data("legacy".utf8).write(to: entry.appendingPathComponent(name))
    }
    XCTAssertEqual(try service.preview(url: source).samples, expected.samples)
    XCTAssertEqual(backend.count(), 1)
    service.scheduleMaintenance() // Startup/hourly maintenance retires old large files.
    service.waitForMaintenance()
    XCTAssertFalse(FileManager.default.fileExists(atPath: entry.appendingPathComponent("source.dng").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: entry.appendingPathComponent("full.tiff").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: entry.appendingPathComponent("user-note.txt").path))
  }

  func testFailedExportKeepsProxyAndRemovesTemporaryDNG() throws {
    let (directory, source, backend, service) = try fixture()
    let proxy = try service.preview(url: source)
    backend.update { $0.failure = "convert" }
    XCTAssertThrowsError(try service.read(url: source))
    XCTAssertEqual(try service.preview(url: source).samples, proxy.samples)
    let paths = try FileManager.default.subpathsOfDirectory(atPath: directory.path)
    XCTAssertFalse(paths.contains { $0.hasSuffix("source.dng") || $0.hasSuffix("full.tiff") || $0.contains(".preparing-") })
  }

  func testColdExportConvertsOnlyOnceAndLeavesNoImageCache() throws {
    let (directory, source, backend, service) = try fixture()
    XCTAssertEqual(try service.read(url: source).samples, backend.image.samples)
    XCTAssertEqual(backend.count(), 1)
    let paths = try FileManager.default.subpathsOfDirectory(atPath: directory.path)
    XCTAssertFalse(paths.contains { $0.hasSuffix(".dng") || $0.hasSuffix(".tiff") || $0.contains(".preparing-") })
  }

  func testFailuresNeverFallbackOrPublish() throws {
    for failure in ["missing", "convert", "cfa", "mutate"] {
      let (directory, source, backend, service) = try fixture()
      backend.update { $0.failure = failure }
      XCTAssertThrowsError(try service.preview(url: source), failure)
      if failure != "mutate" { XCTAssertEqual(try Data(contentsOf: source), Data("original RAW".utf8)) }
      let paths = try FileManager.default.subpathsOfDirectory(atPath: directory.path)
      XCTAssertFalse(paths.contains { $0.hasSuffix("manifest.json") || $0.contains(".preparing-") }, failure)
      backend.lock.lock(); let decodes = backend.decodes; backend.lock.unlock()
      if failure != "mutate" { XCTAssertEqual(decodes, 0, failure) }
    }
  }
  func testCorruptedProxyRebuildAndCacheLimit() throws {
    let (directory, source, backend, service) = try fixture()
    _ = try service.preview(url: source)
    let path = try XCTUnwrap(FileManager.default.subpathsOfDirectory(atPath: directory.path).first { $0.hasSuffix("proxy.tiff") })
    try Data("bad proxy".utf8).write(to: directory.appendingPathComponent(path))
    _ = try service.preview(url: source)
    XCTAssertEqual(backend.count(), 2)
    let bounded = RAWSourceService(cacheRoot: directory.appendingPathComponent("cache"), byteLimit: 0,
                                   dependencies: backend.dependencies())
    _ = try bounded.preview(url: source)
    bounded.scheduleMaintenance() // A changed capacity policy explicitly requests maintenance.
    bounded.waitForMaintenance()
    XCTAssertFalse(try FileManager.default.subpathsOfDirectory(atPath: directory.path).contains { $0.hasSuffix("manifest.json") })
  }
  func testOneCancelledConsumerKeepsSharedPreparation() async throws {
    let (_, source, backend, service) = try fixture()
    backend.update { $0.blocked = true }
    let first = Task.detached { try service.preview(url: source) }
    try await waitForStart(backend)
    let second = Task.detached { try service.preview(url: source) }
    try await Task.sleep(for: .milliseconds(75))
    first.cancel()
    do { _ = try await first.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("\(error)") }
    backend.update { $0.blocked = false }
    let image = try await second.value
    XCTAssertEqual(image.width, 1600)
    XCTAssertEqual(backend.count(), 1)
  }
  func testLastConsumerCancelsProducerAndRetryWorks() async throws {
    let (directory, source, backend, service) = try fixture()
    backend.update { $0.blocked = true }
    let task = Task.detached { try service.preview(url: source) }
    try await waitForStart(backend)
    task.cancel()
    do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("\(error)") }
    for _ in 0..<100 {
      let done = backend.lock.withLock { backend.cancelledProducer }
      if done { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    backend.update { XCTAssertTrue($0.cancelledProducer); $0.blocked = false }
    _ = try service.preview(url: source)
    XCTAssertEqual(backend.count(), 2)
    XCTAssertFalse(try FileManager.default.subpathsOfDirectory(atPath: directory.path).contains { $0.contains(".preparing-") })
  }
  func testCacheRootSymlinkAndUnwritablePathAreRejected() throws {
    let (directory, source, backend, _) = try fixture()
    let target = directory.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    let link = directory.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    let unsafe = RAWSourceService(cacheRoot: link, byteLimit: 100, dependencies: backend.dependencies())
    XCTAssertThrowsError(try unsafe.preview(url: source))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [])
    let invalid = RAWSourceService(cacheRoot: source.appendingPathComponent("cache"), byteLimit: 100, dependencies: backend.dependencies())
    XCTAssertThrowsError(try invalid.preview(url: source))
    XCTAssertEqual(backend.count(), 0)
  }
  func testIndependentServicesSerializeAndReusePublishedCache() async throws {
    let (directory, source, backend, service) = try fixture()
    backend.update { $0.blocked = true }
    let another = RAWSourceService(cacheRoot: directory.appendingPathComponent("cache"), byteLimit: 1_000_000_000,
                                   dependencies: backend.dependencies())
    let first = Task.detached { try service.preview(url: source) }
    try await waitForStart(backend)
    let second = Task.detached { try another.preview(url: source) }
    try await Task.sleep(for: .milliseconds(50))
    backend.update { $0.blocked = false }
    _ = try await first.value
    _ = try await second.value
    XCTAssertEqual(backend.count(), 1)
  }
  func testClearCachePreservesUnownedFilesAndRebuilds() throws {
    let (directory, source, backend, service) = try fixture()
    _ = try service.preview(url: source)
    let marker = directory.appendingPathComponent("cache/user-note.txt")
    try Data("keep".utf8).write(to: marker)
    try service.clearCache()
    XCTAssertEqual(try Data(contentsOf: marker), Data("keep".utf8))
    XCTAssertEqual(try Data(contentsOf: source), Data("original RAW".utf8))
    XCTAssertFalse(try FileManager.default.subpathsOfDirectory(atPath: directory.path).contains { $0.hasSuffix("manifest.json") })
    _ = try service.preview(url: source)
    XCTAssertEqual(backend.count(), 2)
  }
  func testAdobeRunnerNonzeroMissingOutputAndCancellation() async throws {
    let (directory, source, _, _) = try fixture()
    let contents = directory.appendingPathComponent("Fixture.app/Contents")
    try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
    let script = contents.appendingPathComponent("MacOS/converter")
    let info: [String: Any] = ["CFBundleExecutable": "converter", "CFBundleIdentifier": "studio.printroom.test-adobe", "CFBundlePackageType": "APPL"]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
      .write(to: contents.appendingPathComponent("Info.plist"))
    let destination = directory.appendingPathComponent("source.dng")
    let install = AdobeRAWInstallation(executable: script, version: "fixture")
    for text in ["#!/bin/sh\nexit 7\n", "#!/bin/sh\nexit 0\n"] {
      try Data(text.utf8).write(to: script)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
      XCTAssertThrowsError(try RAWSourceService.convert(install, source: source, destination: destination, cancelled: { false }))
    }
    try Data("#!/bin/sh\nwhile :; do :; done\n".utf8).write(to: script)
    let cancellation = RAWFixture()
    let running = Task.detached {
      try RAWSourceService.convert(install, source: source, destination: destination,
                                 cancelled: { cancellation.lock.withLock { cancellation.blocked } })
    }
    try await Task.sleep(for: .milliseconds(50))
    cancellation.update { $0.blocked = true }
    do { try await running.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("\(error)") }
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("adobe.log").path))
  }

  func testCrashStagingRecoveryDeletesOnlyOwnedUUIDDirectories() throws {
    let (directory, source, _, service) = try fixture()
    let fm = FileManager.default
    let cache = directory.appendingPathComponent("cache")
    try fm.createDirectory(at: cache, withIntermediateDirectories: false)
    let stale = cache.appendingPathComponent(".preparing-\(UUID().uuidString)")
    try fm.createDirectory(at: stale, withIntermediateDirectories: false)
    try Data("interrupted Adobe DNG".utf8).write(to: stale.appendingPathComponent("source.dng"))
    let unrelated = cache.appendingPathComponent(".preparing-not-a-uuid")
    try fm.createDirectory(at: unrelated, withIntermediateDirectories: false)
    let regularFile = cache.appendingPathComponent(".preparing-\(UUID().uuidString)")
    try Data("keep file".utf8).write(to: regularFile)
    let outside = directory.appendingPathComponent("outside")
    try fm.createDirectory(at: outside, withIntermediateDirectories: false)
    let marker = outside.appendingPathComponent("keep.txt")
    try Data("keep target".utf8).write(to: marker)
    let link = cache.appendingPathComponent(".preparing-\(UUID().uuidString)")
    try fm.createSymbolicLink(at: link, withDestinationURL: outside)
    _ = try service.preview(url: source)
    service.waitForMaintenance()
    XCTAssertFalse(fm.fileExists(atPath: stale.path))
    XCTAssertTrue(fm.fileExists(atPath: unrelated.path))
    XCTAssertEqual(try Data(contentsOf: regularFile), Data("keep file".utf8))
    XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), outside.path)
    XCTAssertEqual(try Data(contentsOf: marker), Data("keep target".utf8))
    XCTAssertEqual(try Data(contentsOf: source), Data("original RAW".utf8))
  }

  private func sources(in directory: URL, count: Int) throws -> [URL] {
    try (0..<count).map { index in
      let url = directory.appendingPathComponent("parallel-\(index).ARW")
      try Data("original RAW \(index)".utf8).write(to: url)
      return url
    }
  }
  private func waitForFour(_ backend: RAWFixture) async throws {
    for _ in 0..<400 {
      if backend.count() >= 4 { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("Four distinct sources did not prepare concurrently")
  }

  func testEightSourcesUseExactlyFourSlotsAndTinyCacheDrains() async throws {
    let (directory, _, backend, _) = try fixture()
    let service = RAWSourceService(cacheRoot: directory.appendingPathComponent("cache"), byteLimit: 1,
                                   dependencies: backend.dependencies())
    let inputs = try sources(in: directory, count: 8)
    backend.update { $0.blocked = true }
    let tasks = inputs.map { input in Task.detached { try service.preview(url: input) } }
    try await waitForFour(backend)
    try await Task.sleep(for: .milliseconds(75))
    XCTAssertEqual(backend.count(), 4)
    backend.update { XCTAssertEqual($0.peakActive, 4); $0.blocked = false }
    for task in tasks { let image = try await task.value; XCTAssertEqual(image.width, 1600) }
    XCTAssertEqual(backend.count(), 8)
    backend.update { XCTAssertEqual($0.peakActive, 4); XCTAssertEqual($0.active, 0) }
    service.waitForMaintenance()
    let paths = try FileManager.default.subpathsOfDirectory(atPath: directory.path)
    XCTAssertFalse(paths.contains { $0.hasSuffix("manifest.json") || $0.contains(".preparing-") })
  }

  func testMixedSameSourceConsumersDoNotOccupyOtherSlots() async throws {
    let (directory, source, backend, service) = try fixture()
    let others = try sources(in: directory, count: 3)
    backend.update { $0.blocked = true }
    let metadata = Task.detached { try service.metadata(url: source) }
    try await waitForStart(backend)
    let thumbnail = Task.detached { try service.preview(url: source, maxDimension: 240) }
    let full = Task.detached { try service.read(url: source) }
    let tasks = others.map { input in Task.detached { try service.preview(url: input) } }
    try await waitForFour(backend)
    backend.update { XCTAssertEqual($0.peakActive, 4); $0.blocked = false }
    let metadataValue = try await metadata.value
    XCTAssertEqual(metadataValue.width, 3202)
    let thumbnailValue = try await thumbnail.value
    XCTAssertEqual(thumbnailValue.width, 240)
    let fullValue = try await full.value
    XCTAssertEqual(fullValue.samples, backend.image.samples)
    for task in tasks { _ = try await task.value }
    XCTAssertEqual(backend.count(), 5, "Editing shares preparation; export performs one fresh full decode")
  }

  func testClearCacheWaitsForFourActiveSourcesWithoutDeletingStages() async throws {
    let (directory, _, backend, service) = try fixture()
    let inputs = try sources(in: directory, count: 4)
    backend.update { $0.blocked = true }
    let tasks = inputs.map { input in Task.detached { try service.preview(url: input) } }
    try await waitForFour(backend)
    let clearing = Task.detached { try service.clearCache() }
    try await Task.sleep(for: .milliseconds(75))
    let activeStages = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("cache").path)
      .filter { $0.hasPrefix(".preparing-") }
    XCTAssertEqual(activeStages.count, 4, "Clearing must not remove active conversion directories")
    backend.update { $0.blocked = false }
    for task in tasks { let image = try await task.value; XCTAssertEqual(image.width, 1600) }
    try await clearing.value
    XCTAssertFalse(try FileManager.default.subpathsOfDirectory(atPath: directory.path).contains { $0.hasSuffix("manifest.json") })
  }

  func testCancelledSlotWaiterDoesNotStartOrLeakSlot() async throws {
    let (directory, _, backend, service) = try fixture()
    let inputs = try sources(in: directory, count: 5)
    backend.update { $0.blocked = true }
    let tasks = inputs.prefix(4).map { input in Task.detached { try service.preview(url: input) } }
    try await waitForFour(backend)
    let queued = Task.detached { try service.preview(url: inputs[4]) }
    try await Task.sleep(for: .milliseconds(50))
    queued.cancel()
    do { _ = try await queued.value; XCTFail("Expected cancelled slot waiter") }
    catch is CancellationError {} catch { XCTFail("\(error)") }
    XCTAssertEqual(backend.count(), 4)
    backend.update { $0.blocked = false }
    for task in tasks { _ = try await task.value }
    _ = try service.preview(url: inputs[4])
    XCTAssertEqual(backend.count(), 5)
  }

  func testSlotLimitIsSharedAcrossIndependentServiceInstances() async throws {
    let (directory, _, backend, first) = try fixture()
    let second = RAWSourceService(cacheRoot: directory.appendingPathComponent("cache"), byteLimit: 1_000_000_000,
                                 dependencies: backend.dependencies())
    let inputs = try sources(in: directory, count: 8)
    backend.update { $0.blocked = true }
    let tasks = inputs.enumerated().map { index, input in
      Task.detached { try (index.isMultiple(of: 2) ? first : second).preview(url: input) }
    }
    try await waitForFour(backend)
    try await Task.sleep(for: .milliseconds(75))
    XCTAssertEqual(backend.count(), 4)
    backend.update { $0.blocked = false }
    for task in tasks { _ = try await task.value }
    backend.update { XCTAssertEqual($0.peakActive, 4) }
    XCTAssertEqual(backend.count(), 8)
  }

  func testCompletedSourcesReturnAndReuseSlotsWhileAnotherServiceIsStillConverting() async throws {
    let (directory, slowSource, backend, slowService) = try fixture()
    let fastService = RAWSourceService(cacheRoot: directory.appendingPathComponent("cache"),
      byteLimit: 1, dependencies: backend.dependencies())
    backend.update { $0.blockedSources.insert(slowSource.lastPathComponent) }
    let slow = Task.detached { try slowService.preview(url: slowSource) }
    try await waitForStart(backend)
    let inputs = try sources(in: directory, count: 6)
    let returned = expectation(description: "Six sources return before the slow source releases its shared lock")
    let fast = Task.detached {
      for input in inputs { _ = try fastService.preview(url: input) }
      returned.fulfill()
    }
    await fulfillment(of: [returned], timeout: 3)
    let stages = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("cache").path)
      .filter { $0.hasPrefix(".preparing-") }
    XCTAssertEqual(stages.count, 1, "Maintenance must preserve the other service's active stage")
    backend.update { $0.blockedSources.removeAll() }
    _ = try await slow.value
    try await fast.value
    slowService.waitForMaintenance()
    fastService.waitForMaintenance()
    XCTAssertEqual(backend.count(), 7)
    XCTAssertFalse(try FileManager.default.subpathsOfDirectory(atPath: directory.path).contains {
      $0.hasSuffix("manifest.json") || $0.contains(".preparing-")
    }, "Deferred maintenance must drain the tiny cache once readers finish")
  }

}
