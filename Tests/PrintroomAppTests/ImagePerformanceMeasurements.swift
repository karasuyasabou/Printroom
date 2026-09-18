import Darwin
import Foundation
import PrintroomCore
import Testing

@testable import PrintroomApp

/// Opt-in local measurement, never part of a timing-sensitive correctness gate.
/// Run each mode in a fresh process using scripts/measure-performance.sh.
@Suite(.serialized)
struct ImagePerformanceMeasurements {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["PRINTROOM_PERFORMANCE"] == "1"))
  func measureReferenceWorkflow() async throws {
    let mode = ProcessInfo.processInfo.environment["PRINTROOM_PERFORMANCE_MODE"] ?? "optimized"
    let legacy = mode == "legacy"
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let urls = try FileManager.default.contentsOfDirectory(
      at: root.appendingPathComponent("TEST/TIFF"), includingPropertiesForKeys: nil)
      .filter { ["tif", "tiff"].contains($0.pathExtension.lowercased()) }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    #expect(urls.count == 10)
    let first = try #require(urls.first)
    let service = ImageService()
    let thumbnails = ImageService(cacheLimitBytes: 8 * 1024 * 1024)
    let assets = try AppAssets()
    let renderer = PreviewRenderService()
    var records: [(String, Double)] = []
    func seconds(_ from: ContinuousClock.Instant) -> Double {
      let duration = from.duration(to: .now).components
      return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
    }
    func memory() -> Double {
      var usage = rusage()
      getrusage(RUSAGE_SELF, &usage)
      return Double(usage.ru_maxrss) / 1_048_576
    }
    let start = ContinuousClock.now
    var original: LinearImage?
    let input: PixelBuffer
    if legacy {
      original = try TIFFCodec.read(url: first)
      input = original!.preview(maxDimension: 1600)
    } else {
      input = try await service.preview(first).0
    }
    records.append(("first_preview_decode", seconds(start)))
    let decodePeak = memory()
    let displayStart = ContinuousClock.now
    _ = try await renderer.render(
      input, calibration: .init(), adjustments: .init(), assets: assets)
    records.append(("first_gpu_and_display", seconds(displayStart)))
    var changes: [Double] = []
    for step in 0..<20 {
      let began = ContinuousClock.now
      var adjustments = FrameAdjustments()
      adjustments.timing.master = step
      _ = try await renderer.render(
        input, calibration: .init(), adjustments: adjustments, assets: assets)
      changes.append(seconds(began))
    }
    records.append(("adjustment_mean", changes.reduce(0, +) / Double(changes.count)))
    records.append(("adjustment_max", changes.max()!))
    withExtendedLifetime(original) {}
    original = nil
    let thumbnailStart = ContinuousClock.now
    for url in urls {
      let pixels: PixelBuffer
      if legacy { pixels = try TIFFCodec.read(url: url).preview(maxDimension: 240) }
      else { pixels = try await thumbnails.thumbnail(url) }
      _ = try await renderer.render(
        pixels, calibration: .init(), adjustments: .init(), assets: assets)
    }
    records.append(("ten_thumbnails", seconds(thumbnailStart)))
    let switching = ContinuousClock.now
    for url in urls {
      let pixels: PixelBuffer
      if legacy { pixels = try TIFFCodec.read(url: url).preview(maxDimension: 1600) }
      else { pixels = try await service.preview(url).0 }
      _ = try await renderer.render(
        pixels, calibration: .init(), adjustments: .init(), assets: assets)
    }
    records.append(("ten_frame_switches", seconds(switching)))
    let warmed = ContinuousClock.now
    let secondToLast = urls[urls.count - 2]
    if legacy { _ = try TIFFCodec.read(url: secondToLast).preview(maxDimension: 1600) }
    else { _ = try await service.preview(secondToLast) }
    records.append(("recent_frame_decode", seconds(warmed)))
    let tileStart = ContinuousClock.now
    let rect = PixelRect(x: 1000, y: 1000, width: 2048, height: 1536)
    let tile = try await service.region(first, rect: rect)
    _ = try await renderer.render(
      tile, calibration: .init(), adjustments: .init(), assets: assets)
    records.append(("native_2048x1536_tile", seconds(tileStart)))
    let cancellationService = ImageService()
    let canceledLoad = Task { try await cancellationService.preview(first) }
    try await Task.sleep(for: .milliseconds(5))
    let cancellationStart = ContinuousClock.now
    canceledLoad.cancel()
    do {
      _ = try await canceledLoad.value
      Issue.record("Reference preview completed before the cancellation measurement")
    } catch is CancellationError {}
    records.append(("cancel_inflight_decode", seconds(cancellationStart)))
    #expect(await cancellationService.cacheStatistics().entries == 0)
    let stats = await service.cacheStatistics()
    #expect(stats.bytes <= stats.limitBytes)
    print("PRINTROOM_PERFORMANCE mode=\(mode) gpu=\(assets.gpu.deviceName) os=\(ProcessInfo.processInfo.operatingSystemVersionString)")
    for (name, duration) in records {
      print(String(format: "PERF %@ %@ %.6f seconds", mode, name, duration))
    }
    print(String(format: "PERF %@ decode_peak_rss %.2f MiB", mode, decodePeak))
    print(String(format: "PERF %@ process_peak_rss %.2f MiB", mode, memory()))
    print("PERF \(mode) cache_bytes \(stats.bytes) bytes entries=\(stats.entries) hits=\(stats.hits) misses=\(stats.misses)")
  }
}

