import Foundation
import XCTest
@testable import PrintroomCore

final class TIFFProxyServiceTests: XCTestCase, @unchecked Sendable {
  private final class Reads: @unchecked Sendable {
    let lock = NSLock()
    var dimensions: [Int] = []
    func record(_ dimension: Int) { lock.withLock { dimensions.append(dimension) } }
    var values: [Int] { lock.withLock { dimensions } }
  }
  private func fixture() throws -> (URL, URL) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TIFFProxy-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("source.tiff")
    try write(url)
    return (folder, url)
  }
  private func write(_ url: URL, offset: Int = 0, compression: TIFFCompression = .deflate) throws {
    // Odd dimensions expose double resampling of the thumbnail grid.
    let width = 1703, height = 347
    try TIFFCodec.write(url: url, width: width, height: height, profile: Data([0]), compression: compression) { rows in
      (rows.lowerBound * width * 3..<rows.upperBound * width * 3).map {
        UInt16(($0 * 173 + offset) % 65536)
      }
    }
  }
  private func dependencies(_ reads: Reads) -> SourceProxyDependencies {
    var value = SourceProxyDependencies()
    value.installation = { throw PrintroomError.invalid("TIFF must not invoke Adobe") }
    value.readTIFFPreview = { url, dimension, cancelled in
      reads.record(dimension)
      return try TIFFCodec.readPreview(url: url, maxDimension: dimension, cancelled: cancelled)
    }
    return value
  }

  func testBothGridsMatchOriginalUInt16AndWarmRestartDoesNotDecodeOriginal() throws {
    let (folder, url) = try fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let original = try Data(contentsOf: url), reads = Reads()
    let cache = folder.appendingPathComponent("cache")
    let service = SourceProxyService(cacheRoot: cache, byteLimit: 1_000_000_000, dependencies: dependencies(reads))
    let metadata = try service.metadata(url: url)
    XCTAssertEqual(metadata.width, 1703)
    XCTAssertEqual(metadata.height, 347)
    XCTAssertEqual(reads.values, [1600, 240])
    let restarted = SourceProxyService(cacheRoot: cache, byteLimit: 1_000_000_000, dependencies: dependencies(reads))
    for dimension in [1600, 240] {
      let expected = try TIFFCodec.readPreview(url: url, maxDimension: dimension)
      let actual = try restarted.preview(url: url, maxDimension: dimension)
      XCTAssertEqual(actual.width, expected.width)
      XCTAssertEqual(actual.height, expected.height)
      XCTAssertEqual(actual.samples, expected.samples)
    }
    XCTAssertEqual(reads.values, [1600, 240])
    XCTAssertEqual(try Data(contentsOf: url), original)
    service.waitForMaintenance()
    restarted.waitForMaintenance()
  }

  func testCorruptProxyRebuildsAndSourceRevisionInvalidates() throws {
    let (folder, url) = try fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let reads = Reads(), cache = folder.appendingPathComponent("cache")
    let service = SourceProxyService(cacheRoot: cache, byteLimit: 1_000_000_000, dependencies: dependencies(reads))
    let first = try service.preview(url: url)
    service.waitForMaintenance()
    let entry = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)
      .first { $0.lastPathComponent.count == 64 })
    try Data([1, 2, 3]).write(to: entry.appendingPathComponent("proxy.tiff"), options: .atomic)
    XCTAssertEqual(try service.preview(url: url).samples, first.samples)
    XCTAssertEqual(reads.values.count, 4)
    try FileManager.default.removeItem(at: url)
    try write(url, offset: 100)
    let changed = try service.preview(url: url)
    XCTAssertNotEqual(changed.samples, first.samples)
    XCTAssertEqual(changed.samples, try TIFFCodec.readPreview(url: url, maxDimension: 1600).samples)
    XCTAssertEqual(reads.values.count, 6)
    service.waitForMaintenance()
  }

  func testConcurrentMetadataAndPreviewSharePreparation() async throws {
    let (folder, url) = try fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let reads = Reads()
    let service = SourceProxyService(cacheRoot: folder.appendingPathComponent("cache"), byteLimit: 1_000_000_000,
      dependencies: dependencies(reads))
    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<8 {
        group.addTask {
          _ = try index % 2 == 0 ? service.metadata(url: url).width : service.preview(url: url).width
        }
      }
      try await group.waitForAll()
    }
    XCTAssertEqual(reads.values, [1600, 240])
    service.waitForMaintenance()
  }

  func testTIFFReplacementWithSameSizeAndMtimeStillInvalidatesByInode() throws {
    let (folder, url) = try fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.removeItem(at: url)
    try write(url, compression: .none)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: url.path)
    let before = try FileManager.default.attributesOfItem(atPath: url.path)
    let reads = Reads()
    let service = SourceProxyService(cacheRoot: folder.appendingPathComponent("cache"), byteLimit: 1_000_000_000,
      dependencies: dependencies(reads))
    let first = try service.preview(url: url)
    let replacement = folder.appendingPathComponent("replacement.tiff")
    try write(replacement, offset: 300, compression: .none)
    try FileManager.default.setAttributes([.modificationDate: before[.modificationDate]!], ofItemAtPath: replacement.path)
    try FileManager.default.removeItem(at: url)
    try FileManager.default.moveItem(at: replacement, to: url)
    let after = try FileManager.default.attributesOfItem(atPath: url.path)
    XCTAssertEqual(before[.size] as? NSNumber, after[.size] as? NSNumber)
    XCTAssertEqual(before[.modificationDate] as? Date, after[.modificationDate] as? Date)
    XCTAssertNotEqual(before[.systemFileNumber] as? NSNumber, after[.systemFileNumber] as? NSNumber)
    XCTAssertNotEqual(try service.preview(url: url).samples, first.samples)
    XCTAssertEqual(reads.values.count, 4)
    service.waitForMaintenance()
  }

  func testCancelledTIFFPreparationDoesNotPublishPartialEntry() async throws {
    let (folder, url) = try fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let reads = Reads(), cache = folder.appendingPathComponent("cache")
    var configuration = dependencies(reads)
    configuration.readTIFFPreview = { _, dimension, cancelled in
      reads.record(dimension)
      while !cancelled() { Thread.sleep(forTimeInterval: 0.005) }
      throw CancellationError()
    }
    let service = SourceProxyService(cacheRoot: cache, byteLimit: 1_000_000_000, dependencies: configuration)
    let task = Task.detached { try service.metadata(url: url) }
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while reads.values.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertFalse(reads.values.isEmpty)
    task.cancel()
    do { _ = try await task.value; XCTFail("Cancelled preparation returned metadata") }
    catch is CancellationError { }
    // Maintenance waits for the worker's shared lock and removes abandoned staging.
    service.scheduleMaintenance()
    service.waitForMaintenance()
    XCTAssertFalse(try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)
      .contains { $0.lastPathComponent.count == 64 || $0.lastPathComponent.hasPrefix(".preparing-") })
  }
}
