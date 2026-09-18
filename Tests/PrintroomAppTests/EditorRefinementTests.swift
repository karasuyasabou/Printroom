import Combine
import CoreGraphics
import Foundation
import PrintroomCore
import Testing
@testable import PrintroomApp

@Suite(.serialized) @MainActor
struct EditorRefinementTests {
  private func fixture(_ model: EditorModel, count: Int = 2, pixel: SIMD3<UInt16>? = nil) throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PrintroomRefinement-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let profile = try #require(model.assets).profile
    for i in 0..<count {
      try TIFFCodec.write(url: folder.appendingPathComponent("\(i).tif"),
        width: 64, height: 48, profile: profile) { rows in
        var samples: [UInt16] = []
        for y in rows { for x in 0..<64 {
          if let pixel { samples += [pixel.x, pixel.y, pixel.z] }
          else { samples += [UInt16(10000 + x * 80), UInt16(16000 + y * 80), UInt16(23000 + i * 3000)] }
        } }
        return samples
      }
    }
    return folder
  }
  private func until(_ label: String, _ ready: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !ready(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(15)) }
    try #require(ready(), "\(label)")
  }
  private func settled(_ model: EditorModel) async throws {
    try await until("settled preview") {
      !model.isLoading && !model.isRendering && !model.isHistogramUpdating && model.histogram != nil
    }
    #expect(model.errorMessage == nil)
  }

  /// Independent CIE Lab reference from the pinned P3 ICC's signed 16.16
  /// colorants and gamma; no solver or production ICC helper participates.
  private func representativeLab(_ final: PixelBuffer) -> SIMD3<Double> {
    let rgb = (0..<3).map { channel -> Double in
      let values = final.pixels.map { Double($0[channel]) }.sorted()
      let middle = values.count / 2
      return values.count.isMultiple(of: 2)
        ? (values[middle - 1] + values[middle]) / 2 : values[middle]
    }
    let r = SIMD3<Double>(33759, 15807, -69) / 65536
    let g = SIMD3<Double>(19135, 45367, 2745) / 65536
    let b = SIMD3<Double>(10296, 4363, 51385) / 65536
    let white = r + g + b
    let xyz = r * pow(rgb[0], 2.600006103515625)
      + g * pow(rgb[1], 2.600006103515625) + b * pow(rgb[2], 2.600006103515625)
    let relative = xyz / white
    func f(_ t: Double) -> Double {
      t > 216.0 / 24389 ? cbrt(t) : t * (24389.0 / 27) / 116 + 16.0 / 116
    }
    let x = f(relative.x), y = f(relative.y), z = f(relative.z)
    return SIMD3(116 * y - 16, 500 * (x - y), 200 * (y - z))
  }

  @Test func hoverProbeTracksPublishedSnapshotAndHistogramStage() async throws {
    let model = EditorModel()
    let pixel = SIMD3<UInt16>(12000, 23000, 34000)
    let folder = try fixture(model, count: 2, pixel: pixel)
    defer { try? FileManager.default.removeItem(at: folder) }
    model.open(folder)
    model.histogramStage = .d3
    try await settled(model)
    let calibration = try #require(model.project).calibration
    let expected = try Pipeline.process(SIMD3<Float>(pixel) / 65535,
      calibration: calibration, adjustments: model.adjustments, stage: .d3)
    model.probeHistogram(displayX: 10, displayY: 10)
    #expect(model.histogramProbe == expected)
    model.edit { $0.timing.master = 100 }
    model.clearHistogramProbe()
    model.probeHistogram(displayX: 12, displayY: 12)
    #expect(model.histogramProbe == expected) // old histogram is still visible
    try await settled(model)
    model.probeHistogram(displayX: 12, displayY: 12)
    #expect(model.histogramProbe != expected)
    let current = try #require(model.histogramProbe)
    model.histogramStage = .final
    #expect(model.histogramProbe == nil)
    try await settled(model)
    model.probeHistogram(displayX: 12, displayY: 12)
    #expect(model.histogramProbe != nil)
    #expect(model.histogramProbe != current)
    model.probeHistogram(displayX: -1, displayY: 12)
    #expect(model.histogramProbe == nil)
    model.probeHistogram(displayX: 12, displayY: 12)
    model.beginCrop()
    model.probeHistogram(displayX: 12, displayY: 12)
    #expect(model.histogramProbe == nil)
    model.cancelCrop()
    #expect(model.flushSave())
  }

  @Test func hoverMedianIncludesClippingAndAveragesEvenNeighbourhoods() throws {
    let values: [SIMD4<Float>] = [SIMD4(0, 1, 0.2, 1), SIMD4(0, 1, 0.4, 1),
      SIMD4(0.4, 0.2, 0.6, 1), SIMD4(1, 0, 0.8, 1)]
    let lut = try #require(EditorModel().assets).lut
    let result = try HistogramProbe.median(PixelBuffer(width: 2, height: 2, pixels: values),
      calibration: FilmCalibration(), adjustments: FrameAdjustments(), lut: lut, stage: .l0)
    #expect(abs(result.x - 0.2) < 0.000001)
    #expect(abs(result.y - 0.6) < 0.000001)
    #expect(abs(result.z - 0.5) < 0.000001)
  }

  @Test func histogramRemainsVisibleUntilLatestAdjustmentFinishes() async throws {
    let model = EditorModel(), folder: URL
    folder = try fixture(model)
    defer { try? FileManager.default.removeItem(at: folder) }
    model.open(folder)
    model.stage = .d3
    try await settled(model)
    let previous = try #require(model.histogram)
    for value in 1...30 {
      model.edit { $0.timing.master = value * 4 }
      #expect(model.histogram == previous)
    }
    try await settled(model)
    #expect(model.histogram != previous)
    let latest = model.histogram
    try await Task.sleep(for: .milliseconds(180))
    #expect(model.histogram == latest)
    model.stage = .l0
    #expect(model.histogram == nil)
    try await settled(model)
    #expect(model.histogram?.stage == .final)
    #expect(model.flushSave())
  }

  @Test func imagePublicationAlreadyHasMatchingHistogram() async throws {
    let model = EditorModel()
    let folder = try fixture(model)
    defer { try? FileManager.default.removeItem(at: folder) }
    model.open(folder)
    model.stage = .final
    model.histogramStage = .d3
    try await settled(model)
    let old = try #require(model.histogram)
    var publishedHistogram: HistogramStatistics?
    let subscription = model.$previewImage.dropFirst().sink { image in
      if image != nil { publishedHistogram = model.histogram }
    }
    defer { subscription.cancel() }
    model.edit { $0.timing.master = 120 }
    try await settled(model)
    #expect(publishedHistogram != nil)
    #expect(publishedHistogram != old)
    #expect(publishedHistogram == model.histogram)
    let frame = try #require(model.activeFrame)
    let input = try await ImageService().preview(folder.appendingPathComponent(frame.filename)).0
    let pixels = try Pipeline.render(input, calibration: try #require(model.project?.calibration),
      adjustments: model.adjustments, stage: .d3)
    #expect(publishedHistogram == (try HistogramStatistics.computePreview(pixels, stage: .d3)))
    #expect(model.flushSave())
  }

  @Test func switchingUsesThumbnailThenFullPreviewAndReturningUsesCachedPreview() async throws {
    let model = EditorModel(), folder: URL
    folder = try fixture(model)
    defer { try? FileManager.default.removeItem(at: folder) }
    model.open(folder)
    try await settled(model)
    try await until("thumbnails") { model.thumbnails.count == 2 }
    let frames = try #require(model.project?.frames)
    let original = try #require(model.previewImage)
    model.select(frames[1].id)
    #expect(model.previewImage === model.thumbnails[frames[1].id])
    #expect(model.isPreviewPlaceholder && model.isLoading)
    #expect(!model.hasImage && !model.canPickNeutral)
    let placeholder = model.previewImage
    try await settled(model)
    #expect(!model.isPreviewPlaceholder && model.hasImage)
    #expect(model.previewImage !== placeholder)
    model.select(frames[0].id)
    #expect(model.previewImage === original)
    #expect(model.isPreviewPlaceholder)
    // A Final thumbnail cannot masquerade as a density-stage preview.
    model.stage = .d2
    #expect(model.previewImage == nil)
    try await settled(model)
    #expect(model.histogram?.stage == .final)
    #expect(model.flushSave())
  }

  @Test func modifiedSourceCannotReuseDisplaySnapshot() async throws {
    let model = EditorModel(), folder: URL
    folder = try fixture(model)
    defer { try? FileManager.default.removeItem(at: folder) }
    model.open(folder)
    try await settled(model)
    try await until("thumbnails") { model.thumbnails.count == 2 }
    let frames = try #require(model.project?.frames)
    model.select(frames[1].id)
    try await settled(model)
    let first = folder.appendingPathComponent(frames[0].filename)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 5)], ofItemAtPath: first.path)
    model.select(frames[0].id)
    #expect(model.previewImage == nil && !model.isPreviewPlaceholder)
    try await settled(model)
    #expect(model.flushSave())
  }

  @Test func neutralPickUsesOriginalCropCoordinatesAndIsOneUndo() async throws {
    let model = EditorModel(), folder: URL
    folder = try fixture(model)
    defer { try? FileManager.default.removeItem(at: folder) }
    model.open(folder)
    try await settled(model)
    model.edit { $0.timing.master = 200; $0.contrast.red = 1.1; $0.contrast.blue = 0.9 }
    model.beginCrop()
    model.updateCropDraft(FrameCrop(aspect: .square, width: 0.5))
    model.commitCrop()
    model.changeOrientation(.rotateClockwise)
    try await settled(model)
    let before = try #require(model.project)
    let frame = try #require(model.activeFrame)
    let assets = try #require(model.assets)
    // Source crop is x=16...48, y=8...40; clockwise output pixel (0,0)
    // corresponds to source (16,39). The 64-pixel long edge rounds the 0.8% footprint to one pixel.
    let samples = try await model.imageService.region(folder.appendingPathComponent(frame.filename),
      rect: PixelRect(x: 16, y: 39, width: 1, height: 1))
    let expected = try NeutralTiming.solve(samples, calibration: before.calibration,
      adjustments: frame.adjustments, lut: assets.lut, p3Profile: assets.profile)
    let oldLab = representativeLab(try Pipeline.render(samples, calibration: before.calibration,
      adjustments: frame.adjustments, lut: assets.lut))
    model.toggleNeutralPicker()
    #expect(model.neutralPicking)
    model.pickNeutralDisplayed(x: 0, y: 0)
    #expect(!model.neutralPicking && model.isNeutralSampling)
    try await until("neutral sample") { !model.isNeutralSampling }
    #expect(model.errorMessage == nil)
    #expect(model.adjustments == expected)
    let finalLab = representativeLab(try Pipeline.render(samples, calibration: before.calibration,
      adjustments: model.adjustments, lut: assets.lut))
    #expect(hypot(oldLab.y, oldLab.z) > 1)
    #expect(hypot(finalLab.y, finalLab.z) <= 1.0001)
    #expect(abs(finalLab.x - oldLab.x) <= 0.5001)
    #expect(model.adjustments.timing.master == 200)
    #expect(model.adjustments.contrast == frame.adjustments.contrast)
    #expect(model.project?.calibration == before.calibration)
    #expect(model.activeFrame?.crop == frame.crop && model.orientation == frame.orientation)
    #expect(model.project?.frames[1] == before.frames[1])
    model.undo()
    #expect(model.project?.frames == before.frames)
    model.redo()
    #expect(model.adjustments == expected)
    #expect(model.flushSave())
    let saved = try ProjectStore.open(folder: folder)
    #expect(saved.frames.first?.adjustments == expected)
    try await settled(model)
  }

  @Test func unreachableFinalNeutralLeavesParametersAndUndoUntouched() async throws {
    let model = EditorModel()
    let folder = try fixture(model, pixel: SIMD3(1, 32768, 32768))
    defer { try? FileManager.default.removeItem(at: folder) }
    model.open(folder)
    try await settled(model)
    #expect(model.flushSave())
    let before = try #require(model.project)
    let undoRevision = model.undoRevision
    model.toggleNeutralPicker()
    model.pickNeutralDisplayed(x: 20, y: 20)
    try await until("unreachable Final neutral") { !model.isNeutralSampling }
    #expect(model.errorMessage == nil)
    #expect(model.project?.frames == before.frames && model.project?.calibration == before.calibration)
    #expect(model.undoRevision == undoRevision && !model.canUndo)
    #expect(!model.dirty && !model.neutralPicking)
    #expect(try ProjectStore.open(folder: folder).frames == before.frames)
  }

  @Test func finalSolverRunsOffMainActorAndReceivesCancellation() async throws {
    let gate = NeutralSolverGate()
    let model = EditorModel(neutralSolver: { _, _, adjustments, _, _ in
      try gate.solve(adjustments)
    })
    let folder = try fixture(model)
    defer { gate.release(); try? FileManager.default.removeItem(at: folder) }
    model.open(folder)
    try await settled(model)
    let before = try #require(model.project)
    let undoRevision = model.undoRevision
    model.toggleNeutralPicker()
    model.pickNeutralDisplayed(x: 20, y: 20)
    try await until("detached Final solver started") { gate.started }
    #expect(gate.ranOffMainThread && model.isNeutralSampling)
    model.toggleNeutralPicker()
    try await until("Final solver cancellation") { gate.cancelled }
    #expect(!model.isNeutralSampling && !model.neutralPicking)
    #expect(model.project?.frames == before.frames && model.project?.calibration == before.calibration)
    #expect(model.undoRevision == undoRevision)
    #expect(model.errorMessage == nil)
    #expect(model.flushSave())
  }

  @Test func sourceChangeDuringFinalSolveRejectsResultWithoutEditing() async throws {
    let gate = NeutralSolverGate()
    let model = EditorModel(neutralSolver: { _, _, adjustments, _, _ in
      try gate.solve(adjustments)
    })
    let folder = try fixture(model)
    defer { gate.release(); try? FileManager.default.removeItem(at: folder) }
    model.open(folder)
    try await settled(model)
    let before = try #require(model.project)
    let frame = try #require(model.activeFrame)
    let undoRevision = model.undoRevision
    model.toggleNeutralPicker()
    model.pickNeutralDisplayed(x: 20, y: 20)
    try await until("Final solver started before source change") { gate.started }
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 5)],
      ofItemAtPath: folder.appendingPathComponent(frame.filename).path)
    gate.release()
    try await until("source stamp revalidation") { !model.isNeutralSampling }
    #expect(model.errorMessage?.contains("源图像已改变") == true)
    #expect(model.project?.frames == before.frames && model.project?.calibration == before.calibration)
    #expect(model.undoRevision == undoRevision)
    #expect(!model.dirty)
  }

  @Test func pendingNeutralSampleCannotOverwriteNewEditOrNextFrame() async throws {
    let model = EditorModel(), folder: URL
    folder = try fixture(model)
    defer { try? FileManager.default.removeItem(at: folder) }
    model.open(folder)
    try await settled(model)
    model.toggleNeutralPicker()
    model.pickNeutralDisplayed(x: 20, y: 20)
    model.edit { $0.timing.red = 123 }
    try await settled(model)
    #expect(model.adjustments.timing.red == 123)
    #expect(!model.isNeutralSampling && !model.neutralPicking)
    let before = try #require(model.project?.frames)
    model.toggleNeutralPicker()
    model.pickNeutralDisplayed(x: 20, y: 20)
    model.select(before[1].id)
    try await settled(model)
    #expect(model.project?.frames == before)
    #expect(model.errorMessage == nil)
    #expect(model.flushSave())
  }

  @Test func displayCacheObeysByteBudgetAndLeastRecentUse() async throws {
    let model = EditorModel(), folder: URL
    folder = try fixture(model, count: 3)
    defer { try? FileManager.default.removeItem(at: folder) }
    model.open(folder)
    try await settled(model)
    let image = try #require(model.previewImage)
    let bytes = image.bytesPerRow * image.height
    var cache = PreviewPresentationCache(byteLimit: bytes * 2, countLimit: 3)
    let frames = try #require(model.project?.frames)
    let keys = try frames.map { frame in
      PreviewPresentationKey(source: try PreviewSourceStamp(url: folder.appendingPathComponent(frame.filename)),
        frameID: frame.id, calibration: FilmCalibration(), adjustments: .init(),
        orientation: .identity, crop: nil, stage: .final)
    }
    for key in keys.prefix(2) {
      cache.store(.init(key: key, image: image, sourceWidth: 64, sourceHeight: 48))
    }
    #expect(cache.image(for: keys[0]) != nil)
    cache.store(.init(key: keys[2], image: image, sourceWidth: 64, sourceHeight: 48))
    #expect(cache.bytes == bytes * 2 && cache.entries.count == 2)
    #expect(cache.image(for: keys[1]) == nil)
    #expect(cache.image(for: keys[0]) != nil && cache.image(for: keys[2]) != nil)
    #expect(model.flushSave())
  }
}

