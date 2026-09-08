import AppKit
import Foundation
import PrintroomCore
import Testing

@testable import PrintroomApp

@Suite(.serialized) @MainActor
struct EditingV2Tests {
  private func fixture(_ name: String = "PrintroomV2") throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  private func write(_ name: String, folder: URL, width: Int = 12, height: Int = 8,
                     profile: Data, value: UInt16 = 32768) throws {
    try TIFFCodec.write(url: folder.appendingPathComponent(name), width: width, height: height, profile: profile) {
      rows in [UInt16](repeating: value, count: rows.count * width * 3)
    }
  }

  private func until(_ message: String, _ ready: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(8))
    while !ready(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(15)) }
    #expect(ready(), "\(message)")
    guard ready() else { throw PrintroomError.invalid(message) }
  }

  @Test func directionUndoRedoCopyApplyOutputSettingsAndReopen() async throws {
    let model = EditorModel()
    let assets = try #require(model.assets)
    let folder = try fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    for name in ["A.tif", "B.tif", "C.tif"] { try write(name, folder: folder, profile: assets.profile) }
    model.open(folder)
    let frames = try #require(model.project?.frames)
    try await until("initial preview", { model.histogram != nil })
    #expect(model.sourceWidth == 12 && model.sourceHeight == 8)
    model.changeOrientation(.rotateClockwise)
    model.changeOrientation(.flipHorizontal)
    #expect(model.orientation == .transpose)
    #expect(model.displayWidth == 8 && model.displayHeight == 12)
    model.undo()
    #expect(model.orientation == .rotate90CW)
    model.redo()
    #expect(model.orientation == .transpose)
    model.edit { $0.timing.red = 31; $0.contrast.blue = 1.2 }
    model.copyParameters()
    model.select(frames[1].id)
    model.changeOrientation(.flipVertical)
    model.select(frames[2].id)
    model.changeOrientation(.rotateCounterclockwise)
    model.selectAll()
    let before = try #require(model.project)
    model.applyParameters()
    let applied = try #require(model.project)
    #expect(applied.frames.map(\.orientation) == before.frames.map(\.orientation))
    #expect(applied.frames.allSatisfy { $0.adjustments.timing.red == 31 && $0.adjustments.contrast.blue == 1.2 })
    model.undo()
    #expect(model.project?.frames == before.frames)
    model.redo()
    #expect(model.project?.frames == applied.frames)
    model.setOutputProfile(.proPhoto)
    model.setOutputCompression(.deflate)
    #expect(model.flushSave())
    let reopened = try ProjectStore.open(folder: folder)
    #expect(reopened.frames == applied.frames)
    #expect(reopened.exportSettings.profile == .proPhoto)
    #expect(reopened.exportSettings.compression == .deflate)
    #expect(reopened.schemaVersion == 3)
    try await until("oriented preview", { model.histogram != nil && !model.isRendering })
    #expect(model.previewImage?.width == 8 && model.previewImage?.height == 12)
    #expect(model.histogram?.pixelCount == 96)
    #expect(model.errorMessage == nil)
  }

  @Test func rapidFrameAndStageChangesNeverPublishPreviousHistogram() async throws {
    let model = EditorModel()
    let assets = try #require(model.assets)
    let folder = try fixture("PrintroomHistogramRace")
    defer { try? FileManager.default.removeItem(at: folder) }
    try write("A.tif", folder: folder, width: 512, height: 256, profile: assets.profile, value: 8192)
    try write("B.tif", folder: folder, width: 48, height: 32, profile: assets.profile, value: 49152)
    model.open(folder)
    model.stage = .l0
    let frames = try #require(model.project?.frames)
    try await until("first histogram", { model.histogram?.stage == .l0 })
    #expect(model.histogram?.pixelCount == 512 * 256)
    for index in 0..<12 {
      model.select(frames[index % 2].id)
      model.stage = index % 2 == 0 ? .d3 : .final
      model.edit { $0.timing.master = index }
    }
    model.select(frames[1].id)
    model.stage = .l0
    #expect(model.histogram == nil)
    try await until("latest frame histogram", { model.histogram?.stage == .l0 })
    let result = try #require(model.histogram)
    #expect(model.activeFrame?.id == frames[1].id)
    #expect(result.pixelCount == 48 * 32)
    #expect(result.channels.allSatisfy { $0.bins[192] == 48 * 32 && $0.bins.reduce(0, +) == 48 * 32 })
    // Give cancelled, more expensive A work an opportunity to finish; it still cannot publish.
    try await Task.sleep(for: .milliseconds(200))
    #expect(model.histogram == result)
    model.stage = .d2
    model.edit { $0.timing.master = 200 }
    #expect(model.histogram == nil)
    try await until("latest adjusted stage histogram", { model.histogram?.stage == .d2 })
    let adjusted = try #require(model.histogram)
    let value = try Pipeline.process(SIMD3<Float>(repeating: Float(49152) / 65535),
      calibration: try #require(model.project).calibration,
      adjustments: model.adjustments, lut: assets.lut, stage: .d2)
    let bin = min(255, Int(value.x * 256))
    #expect(adjusted.channels[0].bins[bin] == 48 * 32)
    #expect(adjusted.unit.contains("1024"))
    #expect(model.errorMessage == nil)
  }

  @Test func displayedSamplingMapsToOriginalAfterRotationAndFlip() async throws {
    let model = EditorModel()
    let assets = try #require(model.assets)
    let folder = try fixture("PrintroomDirectionSampling")
    defer { try? FileManager.default.removeItem(at: folder) }
    let width = 12, height = 8
    let samples: [UInt16] = (0..<(width * height * 3)).map { UInt16(12000 + $0 * 80) }
    let url = folder.appendingPathComponent("source.tif")
    try TIFFCodec.write(url: url, width: width, height: height, profile: assets.profile) { rows in
      Array(samples[(rows.lowerBound * width * 3)..<(rows.upperBound * width * 3)])
    }
    model.open(folder)
    model.stage = .l0
    try await until("sampling preview", { model.histogram != nil })
    model.changeOrientation(.rotateClockwise)
    model.changeOrientation(.flipVertical)
    #expect(model.orientation == .transverse)
    let displayed = PixelRect(x: 1, y: 3, width: 4, height: 4)
    let original = try FrameOrientation.transverse.inverseRect(displayed, sourceWidth: width, sourceHeight: height)
    model.sampleDisplayedBase(displayed)
    try await until("calibration completed", { model.project?.calibration.isCalibrated == true })
    let calibration = try #require(model.project?.calibration)
    #expect(calibration.selection == original)
    #expect(calibration.sourceWidth == width && calibration.sourceHeight == height)
    let expected = try Pipeline.calibrate(image: TIFFCodec.read(url: url), rect: original,
      matrix: .identity, sourceFrameID: model.activeFrame?.id)
    #expect(calibration == expected)
    let sourcePoint = model.orientation.inversePixel(x: 2, y: 4, sourceWidth: width, sourceHeight: height)
    model.readDisplayedPixel(x: 2, y: 4)
    try await until("mapped pixel readout", { model.sampleReadout.contains("(\(sourcePoint.x), \(sourcePoint.y))") })
    model.undo()
    #expect(model.project?.calibration.isCalibrated == false)
    #expect(model.orientation == .transverse)
    model.redo()
    #expect(model.project?.calibration == calibration)
    #expect(model.flushSave())
    let reopened = try ProjectStore.open(folder: folder)
    #expect(reopened.calibration == calibration)
    #expect(reopened.frames[0].orientation == .transverse)
    try await until("post undo preview", { model.histogram != nil })
    #expect(model.errorMessage == nil)
  }

  @Test func nativeDetailDoesNotReplaceWholePhotoHistogram() async throws {
    let model = EditorModel()
    let assets = try #require(model.assets)
    let folder = try fixture("PrintroomWholeHistogram")
    defer { try? FileManager.default.removeItem(at: folder) }
    try write("A.tif", folder: folder, width: 128, height: 96, profile: assets.profile)
    model.open(folder)
    model.stage = .l0
    try await until("whole photo histogram", { model.histogram != nil })
    let whole = try #require(model.histogram)
    model.changeOrientation(.rotateClockwise)
    try await until("rotated histogram", { model.histogram != nil })
    #expect(model.histogram == whole)
    model.requestDetail(PixelRect(x: 2, y: 3, width: 20, height: 16))
    try await until("native detail tile", { model.detailImage != nil && !model.isDetailLoading })
    #expect(model.detailImage?.width == 20 && model.detailImage?.height == 16)
    #expect(model.histogram == whole)
    #expect(model.histogram?.pixelCount == 128 * 96)
    model.stage = .d0
    #expect(model.detailImage == nil && model.histogram == nil)
    try await until("new diagnostic histogram", { model.histogram?.stage == .d0 })
    #expect(model.histogram?.pixelCount == 128 * 96)
    #expect(model.errorMessage == nil)
  }

  @Test func reloadSameRollDiscardsInFlightCalibration() async throws {
    let model = EditorModel()
    let assets = try #require(model.assets)
    let folder = try fixture("PrintroomDiscardSampling")
    defer { try? FileManager.default.removeItem(at: folder) }
    try write("source.tif", folder: folder, profile: assets.profile)
    model.open(folder)
    try await until("initial sampling preview", { model.histogram != nil })
    #expect(model.project?.calibration.isCalibrated == false)
    model.sampleBase(PixelRect(x: 1, y: 1, width: 4, height: 4))
    // Both commands happen in the same MainActor turn, before the asynchronous read starts.
    model.reloadDiscardingUnsaved()
    try await until("reloaded preview", { model.histogram != nil })
    try await Task.sleep(for: .milliseconds(150))
    #expect(model.project?.calibration.isCalibrated == false)
    #expect(try ProjectStore.open(folder: folder).calibration.isCalibrated == false)
    #expect(model.errorMessage == nil)
  }

  @Test func previousFrameReadFailureCannotShowOnNextFrame() async throws {
    let model = EditorModel()
    let assets = try #require(model.assets)
    let folder = try fixture("PrintroomStaleReadFailure")
    defer { try? FileManager.default.removeItem(at: folder) }
    for name in ["A.tif", "B.tif"] { try write(name, folder: folder, profile: assets.profile) }
    model.open(folder)
    let frames = try #require(model.project?.frames)
    try await until("readout initial preview", { model.histogram != nil })
    model.readPixel(x: 100, y: 100)
    model.select(frames[1].id)
    try await until("new frame preview", { model.histogram != nil })
    try await Task.sleep(for: .milliseconds(100))
    #expect(model.activeFrame?.id == frames[1].id)
    #expect(model.errorMessage == nil)
    #expect(!model.sampleReadout.contains("(100, 100)"))
  }

  @Test func failedNextFrameLoadClearsCancelledRenderingState() async throws {
    let model = EditorModel()
    let assets = try #require(model.assets)
    let folder = try fixture("PrintroomFailedNextFrame")
    defer { try? FileManager.default.removeItem(at: folder) }
    try write("A.tif", folder: folder, profile: assets.profile)
    try Data("broken TIFF".utf8).write(to: folder.appendingPathComponent("B.tif"))
    model.open(folder)
    let frames = try #require(model.project?.frames)
    try await until("valid first preview", { model.histogram != nil })
    model.stage = .d1
    #expect(model.isRendering)
    model.select(frames[1].id)
    try await until("bad source failure", { !model.isLoading && model.errorMessage != nil })
    #expect(model.previewImage == nil)
    #expect(model.histogram == nil)
    #expect(!model.isRendering)
    #expect(!model.isHistogramUpdating)
  }

  @Test func directionChangesNeverExposeOldImageWithNewGeometry() async throws {
    let model = EditorModel()
    let assets = try #require(model.assets)
    let folder = try fixture("PrintroomDirectionGeometry")
    defer { try? FileManager.default.removeItem(at: folder) }
    try write("source.tif", folder: folder, profile: assets.profile)
    model.open(folder)
    try await until("initial geometry preview", { model.histogram != nil })
    model.changeOrientation(.rotateClockwise)
    if let visible = model.previewImage {
      #expect(visible.width * model.displayHeight == visible.height * model.displayWidth)
    }
    try await until("rotated geometry preview", { model.histogram != nil })
    model.undo()
    if let visible = model.previewImage {
      #expect(visible.width * model.displayHeight == visible.height * model.displayWidth)
    }
    try await until("undo geometry preview", { model.histogram != nil })
    #expect(model.orientation == .identity)
    #expect(model.previewImage?.width == 12 && model.previewImage?.height == 8)
  }

  @Test func relocationUndoRedoPersistsActualSelectionAndStableEdits() async throws {
    let model = EditorModel()
    let assets = try #require(model.assets)
    let folder = try fixture("PrintroomRelocateUndoSelection")
    defer { try? FileManager.default.removeItem(at: folder) }
    for name in ["A-other.tif", "B-old.tif"] { try write(name, folder: folder, profile: assets.profile) }
    let oldURL = folder.appendingPathComponent("B-old.tif")
    let newURL = folder.appendingPathComponent("C-renamed.tif")
    model.open(oldURL)
    let stableID = try #require(model.activeFrame?.id)
    model.edit { $0.timing.green = 51 }
    model.changeOrientation(.rotateClockwise)
    #expect(model.flushSave())
    try await until("old source preview settled", { model.histogram != nil })
    try FileManager.default.moveItem(at: oldURL, to: newURL)
    model.reloadDiscardingUnsaved()
    #expect(model.project?.frames.first(where: { $0.id == stableID })?.isMissing == true)
    model.relocate(stableID, to: newURL)
    #expect(model.activeFrame?.id == stableID)
    #expect(model.adjustments.timing.green == 51)
    #expect(model.orientation == .rotate90CW)
    model.undo()
    #expect(model.project?.frames.first(where: { $0.id == stableID })?.isMissing == true)
    #expect(model.project?.lastActiveFrameID == model.selection.activeFrameID)
    model.redo()
    let restored = try #require(model.project)
    let available = Set(restored.frames.filter { !$0.isMissing }.map(\.id))
    #expect(model.selection.selectedFrameIDs.isSubset(of: available))
    #expect(restored.lastActiveFrameID == model.selection.activeFrameID)
    #expect(restored.frames.first(where: { $0.id == stableID })?.filename == "C-renamed.tif")
    #expect(restored.frames.first(where: { $0.id == stableID })?.adjustments.timing.green == 51)
    #expect(restored.frames.first(where: { $0.id == stableID })?.orientation == .rotate90CW)
    #expect(model.flushSave())
    let reopened = try ProjectStore.open(folder: folder)
    #expect(reopened.lastActiveFrameID == model.selection.activeFrameID)
    try await until("relocation final preview", { model.histogram != nil })
    #expect(model.errorMessage == nil)
  }

  @Test func exportWhileEditingUsesCapturedTargetsDirectionAdjustmentsAndProfile() async throws {
    let model = EditorModel()
    let assets = try #require(model.assets)
    let folder = try fixture("PrintroomExportEditSnapshot")
    defer { try? FileManager.default.removeItem(at: folder) }
    for name in ["A.tif", "B.tif"] { try write(name, folder: folder, profile: assets.profile) }
    let destination = folder.appendingPathComponent("Exports")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    model.open(folder)
    let firstID = try #require(model.activeFrame?.id)
    let captured = try #require(model.project)
    model.startExport(targetIDs: [firstID], directory: destination)
    #expect(model.isExporting)
    // These commands run before the export's Task gets its first actor turn.
    model.edit { $0.timing.master = 200; $0.contrast.red = 2 }
    model.changeOrientation(.rotateClockwise)
    model.setOutputProfile(.sRGB)
    model.setOutputCompression(.deflate)
    model.selectAll()
    try await until("snapshot export completed", { !model.isExporting })
    let summary = try #require(model.exportSummary)
    #expect(summary.completedCount == 1 && summary.failedCount == 0)
    #expect(summary.results.count == 1 && summary.results[0].id == firstID)
    let outputURL = try #require(summary.results[0].destination)
    let output = try TIFFCodec.read(url: outputURL)
    #expect(output.width == 12 && output.height == 8)
    #expect(output.embeddedProfileName == "P3 D65 Gamma 2.6")
    let expected = try Pipeline.process(SIMD3<Float>(repeating: Float(32768) / 65535),
      calibration: captured.calibration, adjustments: captured.frames[0].adjustments, lut: assets.lut)
    for channel in 0..<3 {
      let actual: Float = Float(output.samples[channel]) / Float(65535)
      let difference: Float = abs(actual - expected[channel])
      let tolerance: Float = 0.0002 + Float(0.5) / Float(65535)
      #expect(difference <= tolerance)
    }
    #expect(model.orientation == .rotate90CW)
    #expect(model.adjustments.timing.master == 200)
    #expect(model.exportSettings.profile == .sRGB && model.exportSettings.compression == .deflate)
    try await until("edited preview after export", { model.histogram != nil })
    #expect(model.errorMessage == nil)
  }
}
