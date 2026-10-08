import CoreGraphics
import Foundation
import PrintroomCore
import Testing
@testable import PrintroomApp

@Suite(.serialized) @MainActor
struct FilmBasePreviewTests {
  private func wait(_ ready: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(15))
    while !ready(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    try #require(ready())
  }
  private func fixture() async throws -> (EditorModel, URL) {
    let model = EditorModel()
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FilmBasePreview-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let profile = try #require(model.assets).profile
    for i in 0..<2 {
      try TIFFCodec.write(url: folder.appendingPathComponent("\(i).tif"), width: 32, height: 24,
        profile: profile) { rows in
        (0..<(rows.count * 32)).flatMap { _ in [UInt16(12000 + i * 1000), 23000, 34000] }
      }
    }
    model.open(folder)
    try await waitForProxyImport(model)
    try await wait { model.hasImage && !model.isRendering && model.thumbnails.count == 2 }
    return (model, folder)
  }
  private func data(_ image: CGImage) throws -> Data {
    try #require(image.dataProvider?.data) as Data
  }

  @Test func newRollUsesLinearSourceForPreviewAndThumbnailsUntilSuccessfulSelection() async throws {
    let (model, folder) = try await fixture()
    defer { model.returnHome(); try? FileManager.default.removeItem(at: folder) }
    #expect(!model.hasFilmBase && !model.canAdjustColors && !model.canPickNeutral)
    #expect(model.canOpenRollTiming && !model.canStartRollTiming)
    model.copyParameters()
    #expect(!model.canApply)
    #expect(model.histogram == nil)
    let original = try #require(model.previewImage)
    let source = try await model.imageService.preview(folder.appendingPathComponent("0.tif"))
    let expected = try DisplayImage.make(source.0, profile: nil, original: true)
    #expect(try data(original) == data(expected))
    #expect(original.colorSpace?.name == CGColorSpace.extendedLinearDisplayP3)
    let activeID = try #require(model.activeFrame).id
    let thumbnail = try #require(model.thumbnails[activeID])
    #expect(try data(thumbnail) == data(expected))
    model.toggleNeutralPicker()
    #expect(!model.neutralPicking)
    model.startAdjustmentKey("w", contrast: false, shift: false, isRepeat: false) { true }
    #expect(model.adjustments.timing.master == 0 && !model.canUndo)
    model.showMissingFilmBaseDialog = true
    model.beginFilmBaseSelection()
    #expect(model.sampling && !model.showMissingFilmBaseDialog)
    model.sampling = false
    #expect(!model.hasFilmBase && model.histogram == nil)
    model.stage = .d3 // A stale session stage must not leak into first calibrated view.
    try await wait { model.hasImage && !model.isRendering }
    #expect(try data(#require(model.previewImage)) == data(expected))
    model.sampleBase(.init(x: 0, y: 0, width: 1, height: 1))
    try await wait { model.errorMessage != nil }
    #expect(!model.hasFilmBase && model.histogram == nil)
    model.errorMessage = nil
    model.sampleBase(.init(x: 0, y: 0, width: 4, height: 4))
    try await wait { model.hasFilmBase && !model.isRendering && model.histogram != nil }
    #expect(model.stage == .final && model.canAdjustColors && model.canPickNeutral)
    #expect(!model.showRollTimingDialog && !model.isAnalyzingRollTiming)
    #expect(try data(#require(model.previewImage)) != data(expected))
    let saved = try #require(model.project?.calibration)
    model.undo()
    try await wait { !model.isRendering }
    #expect(!model.hasFilmBase && model.histogram == nil)
    #expect(try data(#require(model.previewImage)) == data(expected))
    model.redo()
    try await wait { !model.isRendering && model.histogram != nil }
    #expect(model.project?.calibration == saved)
    #expect(model.flushSave())
    model.open(folder)
    try await waitForProxyImport(model)
    try await wait { model.hasImage && !model.isRendering }
    #expect(model.project?.calibration == saved && model.histogram != nil)
  }