/// A bounded stand-in for a numerical solve, so the test changes state while
/// work is actually in flight rather than racing the TIFF read or scheduler.
private final class NeutralSolverGate: @unchecked Sendable {
  private let condition = NSCondition()
  private var didStart = false
  private var didCancel = false
  private var offMainThread = false
  private var released = false

  var started: Bool {
    condition.lock(); defer { condition.unlock() }
    return didStart
  }
  var cancelled: Bool {
    condition.lock(); defer { condition.unlock() }
    return didCancel
  }
  var ranOffMainThread: Bool {
    condition.lock(); defer { condition.unlock() }
    return offMainThread
  }
  func release() {
    condition.lock(); defer { condition.unlock() }
    released = true
    condition.broadcast()
  }
  func solve(_ adjustments: FrameAdjustments) throws -> FrameAdjustments {
    condition.lock(); defer { condition.unlock() }
    didStart = true
    offMainThread = !Thread.isMainThread
    let deadline = Date(timeIntervalSinceNow: 5)
    while !released, !Task.isCancelled, Date() < deadline {
      condition.wait(until: Date(timeIntervalSinceNow: 0.01))
    }
    if Task.isCancelled {
      didCancel = true
      throw CancellationError()
    }
    guard released else { throw PrintroomError.invalid("Test solver gate timed out") }
    var result = adjustments
    result.timing.red = 17
    return result
  }
}