extension ImagePerformanceMeasurements {
  /// Two-frame real TIFF batches, opt-in and intended for separate release test
  /// processes so ru_maxrss is meaningful for each profile/compression choice.
  @Test(.enabled(if: ProcessInfo.processInfo.environment["PRINTROOM_EXPORT_PERFORMANCE"] != nil))
  func measureBatchExport() async throws {
    let mode = try #require(ProcessInfo.processInfo.environment["PRINTROOM_EXPORT_PERFORMANCE"])
    #expect(mode == "p3" || mode == "proPhoto")
    let profile: OutputColorProfile = mode == "p3" ? .displayP3 : .proPhoto
    let compression: TIFFCompression = mode == "p3" ? .none : .deflate
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let sources = try FileManager.default.contentsOfDirectory(
      at: root.appendingPathComponent("TEST/TIFF"), includingPropertiesForKeys: nil)
      .filter { ["tif", "tiff"].contains($0.pathExtension.lowercased()) }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    #expect(sources.count == 10)
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
      "PrintroomExportPerformance-\(UUID().uuidString)", isDirectory: true)
    let rollFolder = temporary.appendingPathComponent("Roll", isDirectory: true)
    let destination = temporary.appendingPathComponent("Exports", isDirectory: true)
    try FileManager.default.createDirectory(at: rollFolder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    for source in sources.prefix(2) {
      try FileManager.default.copyItem(at: source, to: rollFolder.appendingPathComponent(source.lastPathComponent))
    }
    let assets = try AppAssets()
    var project = try ProjectStore.open(folder: rollFolder, preferredFile: nil)
    #expect(project.frames.count == 2)
    let first = try #require(project.frames.first)
    let service = ImageService()
    project.calibration = try await service.sample(
      rollFolder.appendingPathComponent(first.filename),
      rect: PixelRect(x: 359, y: 604, width: 79, height: 494),
      matrix: .ledLightSource, frameID: first.id).0
    for index in project.frames.indices {
      project.frames[index].adjustments = FrameAdjustments(
        timing: .init(master: 30, red: 5, green: -3, blue: 7),
        contrast: .init(master: 1.05, red: 0.95, green: 1.02, blue: 1.1))
    }
    // Include a full-resolution transposed export without changing the source.
    project.frames[1].orientation = .rotate90CW
    project.exportSettings = ProjectExportSettings(profile: profile, compression: compression)
    let request = try ExportRequest(
      project: project, targetIDs: Set(project.frames.map(\.id)), destinationDirectory: destination)
    let probe = ExportMemoryProbe()
    let began = ContinuousClock.now
    let summary = try await ExportEngine().run(request, lut: assets.lut, p3Profile: assets.profile) {
      probe.record($0)
    }
    let duration = began.duration(to: .now).components
    let elapsed = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
    let exportPeak = ExportMemoryProbe.peakResidentBytes()
    #expect(summary.completedCount == 2 && summary.failedCount == 0 && !summary.wasCancelled)
    #expect(summary.results.count == 2)
    print("PRINTROOM_EXPORT_PERFORMANCE mode=\(mode) compression=\(compression.rawValue) gpu=\(assets.gpu.deviceName)")
    print("EXPORT_INPUT parameters=master30,r5,g-3,b7 contrast=1.05,.95,1.02,1.1 matrix=LED secondFrame=rotate90CW")
    print(String(format: "EXPORT_PERF %@ elapsed %.6f seconds", mode, elapsed))
    print(String(format: "EXPORT_PERF %@ export_peak_rss %.2f MiB", mode, Double(exportPeak) / 1_048_576))
    for (index, result) in summary.results.enumerated() {
      let url = try #require(result.destination)
      let info = try TIFFCodec.metadata(url: url)
      let expected = index == 0 ? (7008, 4672) : (4672, 7008)
      #expect(info.width == expected.0 && info.height == expected.1)
      let sample = try TIFFCodec.readRegion(
        url: url, rect: PixelRect(x: 101, y: 203, width: 8, height: 8))
      #expect(sample.samples.count == 8 * 8 * 3)
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      let size = try #require((attributes[.size] as? NSNumber)?.int64Value)
      print("EXPORT_FILE \(mode) \(index + 1) \(result.sourceName) \(info.width)x\(info.height) bytes=\(size) profile=\(info.embeddedProfileName)")
    }
    let samples = probe.snapshot()
    #expect(samples.count == 2)
    // malloc can keep freed pages resident for reuse. An immediate RSS drop
    // does not prove object release; instead bound growth across frame boundaries
    // and the whole queue to one UInt16 source plus GPU/conversion working space.
    let sourceBytes = UInt64(7008 * 4672 * 6)
    #expect(exportPeak <= probe.initialResident + sourceBytes + 128 * 1_048_576)
    if samples.count == 2 {
      #expect(samples[1].peak <= samples[0].peak + 64 * 1_048_576)
    }
    for (index, sample) in samples.enumerated() {
      print(String(format: "EXPORT_MEMORY %@ frame%d peak %.2f after %.2f MiB",
        mode, index + 1, Double(sample.peak) / 1_048_576, Double(sample.after) / 1_048_576))
    }
    print(String(format: "EXPORT_MEMORY %@ initial %.2f allowed_peak %.2f MiB",
      mode, Double(probe.initialResident) / 1_048_576,
      Double(probe.initialResident + sourceBytes + 128 * 1_048_576) / 1_048_576))
  }
}

/// Measurements are observed synchronously at ExportEngine's progress boundaries;
/// no polling task or extra process competes with the actual export work.
private final class ExportMemoryProbe: @unchecked Sendable {
  struct Sample {
    let peak: UInt64
    let after: UInt64
  }
  let initialResident = ExportMemoryProbe.currentResidentBytes()
  private let lock = NSLock()
  private var framePeak: UInt64 = 0
  private var samples: [Sample] = []

  func record(_ progress: ExportProgress) {
    let resident = Self.currentResidentBytes()
    lock.lock()
    defer { lock.unlock() }
    if progress.currentName != nil {
      framePeak = max(framePeak, resident)
    } else if progress.processedCount > samples.count {
      samples.append(Sample(peak: framePeak, after: resident))
      framePeak = 0
    }
  }

  func snapshot() -> [Sample] {
    lock.lock()
    defer { lock.unlock() }
    return samples
  }

  static func peakResidentBytes() -> UInt64 {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return UInt64(usage.ru_maxrss)
  }

  static func currentResidentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
      }
    }
    return result == KERN_SUCCESS ? info.resident_size : 0
  }
}
