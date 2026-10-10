import CryptoKit
import Darwin
import Foundation
import ImageIO
import PrintroomCore
import Testing
@testable import PrintroomApp

#if PRINTROOM_PERFORMANCE_TRACE
/// Real workflows in fresh Release processes. All writes require a scratch/performance fixture.
@Suite(.serialized) @MainActor
struct RollPerformanceMeasurements {
  struct Report: Encodable {
    let mode: String
    let frameCount: Int
    let elapsed: Double
    let applied: Double?
    let peakRSSMiB: Double
    let stages: [String: PerformanceTrace.Stat]
    let outputs: [String]
  }
  @Test(.enabled(if: ProcessInfo.processInfo.environment["PRINTROOM_BENCH_MODE"] != nil))
  func measureRoll() async throws {
    let env = ProcessInfo.processInfo.environment
    let mode = try #require(env["PRINTROOM_BENCH_MODE"])
    let path = try #require(env["PRINTROOM_BENCH_ROLL"])
    let reportPath = try #require(env["PRINTROOM_BENCH_REPORT"])
    try #require(PerformanceTrace.isolatedCacheRoot != nil && path.contains("/scratch/performance/"))
    let folder = URL(fileURLWithPath: path, isDirectory: true)
    let out = URL(fileURLWithPath: reportPath).deletingLastPathComponent()
    let defaults = try #require(UserDefaults(suiteName: "PrintroomBenchmark-\(UUID())"))
    let model = EditorModel(timingDefaults: defaults,
      matrixStore: MatrixLibraryStore(url: out.appendingPathComponent("matrices.json")),
      previewWarmupEnabled: false)
    try #require(model.assets != nil)
    var project = try ProjectStore.open(folder: folder)
    // Controlled benchmark settings, stored only in a private copied roll.
    if mode != "import" {
      let first = try #require(project.frames.first)
      project.calibration = try await ImageService().sample(folder.appendingPathComponent(first.filename),
        rect: PixelRect(x: 359, y: 604, width: 79, height: 494),
        matrix: .ledLightSource, frameID: first.id)
    }
    for i in project.frames.indices { project.frames[i].adjustments = .init() }
    project.frames[0].adjustments = FrameAdjustments(
      timing: .init(master: 30, red: 5, green: -3, blue: 7),
      contrast: .init(master: 1.05, red: 0.95, green: 1.02, blue: 1.1))
    if mode != "import" {
      _ = try ProjectStore.save(project, folder: folder, expectedModification: project.loadedModificationDate)
    }
    var applied: Double?
    var outputs: [String] = []
    var elapsed: Double = 0
    PerformanceTrace.reset()
    if mode == "import" || mode == "sync" {
      let start = ContinuousClock.now
      model.open(folder)
      try await until {
        model.importFailure != nil || (model.project != nil && !model.isImporting)
      }
      try #require(model.importFailure == nil && model.importCompleted == project.frames.count)
      elapsed = seconds(start)
      if mode == "import" {
        // Snapshot the barrier, before ongoing preview/thumbnail work changes the totals.
        let stages = PerformanceTrace.snapshot()
        try writeReport(mode, count: project.frames.count, elapsed: elapsed,
          applied: nil, stages: stages, outputs: [], path: reportPath)
        model.returnHome()
        return
      }
      try #require(await model.performanceWaitForThumbnails())
      try await until { !model.isLoading && !model.isRendering }
      model.selectAll()
      model.syncTiming = true; model.syncContrast = true; model.syncLUT = true
      PerformanceTrace.reset()
      let syncStart = ContinuousClock.now
      try #require(model.syncCurrentSettings())
      applied = seconds(syncStart)
      try #require(model.project!.frames.allSatisfy { $0.adjustments == project.frames[0].adjustments })
      try #require(!model.dirty && !model.saveFailure)
      try #require(await model.performanceWaitForThumbnails())
      elapsed = seconds(syncStart)
      if env["PRINTROOM_BENCH_DRAIN_MAINTENANCE"] == "1" {
        // Capture asynchronous cleanup separately, without adding it to thumbnail completion time.
        try await until { (PerformanceTrace.snapshot()["proxy.maintenance"]?.count ?? 0) > 0 }
      }
      let saved = try ProjectStore.open(folder: folder)
      try #require(saved.frames.allSatisfy { $0.adjustments == project.frames[0].adjustments })
    } else if mode == "derive-tiff" {
      let sources = project.frames.map { folder.appendingPathComponent($0.filename) }
      let destination = out.appendingPathComponent("derived-tiff", isDirectory: true)
      try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
      let start = ContinuousClock.now
      for url in sources {
        try await Task.detached {
          let image = try SourceImageIO.read(url: url)
          let target = destination.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".tiff")
          try TIFFCodec.write(url: target, width: image.width, height: image.height,
            profile: nil, compression: .none) { rows in
            Array(image.samples[(rows.lowerBound * image.width * 3)..<(rows.upperBound * image.width * 3)])
          }
        }.value
      }
      elapsed = seconds(start)
    } else {
      let assets = try #require(model.assets)
      let count = Int(env["PRINTROOM_BENCH_COUNT"] ?? "36")!
      project.frames = Array(project.frames.prefix(count))
      let concurrency = Int(env["PRINTROOM_BENCH_CONCURRENCY"] ?? "4")!
      project.exportSettings = .init(profile: .displayP3,
        compression: mode == "export-none" ? .none : .deflate)
      if mode == "export-jpeg" { project.exportSettings.format = .jpeg }
      for i in project.frames.indices {
        project.frames[i].adjustments = project.frames[0].adjustments
        if env["PRINTROOM_BENCH_CROP"] == "1" {
          project.frames[i].crop = try FrameCrop(width: 0.9, angleDegrees: 3.25)
            .constrained(sourceWidth: 7008, sourceHeight: 4672)
          project.frames[i].orientation = i % 2 == 0 ? .identity : .rotate90CW
        }
      }
      let destination = out.appendingPathComponent("exports-\(UUID())", isDirectory: true)
      try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
      let request = try ExportRequest(project: project, targetIDs: Set(project.frames.map(\.id)),
        destinationDirectory: destination)
      PerformanceTrace.reset()
      let start = ContinuousClock.now
      let summary = try await ExportEngine(maximumConcurrentExports: concurrency).run(
        request, lut: assets.lut, p3Profile: assets.profile,
        fujifilmLUT: assets.lut(for: .fujifilm3513DI))
      elapsed = seconds(start)
      try #require(summary.completedCount == count && summary.failedCount == 0 && !summary.wasCancelled)
      let stages = PerformanceTrace.snapshot()
      // Validation and output hashes are outside the timed interval and reported peak.
      try writeReport(mode, count: count, elapsed: elapsed, applied: nil,
        stages: stages, outputs: [], path: reportPath)
      for (index, item) in summary.results.enumerated() {
        let url = try #require(item.destination)
        let info = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(info, 0, nil) as? [String: Any])
        let geometry = try CropGeometry(crop: request.frames[index].crop,
          sourceWidth: 7008, sourceHeight: 4672, orientation: request.frames[index].orientation)
        try #require((props[kCGImagePropertyPixelWidth as String] as? Int) == geometry.outputWidth)
        try #require((props[kCGImagePropertyPixelHeight as String] as? Int) == geometry.outputHeight)
        // Stream hashes to avoid a full-file allocation polluting memory measurements.
        let handle = try FileHandle(forReadingFrom: url)
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty { hash.update(data: bytes) }
        try handle.close()
        outputs.append(url.lastPathComponent + " " + hash.finalize().map { String(format: "%02x", $0) }.joined())
      }
      try outputs.joined(separator: "\n").write(to: out.appendingPathComponent("\(URL(fileURLWithPath: reportPath).lastPathComponent).sha256"), atomically: true, encoding: .utf8)
      if env["PRINTROOM_BENCH_KEEP_OUTPUTS"] != "1" { try FileManager.default.removeItem(at: destination) }
      return
    }
    try writeReport(mode, count: project.frames.count, elapsed: elapsed,
      applied: applied, stages: PerformanceTrace.snapshot(), outputs: outputs, path: reportPath)
    model.returnHome()
  }
  private func until(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(1200))
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    try #require(condition())
  }
  private func seconds(_ start: ContinuousClock.Instant) -> Double {
    let d = start.duration(to: .now).components
    return Double(d.seconds) + Double(d.attoseconds) / 1e18
  }
  private func writeReport(_ mode: String, count: Int, elapsed: Double, applied: Double?,
    stages: [String: PerformanceTrace.Stat], outputs: [String], path: String) throws {
    var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
    let report = Report(mode: mode, frameCount: count, elapsed: elapsed, applied: applied,
      peakRSSMiB: Double(usage.ru_maxrss) / 1_048_576, stages: stages, outputs: outputs)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(report).write(to: URL(fileURLWithPath: path), options: .atomic)
    print("BENCH \(mode) count=\(count) seconds=\(elapsed) applied=\(String(describing: applied)) peakRSSMiB=\(report.peakRSSMiB)")
  }
}
#endif
