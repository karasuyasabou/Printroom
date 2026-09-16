import Combine
import CoreGraphics
import Darwin
import Foundation
import PrintroomCore
import Testing

@testable import PrintroomApp

/// Opt-in release measurements. Publication means a CGImage delivered by the
/// editor model, not a display refresh or a physical screen presentation.
@Suite(.serialized)
struct AdjustmentPerformanceMeasurements {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["PRINTROOM_ADJUSTMENT_PERFORMANCE"] != nil))
  @MainActor func measureAdjustments() async throws {
    let mode = try #require(ProcessInfo.processInfo.environment["PRINTROOM_ADJUSTMENT_PERFORMANCE"])
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let source = root.appendingPathComponent("TEST/TIFF/DSC07079.tiff")
    let service = ImageService()
    let assets = try AppAssets()
    let input = try await service.preview(source).0
    let calibration = try await service.sample(source,
      rect: PixelRect(x: 359, y: 604, width: 79, height: 494),
      matrix: .ledLightSource, frameID: UUID()).0
    print("ADJUSTMENT_ENV mode=\(mode) gpu=\(assets.gpu.deviceName) os=\(ProcessInfo.processInfo.operatingSystemVersionString) input=DSC07079.tiff preview=\(input.width)x\(input.height) calibration=LED_ROI_359_604_79_494")
    if mode == "renderer" {
      try await measureRenderer(input, calibration: calibration, assets: assets)
    } else {
      #expect(mode == "editor")
      try await measureEditor(source, input: input, calibration: calibration, assets: assets)
    }
    print(String(format: "ADJUSTMENT_PERF %@ current_rss %.2f MiB", mode, residentMiB()))
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    print(String(format: "ADJUSTMENT_PERF %@ peak_rss %.2f MiB", mode, Double(usage.ru_maxrss) / 1_048_576))
  }

  private func measureRenderer(_ input: PixelBuffer, calibration: FilmCalibration,
    assets: AppAssets) async throws {
    let renderer = PreviewRenderService()
    let identity = UUID()
    var adjustments = FrameAdjustments()
    let cold = ContinuousClock.now
    _ = try await render(renderer, input, calibration: calibration,
      adjustments: adjustments, assets: assets, identity: identity)
    report("renderer", "first_gpu_and_display", milliseconds(cold, .now))
    for group in ["timing", "contrast"] {
      var samples: [Double] = []
      var histogramSamples: [Double] = []
      var combinedSamples: [Double] = []
      var sampledTimes: [Double] = []
      var maxCDFError = 0.0
      for step in 1...30 {
        if group == "timing" {
          adjustments.timing.master = step
          adjustments.timing.red = -step / 3
        } else {
          adjustments.contrast.master = 1 + Float(step) / 100
          adjustments.contrast.blue = 1 - Float(step) / 200
        }
        let began = ContinuousClock.now
        let result = try await render(renderer, input, calibration: calibration,
          adjustments: adjustments, assets: assets, identity: identity)
        samples.append(milliseconds(began, .now))
        let histogramBegan = ContinuousClock.now
        let statistics = try await Task.detached(priority: .utility) {
          try HistogramStatistics.compute(result.pixels, stage: .final,
            isPreview: true, cancelled: { Task.isCancelled })
        }.value
        histogramSamples.append(milliseconds(histogramBegan, .now))
        combinedSamples.append(milliseconds(began, .now))
        #expect(statistics.pixelCount == input.width * input.height)
        let sampledBegan = ContinuousClock.now
        let sampled = try await Task.detached(priority: .utility) {
          try HistogramStatistics.computePreview(result.pixels, stage: .final,
            cancelled: { Task.isCancelled })
        }.value
        sampledTimes.append(milliseconds(sampledBegan, .now))
        for channel in 0..<3 {
          var exactCDF = 0.0, sampledCDF = 0.0
          for bin in 0..<256 {
            exactCDF += Double(statistics.channels[channel].bins[bin]) / Double(statistics.sampleCount)
            sampledCDF += Double(sampled.channels[channel].bins[bin]) / Double(sampled.sampleCount)
            maxCDFError = max(maxCDFError, abs(exactCDF - sampledCDF))
          }
        }
        #expect(result.image.width == input.width && result.image.height == input.height)
      }
      report("renderer", "\(group)_mean", samples.reduce(0, +) / Double(samples.count))
      report("renderer", "\(group)_p50", percentile(samples, 0.5))
      report("renderer", "\(group)_p95", percentile(samples, 0.95))
      report("renderer", "\(group)_max", samples.max()!)
      for (name, values) in [("histogram", histogramSamples), ("combined", combinedSamples)] {
        report(name, "\(group)_mean", values.reduce(0, +) / Double(values.count))
        report(name, "\(group)_p50", percentile(values, 0.5))
        report(name, "\(group)_p95", percentile(values, 0.95))
      }
      report("sampled_histogram", "\(group)_mean", sampledTimes.reduce(0, +) / Double(sampledTimes.count))
      report("sampled_histogram", "\(group)_p95", percentile(sampledTimes, 0.95))
      print("ADJUSTMENT_ACCURACY \(group) max_CDF_error_percentage_points=\(maxCDFError * 100)")
    }
    print("ADJUSTMENT_CHECK renderer measured_changes=60 includes=GPU,CPU_readback,orientation,UInt16_CGImage excludes=decode,histogram,UI_publication,screen_compositor")
    print("ADJUSTMENT_CHECK histogram includes=utility_task_scheduling,whole_preview_scan excludes=120ms_debounce combined=serial_render_then_histogram screen_presentation=not_measured")
  }

  @MainActor private func measureEditor(_ source: URL, input: PixelBuffer,
    calibration: FilmCalibration, assets: AppAssets) async throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
      "PrintroomAdjustmentPerformance-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    try FileManager.default.copyItem(at: source,
      to: temporary.appendingPathComponent(source.lastPathComponent))
    let model = EditorModel()
    model.open(temporary)
    try await waitUntil { !model.isLoading && !model.isRendering && model.previewImage != nil
      && model.histogram != nil && model.thumbnails.count == 1 }
    var rollCalibration = calibration
    rollCalibration.sourceFrameID = try #require(model.activeFrame?.id)
    model.project?.calibration = rollCalibration
    model.render()
    try await waitUntil { !model.isRendering && !model.isHistogramUpdating && model.histogram != nil }

    let publication = AdjustmentPublicationProbe()
    let subscription = model.$previewImage.dropFirst().sink { image in
      if image != nil { publication.record() }
    }
    defer { subscription.cancel() }
    model.beginAdjustment()
    let began = ContinuousClock.now
    var submitted = began
    // Deliberately faster than the legacy 25 ms debounce for at least one second.
    // The observed publication times below, rather than this input period,
    // determine whether continuous input receives visible model updates.
    for step in 1...120 {
      if step > 1 { try await Task.sleep(for: .milliseconds(10)) }
      submitted = .now
      model.edit { adjustment in
        adjustment.timing.master = step
        adjustment.timing.red = -step / 4
        adjustment.contrast.master = 1 + Float(step) / 1000
      }
    }
    let finalSubmission = submitted
    model.endAdjustment()
    try await waitUntil { !model.isRendering && model.previewImage != nil }
    let renderIdle = ContinuousClock.now
    try await waitUntil { !model.isHistogramUpdating && model.histogram != nil }
    let histogramIdle = ContinuousClock.now
    let times = publication.snapshot()
    let last = try #require(times.last)
    let during = times.filter { $0 <= finalSubmission }
    report("editor", "input_span", milliseconds(began, finalSubmission))
    report("editor", "first_input_to_first_publication", milliseconds(began, try #require(times.first)))
    report("editor", "last_input_to_final_publication", milliseconds(finalSubmission, last))
    report("editor", "last_input_to_render_idle_observed", milliseconds(finalSubmission, renderIdle))
    report("editor", "last_input_to_histogram_idle_observed", milliseconds(finalSubmission, histogramIdle))
    if times.count > 1 {
      let intervals = zip(times, times.dropFirst()).map { milliseconds($0.0, $0.1) }
      report("editor", "publication_interval_p50", percentile(intervals, 0.5))
      report("editor", "publication_interval_p95", percentile(intervals, 0.95))
      report("editor", "publication_interval_max", intervals.max()!)
    }
    print("ADJUSTMENT_COUNT editor inputs=120 publications_during_input=\(during.count) publications_total=\(times.count)")
    // Outside the timed path: independently render the final parameters through
    // the original stateless GPU API and compare the complete display bytes.
    let expectedPixels = try assets.gpu.render(input, calibration: calibration,
      adjustments: model.adjustments, lut: assets.lut)
    let expectedImage = try DisplayImage.make(expectedPixels, profile: assets.profile)
    let actualImage = try #require(model.previewImage)
    #expect(actualImage.width == expectedImage.width && actualImage.height == expectedImage.height)
    let completeImageMatches = actualImage.dataProvider?.data as Data?
      == expectedImage.dataProvider?.data as Data?
    try #require(completeImageMatches, "Final preview differs from independent stateless GPU rendering")
    #expect(model.adjustments.timing.master == 120)
    #expect(model.errorMessage == nil)
    #expect(model.flushSave())
    print("ADJUSTMENT_CHECK editor final_complete_image_bytes=matched_stateless_GPU input_cadence_is_not_output_FPS screen_presentation=not_measured idle_poll_resolution_ms=2")
    // Let the final thumbnail settle before deleting the temporary roll.
    try await Task.sleep(for: .milliseconds(300))
  }

  private func render(_ renderer: PreviewRenderService, _ input: PixelBuffer,
    calibration: FilmCalibration, adjustments: FrameAdjustments, assets: AppAssets,
    identity: UUID) async throws -> RenderedPreview {
    #if PRINTROOM_LEGACY_ADJUSTMENT_RENDERER
    return try await renderer.render(input, calibration: calibration,
      adjustments: adjustments, assets: assets)
    #else
    return try await renderer.render(input, calibration: calibration,
      adjustments: adjustments, assets: assets, inputIdentity: identity)
    #endif
  }

  @MainActor private func waitUntil(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(20))
    while !predicate() && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(2))
    }
    try #require(predicate(), "Editor did not settle within 20 seconds")
  }

  private func milliseconds(_ start: ContinuousClock.Instant, _ end: ContinuousClock.Instant) -> Double {
    let components = start.duration(to: end).components
    return Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
  }
  private func percentile(_ values: [Double], _ percentile: Double) -> Double {
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * percentile)) - 1)]
  }
  private func report(_ mode: String, _ name: String, _ milliseconds: Double) {
    print(String(format: "ADJUSTMENT_PERF %@ %@ %.3f ms", mode, name, milliseconds))
  }
  private func residentMiB() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
      }
    }
    return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
  }
}

/// A short locked timestamp append keeps Combine observation out of image
/// processing. All whole-image verification is deferred until after timing.
private final class AdjustmentPublicationProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var times: [ContinuousClock.Instant] = []
  func record() {
    let timestamp = ContinuousClock.now
    lock.lock()
    times.append(timestamp)
    lock.unlock()
  }
  func snapshot() -> [ContinuousClock.Instant] {
    lock.lock()
    defer { lock.unlock() }
    return times
  }
}