  @Test func storedBaseSurvivesChangedOrMissingSourceAndAnalysisUsesAvailableFrames() async throws {
    let (model, folder) = try await fixture()
    defer { model.returnHome(); try? FileManager.default.removeItem(at: folder) }
    model.sampleBase(.init(x: 0, y: 0, width: 4, height: 4))
    try await wait { model.hasFilmBase && !model.isRendering }
    let saved = try #require(model.project?.calibration)
    let baseURL = folder.appendingPathComponent("0.tif")
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: baseURL.path)
    model.open(folder)
    try await waitForProxyImport(model)
    try await wait { model.hasImage && !model.isRendering }
    #expect(model.project?.calibration == saved && model.canStartRollTiming)
    #expect(model.errorMessage == nil && model.project?.calibrationNeedsReview == false)
    try FileManager.default.removeItem(at: baseURL)
    model.open(folder)
    try await waitForProxyImport(model)
    try await wait { model.hasImage && !model.isRendering }
    #expect(model.project?.calibration == saved && model.canStartRollTiming)
    model.project?.calibrationNeedsReview = true // Legacy values must not disable consumers.
    model.rollTimingRunner = { roll, folder, _, _, _ in
      RollTimingResult(timing: .init(red: 10), sources: try roll.frames.filter { !$0.isMissing }
        .map { try SourceStamp(url: folder.appendingPathComponent($0.filename)) })
    }
    model.startRollTiming()
    try await wait { !model.isAnalyzingRollTiming }
    #expect(model.rollTimingError == nil)
    model.applyRollTiming(preserveEdited: false)
    #expect(model.adjustments.timing.red == 10 && model.project?.calibration == saved)
  }

  @Test func cmosSwitchResamplesCurrentPixelsAtSavedSelectionDespiteChangedFingerprint() async throws {
    let (model, folder) = try await fixture()
    defer { model.returnHome(); try? FileManager.default.removeItem(at: folder) }
    model.sampleBase(.init(x: 2, y: 3, width: 4, height: 4))
    try await wait { model.hasFilmBase && !model.isRendering }
    let before = try #require(model.project?.calibration)
    let url = folder.appendingPathComponent("0.tif")
    try FileManager.default.removeItem(at: url)
    let samples: [UInt16] = (0..<(32 * 24)).flatMap { _ in [15000, 25000, 35000] }
    let assets = try #require(model.assets)
    try TIFFCodec.write(url: url, width: 32, height: 24, profile: assets.profile) { rows in
      Array(samples[(rows.lowerBound * 32 * 3)..<(rows.upperBound * 32 * 3)])
    }
    #expect(model.project?.calibration == before)
    let target: MatrixPreset = model.cmosMatrix == .identity ? .sonyA7CII : .identity
    model.setMatrixPreset(target, kind: .cmos)
    try await wait { model.cmosMatrix == target && !model.isRendering }
    let rect = try #require(before.selection)
    let expected = try Pipeline.calibrate(image: LinearImage(width: 32, height: 24, samples: samples),
      rect: rect, matrix: before.matrix,
      sourceFrameID: before.sourceFrameID, cmosMatrix: target)
    #expect(model.project?.calibration == expected && model.errorMessage == nil)
    model.undo()
    #expect(model.project?.calibration == before)
  }

  @Test func originalRendererBypassesMatricesAdjustmentsLUTAndStatisticsAcrossDirections() async throws {
    let assets = try #require(EditorModel().assets)
    let input = PixelBuffer(width: 3, height: 2, pixels: (0..<6).map {
      SIMD4<Float>(Float($0 + 1) / 10, 0.35, 0.62, 1)
    })
    var calibration = FilmCalibration()
    calibration.cmosMatrix = .sonyA7CII
    calibration.matrix = .ledLightSource
    let adjustments = FrameAdjustments(timing: .init(master: 200, red: -90),
      contrast: .init(master: 1.6), cineonLogLUT: .fujifilm3513DI)
    let renderer = PreviewRenderService()
    for direction in FrameOrientation.allCases {
      let rendered = try await renderer.render(input, calibration: calibration, adjustments: adjustments,
        assets: assets, stage: .final, original: true, orientation: direction, includeHistogram: true)
      let expected = try direction.transform(input)
      #expect(rendered.pixels.pixels == expected.pixels && rendered.histogram == nil)
      #expect(rendered.pixels.width == expected.width && rendered.pixels.height == expected.height)
    }
  }
}
