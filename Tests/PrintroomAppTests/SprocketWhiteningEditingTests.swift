import AppKit
import Foundation
import PrintroomCore
import Testing
@testable import PrintroomApp

@Suite(.serialized) @MainActor
struct SprocketWhiteningEditingTests {
  private func until(_ ready: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !ready(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    try #require(ready())
  }
  @Test func rollSettingIgnoresSelectionAndSliderGestureIsOneUndo() throws {
    let model = EditorModel()
    var roll = RollProject()
    roll.frames = [FrameRecord(filename: "A.tiff", crop: .init(width: 0.5)), FrameRecord(filename: "B.tiff")]
    roll.calibration.baseRGB = SIMD3(repeating: 0.2)
    roll.calibration.gainRGB = SIMD3(repeating: 3.75)
    model.project = roll
    model.selection.click(roll.frames[0].id, ordered: roll.frames.map(\.id))
    #expect(model.canAdjustSprocketWhitening)
    model.setSprocketWhitening(.init(enabled: true))
    #expect(model.sprocketWhitening.enabled)
    model.selection.click(roll.frames[1].id, ordered: roll.frames.map(\.id))
    #expect(model.sprocketWhitening.enabled)
    let undoRevision = model.undoRevision
    model.beginAdjustment()
    for value in [35.0, 55, 90] { model.setSprocketWhitening(.init(enabled: true, thresholdPercent: value)) }
    #expect(model.undoRevision == undoRevision)
    model.endAdjustment()
    #expect(model.undoRevision == undoRevision + 1)
    model.undo()
    #expect(model.sprocketWhitening == .init(enabled: true))
    model.undo()
    #expect(model.sprocketWhitening == .init())
    model.redo(); model.redo()
    #expect(model.sprocketWhitening.thresholdPercent == 90)
    #expect(model.project?.frames == roll.frames)
    #expect(model.project?.calibration == roll.calibration)
    model.project?.calibrationNeedsReview = true
    #expect(model.canAdjustSprocketWhitening)
    model.setSprocketWhitening(.init(enabled: false, thresholdPercent: 90))
    #expect(!model.sprocketWhitening.enabled)
  }
  @Test func missingCropOrCalibrationCannotEnableAndInvalidValueDoesNotCreateUndo() {
    let model = EditorModel()
    var roll = RollProject()
    roll.frames = [FrameRecord(filename: "A.tiff")]
    model.project = roll
    model.setSprocketWhitening(.init(enabled: true))
    #expect(!model.sprocketWhitening.enabled && !model.canUndo)
    model.project?.frames[0].crop = .init(width: 0.5)
    model.setSprocketWhitening(.init(enabled: true))
    #expect(!model.sprocketWhitening.enabled)
    model.project?.calibration.baseRGB = SIMD3(repeating: 0.2)
    model.setSprocketWhitening(.init(enabled: true, thresholdPercent: 400))
    #expect(!model.sprocketWhitening.enabled && !model.canUndo)
    #expect(model.errorMessage != nil)
  }
  @Test func fullPreviewUsesSavedProtectionWhileHistogramAndCroppedPixelsStayUnchanged() async throws {
    let assets = try #require(EditorModel().assets)
    var c = FilmCalibration()
    c.baseRGB = SIMD3(repeating: 0.2)
    c.gainRGB = SIMD3(repeating: 3.75)
    let raw = PixelBuffer(width: 96, height: 72, pixels: Array(repeating: SIMD4(0.6, 0.6, 0.6, 1), count: 96 * 72))
    let crop = FrameCrop(aspect: .square, centerX: 0.4, width: 0.5, angleDegrees: 4)
    let renderer = PreviewRenderService()
    for direction in FrameOrientation.allCases {
      for choice in CineonLogLUT.allCases {
        var edits = FrameAdjustments()
        edits.cineonLogLUT = choice
        let before = try await renderer.render(raw, calibration: c, adjustments: edits, assets: assets,
          orientation: direction, sourceWidth: 96, sourceHeight: 72, includeHistogram: true, histogramCrop: crop)
        let after = try await renderer.render(raw, calibration: c, adjustments: edits, assets: assets,
          orientation: direction, sourceWidth: 96, sourceHeight: 72, includeHistogram: true, histogramCrop: crop,
          sprocketWhitening: .init(enabled: true), protectedCrop: crop)
        #expect(before.histogram == after.histogram)
        #expect(after.pixels.pixels.contains(SIMD4(repeating: 1)))
        #expect(before.pixels.pixels != after.pixels.pixels)
        let croppedBefore = try await renderer.render(raw, calibration: c, adjustments: edits, assets: assets,
          orientation: direction, crop: crop, sourceWidth: 96, sourceHeight: 72)
        let croppedAfter = try await renderer.render(raw, calibration: c, adjustments: edits, assets: assets,
          orientation: direction, crop: crop, sourceWidth: 96, sourceHeight: 72,
          sprocketWhitening: .init(enabled: true), protectedCrop: crop)
        #expect(croppedBefore.pixels.pixels == croppedAfter.pixels.pixels)
        let noCrop = try await renderer.render(raw, calibration: c, adjustments: edits, assets: assets,
          orientation: direction, sprocketWhitening: .init(enabled: true))
        #expect(noCrop.pixels.pixels == before.pixels.pixels)
      }
    }
  }
  @Test func modelSavesRollSettingAndRejectsStaleFullPreviewOnRapidChanges() async throws {
    let model = EditorModel()
    let assets = try #require(model.assets)
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprocket-editing-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("A.tiff")
    try TIFFCodec.write(url: source, width: 96, height: 72, profile: assets.profile) { rows in
      rows.flatMap { y in (0..<96).flatMap { x in [UInt16](repeating: x < 4 && y < 4 ? 13107 : 40000, count: 3) } }
    }
    var roll = try ProjectStore.open(folder: folder)
    roll.calibration = try Pipeline.calibrate(image: TIFFCodec.read(url: source), rect: .init(x: 0, y: 0, width: 4, height: 4),
      matrix: .identity, sourceFrameID: roll.frames[0].id)
    roll.frames[0].crop = FrameCrop(aspect: .square, width: 0.5, angleDegrees: 5)
    try ProjectStore.save(roll, folder: folder, expectedModification: nil)
    model.open(source)
    try await waitForProxyImport(model)
    try await until { model.hasImage && !model.isRendering }
    model.cropPreviewEnabled = false
    try await until { !model.isRendering }
    let baseline = try #require(model.previewImage?.dataProvider?.data) as Data
    let histogram = model.histogram
    for value in [25.0, 35, 55] { model.setSprocketWhitening(.init(enabled: true, thresholdPercent: value)) }
    model.setSprocketWhitening(.init(enabled: false, thresholdPercent: 55))
    try await until { !model.isRendering }
    #expect((try #require(model.previewImage?.dataProvider?.data) as Data) == baseline)
    model.setSprocketWhitening(.init(enabled: true, thresholdPercent: 25))
    try await until { !model.isRendering }
    #expect((try #require(model.previewImage?.dataProvider?.data) as Data) != baseline)
    #expect(model.histogram == histogram)
    #expect(model.flushSave())
    #expect(try ProjectStore.open(folder: folder).sprocketWhitening == .init(enabled: true))
    #expect(model.errorMessage == nil)
  }
}
