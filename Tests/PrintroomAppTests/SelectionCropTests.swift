import AppKit
import Foundation
import PrintroomCore
import Testing

@testable import PrintroomApp

@Suite(.serialized) @MainActor
struct SelectionCropTests {
  private func fixture(count: Int, profile: Data) throws -> URL {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PrintroomSourceCrop-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let width = 84, height = 60
    // The unequal channel slopes expose both a wrong source region and an extra
    // reflection/quarter turn; a uniform or centered symmetric image would not.
    var samples = [UInt16]()
    for y in 0..<height {
      for x in 0..<width {
        samples.append(UInt16(4000 + 300 * x + 71 * y))
        samples.append(UInt16(8000 + 83 * x + 350 * y))
        samples.append(UInt16(12000 + 190 * x + 123 * y))
      }
    }
    let immutableSamples = samples
    for index in 0..<count {
      try TIFFCodec.write(url: folder.appendingPathComponent("\(index).tif"), width: width,
        height: height, profile: profile) { rows in
          Array(immutableSamples[(rows.lowerBound * width * 3)..<(rows.upperBound * width * 3)])
        }
    }
    return folder
  }

  private func until(_ message: String, _ ready: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(8))
    while !ready(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(15)) }
    #expect(ready(), "\(message)")
    guard ready() else { throw PrintroomError.invalid(message) }
  }

  @Test func cropPreviewOnlyChangesDisplayAndSurvivesNavigation() async throws {
    let model = EditorModel()
    #expect(model.cropPreviewEnabled)
    let assets = try #require(model.assets)
    let folder = try fixture(count: 2, profile: assets.profile)
    defer { try? FileManager.default.removeItem(at: folder) }
    var roll = try ProjectStore.open(folder: folder)
    for index in roll.frames.indices {
      roll.frames[index].crop = FrameCrop(aspect: .square, centerX: 0.42,
        width: 0.5, angleDegrees: 4)
      roll.frames[index].orientation = .rotate90CW
      roll.frames[index].adjustments.timing.red = 24
    }
    try ProjectStore.save(roll, folder: folder, expectedModification: roll.loadedModificationDate)
    model.open(folder.appendingPathComponent(roll.frames[0].filename))
    try await waitForProxyImport(model)
    try await prepareCalibratedPreview(model)
    try await until("cropped preview ready", { !model.isLoading && !model.isRendering && model.histogram != nil })
    let frames = model.project?.frames
    let calibration = model.project?.calibration
    let exportSettings = model.exportSettings
    let canUndo = model.canUndo
    for stage in [PipelineStage.final, .d3] {
      model.histogramStage = stage
      try await until("statistics ready", { !model.isRendering })
      let histogram = try #require(model.histogram)
      let croppedWidth = model.previewImage?.width
      model.cropPreviewEnabled = false
      #expect(model.histogram == histogram)
      try await until("full preview ready", { !model.isRendering })
      #expect(model.previewImage?.width == 60 && model.previewImage?.height == 84)
      #expect(model.previewImage?.width != croppedWidth)
      #expect(model.histogram == histogram)
      #expect(model.displayedCrop == nil)
      model.cropPreviewEnabled = true
      try await until("crop restored", { !model.isRendering })
      #expect(model.previewImage?.width == croppedWidth && model.histogram == histogram)
    }
    #expect(model.project?.frames == frames)
    #expect(model.project?.calibration == calibration)
    #expect(model.exportSettings == exportSettings && model.canUndo == canUndo)
    model.cropPreviewEnabled = false
    model.selectAdjacentFrame(1)
    try await until("next full frame ready", { !model.isLoading && !model.isRendering })
    #expect(!model.cropPreviewEnabled && model.previewImage?.width == 60)
    model.beginCrop()
    try await until("crop editor ready", { !model.isRendering })
    #expect(model.isCropping && model.cropDraft != nil)
    model.cancelCrop()
    try await until("full frame restored after cancel", { !model.isRendering })
    #expect(!model.cropPreviewEnabled && model.previewImage?.height == 84)
    model.beginCrop()
    try await until("crop editor ready again", { !model.isRendering })
    model.commitCrop()
    try await until("full frame restored after commit", { !model.isRendering })
    #expect(!model.cropPreviewEnabled && model.displayedCrop == nil)
    model.edit { $0.timing.master = 60 }
    model.cropPreviewEnabled = true
    model.cropPreviewEnabled = false
    try await until("latest edit and toggle ready", { !model.isRendering })
    let fullHistogram = model.histogram
    model.cropPreviewEnabled = true
    try await until("latest cropped statistics ready", { !model.isRendering })
    #expect(model.histogram == fullHistogram)
    #expect(model.adjustments.timing.master == 60)
    #expect(model.errorMessage == nil)
    #expect(EditorModel().cropPreviewEnabled)
    #expect(model.flushSave())
  }

  @Test(arguments: FrameOrientation.allCases)
  func hiddenCropKeepsHistogramPixels(orientation: FrameOrientation) async throws {
    let assets = try #require(EditorModel().assets)
    let folder = try fixture(count: 1, profile: assets.profile)
    defer { try? FileManager.default.removeItem(at: folder) }
    let input = try TIFFCodec.read(url: folder.appendingPathComponent("0.tif")).preview()
    let renderer = PreviewRenderService()
    let crop = FrameCrop(aspect: .square, centerX: 0.4, width: 0.5, angleDegrees: 4)
    for stage in [PipelineStage.l2, .d3, .final] {
      let reference = try await renderer.render(input, calibration: .init(), adjustments: .init(),
        assets: assets, stage: stage, orientation: orientation, crop: crop,
        includeHistogram: true, histogramStage: .d3)
      let full = try await renderer.render(input, calibration: .init(), adjustments: .init(),
        assets: assets, stage: stage, orientation: orientation)
      let hidden = try await renderer.render(input, calibration: .init(), adjustments: .init(),
        assets: assets, stage: stage, orientation: orientation,
        includeHistogram: true, histogramStage: .d3, histogramCrop: crop)
      #expect(hidden.histogram == reference.histogram)
      #expect(hidden.pixels.pixels == full.pixels.pixels)
      #expect(hidden.pixels.width == full.pixels.width && hidden.pixels.height == full.pixels.height)
    }
  }

  @Test func filmBaseModeSurvivesNavigationAndKeepsFullFrame() async throws {
    let model = EditorModel()
    let assets = try #require(model.assets)
    let folder = try fixture(count: 3, profile: assets.profile)
    defer { try? FileManager.default.removeItem(at: folder) }
    var roll = try ProjectStore.open(folder: folder)
    let crop = FrameCrop(aspect: .square, width: 0.5)
    for index in roll.frames.indices { roll.frames[index].crop = crop }
    try ProjectStore.save(roll, folder: folder, expectedModification: roll.loadedModificationDate)
    model.open(folder.appendingPathComponent(roll.frames[0].filename))
    try await waitForProxyImport(model)
    try await prepareCalibratedPreview(model)
    model.stage = .l0
    try await until("initial frame ready", { model.histogram != nil })
    let calibration = model.project?.calibration
    model.sampling = true
    for delta in [1, 1, 1, -1, -1, -1] {
      model.selectAdjacentFrame(delta)
      #expect(model.sampling && model.displayedCrop == nil)
      try await until("full frame ready", { !model.isLoading && !model.isRendering })
      #expect(model.sampling && !model.isCropping)
      #expect(model.previewImage?.width == 84 && model.previewImage?.height == 60)
    }
    model.selectAdjacentFrame(1)
    model.selectAdjacentFrame(1)
    model.selectAdjacentFrame(-1)
    try await until("rapid switch ready", { !model.isLoading && !model.isRendering })
    #expect(model.activeFrame?.id == roll.frames[1].id && model.sampling)
    model.select(roll.frames[2].id)
    try await until("clicked frame ready", { !model.isLoading && !model.isRendering })
    #expect(model.sampling && model.displayedCrop == nil)
    #expect(model.project?.calibration == calibration)
    #expect(model.project?.frames.map(\.crop) == roll.frames.map(\.crop))
    model.sampling = false
    try await until("cropped frame restored", { !model.isRendering })
    #expect(model.displayedCrop == crop)
    #expect(model.errorMessage == nil)
  }

  @Test(arguments: [FrameOrientation.rotate90CW, .transverse])
  func syncUsesOneOriginalCropAcrossAllDirections(activeOrientation: FrameOrientation) async throws {
    let model = EditorModel()
    let assets = try #require(model.assets)
    let directions = FrameOrientation.allCases
    let folder = try fixture(count: directions.count, profile: assets.profile)
    defer { try? FileManager.default.removeItem(at: folder) }
    var roll = try ProjectStore.open(folder: folder)
    for index in roll.frames.indices {
      roll.frames[index].orientation = directions[index]
      roll.frames[index].adjustments.timing.red = 10 + index
    }
    try ProjectStore.save(roll, folder: folder, expectedModification: roll.loadedModificationDate)
    let sourceIndex = try #require(directions.firstIndex(of: activeOrientation))
    model.open(folder.appendingPathComponent(roll.frames[sourceIndex].filename))
    try await waitForProxyImport(model)
    try await prepareCalibratedPreview(model)
    model.stage = .l0
    try await until("rotated sync source loaded", { model.histogram != nil })
    model.beginCrop()
    let requested = FrameCrop(aspect: .sevenSix, centerX: 0.38, centerY: 0.45,
                              width: 0.5, angleDegrees: 4.25)
    let displayed = try requested.displayCoordinates(sourceWidth: 84, sourceHeight: 60,
      orientation: activeOrientation)
    model.updateDisplayedCropDraft(displayed)
    let originalCrop = try #require(model.cropDraft)
    #expect(originalCrop.geometryVersion == 2)
    #expect(!originalCrop.portrait)
    #expect(abs(originalCrop.angleDegrees - 4.25) < 1e-10)
    model.selectAll()
    #expect(model.activeFrame?.orientation == activeOrientation)
    #expect(model.cropDraft == originalCrop && model.isCropping)
    model.commitCrop()
    model.beginSync()
    model.syncCrop = true
    #expect(model.syncCurrentSettings())
    let applied = try #require(model.project)
    #expect(applied.frames.allSatisfy { $0.crop == originalCrop })
    #expect(applied.frames.map(\.orientation) == roll.frames.map(\.orientation))
    #expect(applied.frames.map(\.adjustments) == roll.frames.map(\.adjustments))

    let service = ImageService()
    let renderer = PreviewRenderService()
    let source = try await service.preview(folder.appendingPathComponent("0.tif"))
    let sourceResult = try CropGeometry(crop: originalCrop, sourceWidth: 84, sourceHeight: 60)
      .render(source.0)
    #expect(sourceResult.width == 42 && sourceResult.height == 36)
    for frame in applied.frames {
      // The contract is crop in the original image first, then lossless D4.
      // Compare full buffers so neither matching dimensions nor a histogram can
      // hide synchronization of the wrong side of this asymmetric photograph.
      let expected = try frame.orientation.transform(sourceResult)
      let rendered = try await renderer.render(source.0, calibration: .init(),
        adjustments: frame.adjustments, assets: assets, stage: .l0,
        orientation: frame.orientation, crop: frame.crop, sourceWidth: 84, sourceHeight: 60)
      #expect(rendered.pixels.width == expected.width && rendered.pixels.height == expected.height)
      for index in expected.pixels.indices {
        for channel in 0..<3 {
          #expect(abs(rendered.pixels.pixels[index][channel] - expected.pixels[index][channel]) < 2e-6)
        }
      }
    }
    #expect(model.flushSave())
    #expect(try ProjectStore.open(folder: folder).frames == applied.frames)
    try await until("synced active preview settled", { model.histogram?.pixelCount == 42 * 36 })
    #expect(model.errorMessage == nil)
  }

  @Test func commandAndShiftTargetChangesKeepCropSourceDraftAndPreview() async throws {
    let model = EditorModel()
    let assets = try #require(model.assets)
    let folder = try fixture(count: 5, profile: assets.profile)
    defer { try? FileManager.default.removeItem(at: folder) }
    model.open(folder)
    try await waitForProxyImport(model)
    try await prepareCalibratedPreview(model)
    let ids = try #require(model.project?.frames.map(\.id))
    model.select(ids[1])
    try await until("ordinary-click crop source loaded", { model.histogram != nil })
    model.beginCrop()
    model.updateCropDraft(FrameCrop(aspect: .sevenSix, centerX: 0.4,
      width: 0.5, angleDegrees: 2.73))
    try await until("editing full-frame preview ready", { model.previewImage != nil && !model.isRendering })
    let preview = try #require(model.previewImage)
    let draft = try #require(model.cropDraft)
    let token = model.cropViewportToken
    func expectSourceUnchanged() {
      #expect(model.activeFrame?.id == ids[1])
      #expect(model.selection.activeFrameID == ids[1])
      #expect(model.selection.anchorID == ids[1])
      #expect(model.selection.selectedFrameIDs.contains(ids[1]))
      #expect(model.project?.lastActiveFrameID == ids[1])
      #expect(model.cropDraft == draft && model.isCropping)
      #expect(model.previewImage === preview)
      #expect(model.cropViewportToken == token)
      #expect(model.sourceWidth == 84 && model.sourceHeight == 60)
      #expect(!model.isLoading && !model.isRendering)
    }
    model.select(ids[4], command: true)
    #expect(model.selection.selectedFrameIDs == Set([ids[1], ids[4]]))
    expectSourceUnchanged()
    model.select(ids[4], command: true)
    #expect(model.selection.selectedFrameIDs == Set([ids[1]]))
    expectSourceUnchanged()
    model.select(ids[1], command: true)
    #expect(model.selection.selectedFrameIDs == Set([ids[1]]))
    expectSourceUnchanged()
    model.select(ids[3], shift: true)
    #expect(model.selection.selectedFrameIDs == Set(ids[1...3]))
    expectSourceUnchanged()
    model.select(ids[0], command: true, shift: true)
    #expect(model.selection.selectedFrameIDs == Set(ids[0...3]))
    expectSourceUnchanged()
    model.select(ids[4], shift: true)
    #expect(model.selection.selectedFrameIDs == Set(ids[1...4]))
    expectSourceUnchanged()
    model.select(ids[1], command: true)
    #expect(model.selection.selectedFrameIDs == Set(ids[1...4]))
    expectSourceUnchanged()
    // A plain click explicitly changes the editing source and its next range anchor.
    model.select(ids[4])
    #expect(model.selection.selectedFrameIDs == Set([ids[4]]))
    #expect(model.selection.activeFrameID == ids[4] && model.selection.anchorID == ids[4])
    #expect(model.isCropping && model.cropDraft == nil)
    if let placeholder = model.previewImage {
      #expect(model.isPreviewPlaceholder && placeholder === model.thumbnails[ids[4]])
    }
    #expect(model.project?.frames[1].crop == draft)
    #expect(model.project?.frames.filter { $0.id != ids[1] }.allSatisfy { $0.crop == nil } == true)
    try await until("new source crop preview", { model.previewImage != nil && !model.isLoading && !model.isRendering })
    #expect(model.isCropping && model.cropDraft != nil && model.cropDraft != draft)
    let nextPreview = try #require(model.previewImage)
    model.select(ids[2], shift: true)
    #expect(model.selection.selectedFrameIDs == Set(ids[2...4]))
    #expect(model.selection.activeFrameID == ids[4] && model.selection.anchorID == ids[4])
    #expect(model.previewImage === nextPreview)
    #expect(model.errorMessage == nil)
  }

  @Test func switchingInCropModeLoadsSavedCropAndCancellationSurvivesLoading() async throws {
    let model = EditorModel()
    let assets = try #require(model.assets)
    let folder = try fixture(count: 3, profile: assets.profile)
    defer { try? FileManager.default.removeItem(at: folder) }
    model.open(folder)
    try await waitForProxyImport(model)
    try await prepareCalibratedPreview(model)
    let ids = try #require(model.project?.frames.map(\.id))
    model.select(ids[1])
    try await until("B ready", { model.histogram != nil })
    model.beginCrop()
    model.updateCropDraft(FrameCrop(aspect: .square, width: 0.5, angleDegrees: 2))
    model.commitCrop()
    let saved = try #require(model.activeFrame?.crop)
    model.select(ids[0])
    try await until("A ready", { model.histogram != nil })
    model.beginCrop()
    model.selectAdjacentFrame(1)
    #expect(model.isCropping && model.isLoading)
    model.commitCrop()
    #expect(model.activeFrame?.crop == saved && model.isCropping)
    try await until("B crop ready", { !model.isLoading && !model.isRendering })
    #expect(model.cropDraft == saved && model.isCropping)
    model.selectAdjacentFrame(1)
    model.selectAdjacentFrame(-1)
    try await until("rapid B crop ready", { !model.isLoading && !model.isRendering })
    #expect(model.activeFrame?.id == ids[1] && model.cropDraft == saved)
    model.selectAdjacentFrame(-1)
    model.cancelCrop()
    try await until("cancel during loading", { !model.isLoading && !model.isRendering })
    #expect(!model.isCropping && model.cropDraft == nil)
    #expect(model.project?.frames[1].crop == saved)
    #expect(model.errorMessage == nil)
  }

  @Test(arguments: [false, true])
  func switchingSavesCropAndResetWithUndoAndReopen(usingKeyboard: Bool) async throws {
    let model = EditorModel()
    let assets = try #require(model.assets)
    let folder = try fixture(count: 3, profile: assets.profile)
    defer { try? FileManager.default.removeItem(at: folder) }
    model.open(folder)
    try await waitForProxyImport(model)
    try await prepareCalibratedPreview(model)
    let ids = try #require(model.project?.frames.map(\.id))
    try await until("source ready", { model.histogram != nil })
    model.changeOrientation(.rotateClockwise)
    model.beginCrop()
    model.updateCropDraft(FrameCrop(aspect: .sevenSix, centerX: 0.4,
      width: 0.5, angleDegrees: 3.25))
    let draft = try #require(model.cropDraft)
    func switchTo(_ index: Int, delta: Int) {
      if usingKeyboard { model.selectAdjacentFrame(delta) }
      else { model.select(ids[index]) }
    }
    switchTo(1, delta: 1)
    #expect(model.isCropping && model.activeFrame?.id == ids[1])
    #expect(model.project?.frames[0].crop == draft)
    // Switching itself saves to disk, without a later explicit flush.
    #expect(try ProjectStore.open(folder: folder).frames[0].crop == draft)
    switchTo(0, delta: -1)
    try await until("saved source reloaded", { !model.isLoading && !model.isRendering })
    #expect(model.cropDraft == draft)
    model.resetCropDraft()
    switchTo(1, delta: 1)
    #expect(model.project?.frames[0].crop == nil)
    #expect(try ProjectStore.open(folder: folder).frames[0].crop == nil)
    model.cancelCrop()
    model.undo()
    #expect(model.project?.frames[0].crop == draft)
    model.undo()
    #expect(model.project?.frames[0].crop == nil)
    model.redo()
    #expect(model.project?.frames[0].crop == draft)
    model.redo()
    #expect(model.project?.frames[0].crop == nil)
    #expect(model.project?.frames[0].orientation == .rotate90CW)
    #expect(model.project?.frames.dropFirst().allSatisfy { $0.crop == nil } == true)
    try await until("destination settled", { !model.isLoading && !model.isRendering })
    #expect(model.errorMessage == nil)
  }

  @Test func displayedAngleAndRatioFollowDirectionWhileStoredDraftUsesOriginalCoordinates() async throws {
    let model = EditorModel()
    let assets = try #require(model.assets)
    let folder = try fixture(count: 1, profile: assets.profile)
    defer { try? FileManager.default.removeItem(at: folder) }
    model.open(folder)
    try await waitForProxyImport(model)
    try await prepareCalibratedPreview(model)
    try await until("angle basis source loaded", { model.histogram != nil })
    model.beginCrop()
    model.updateCropDraft(FrameCrop(aspect: .sevenSix, width: 0.5, angleDegrees: 3.25))
    model.commitCrop()
    let original = try #require(model.activeFrame?.crop)
    let operations: [OrientationOperation] = [.flipHorizontal, .reset, .rotateClockwise, .flipHorizontal]
    for operation in operations {
      model.changeOrientation(operation)
      #expect(model.activeFrame?.crop == original)
      model.beginCrop()
      let display = try #require(model.displayedCropDraft)
      let reflected = [FrameOrientation.flipHorizontal, .flipVertical, .transpose, .transverse]
        .contains(model.orientation)
      #expect(display.geometryVersion == 1)
      #expect(display.portrait == model.orientation.swapsAxes)
      #expect(display.angleDegrees == (reflected ? -3.25 : 3.25))
      let expectedWidth = model.orientation.swapsAxes ? 0.6 : 0.5
      #expect(abs(display.width - expectedWidth) < 1e-10)
      #expect(model.cropDraft == original)
      model.cancelCrop()
    }
    #expect(model.orientation == .transpose)
    model.beginCrop()
    var editedDisplay = try #require(model.displayedCropDraft)
    editedDisplay.angleDegrees = 5.37
    model.updateDisplayedCropDraft(editedDisplay)
    let raw = try #require(model.cropDraft)
    #expect(raw.geometryVersion == 2 && !raw.portrait)
    #expect(raw.angleDegrees == -5.37)
    #expect(model.displayedCropDraft?.angleDegrees == 5.37)
    #expect(model.displayedCropDraft?.portrait == true)
    model.commitCrop()
    #expect(model.activeFrame?.crop == raw)
    #expect(model.flushSave())
    #expect(try ProjectStore.open(folder: folder).frames[0].crop == raw)
    try await until("converted angle crop preview", { model.histogram?.pixelCount == 42 * 36 })
    #expect(model.errorMessage == nil)
  }

  @Test func legacyCropRestoresAndReconnectsUsingActualOriginalDimensions() async throws {
    let model = EditorModel()
    let assets = try #require(model.assets)
    let folder = try fixture(count: 2, profile: assets.profile)
    defer { try? FileManager.default.removeItem(at: folder) }
    var legacy = try ProjectStore.open(folder: folder)
    let crop = FrameCrop(aspect: .sevenSix, portrait: true, centerX: 0.45,
      centerY: 0.4, width: 0.6, angleDegrees: -3.25, geometryVersion: 1)
    for index in legacy.frames.indices {
      legacy.frames[index].orientation = .transpose
      legacy.frames[index].crop = crop
    }
    let expected = try crop.sourceCoordinates(sourceWidth: 84, sourceHeight: 60,
      orientation: .transpose)
    let backup = try JSONEncoder().encode(legacy)
    try backup.write(to: folder.appendingPathComponent(ProjectStore.filename))
    let oldURL = folder.appendingPathComponent("1.tif")
    let newURL = folder.appendingPathComponent("renamed.tif")
    try FileManager.default.moveItem(at: oldURL, to: newURL)
    let reopened = try ProjectStore.open(folder: folder)
    let missing = try #require(reopened.frames.first { $0.filename == "1.tif" })
    #expect(missing.isMissing && missing.crop == crop)
    let reconnected = try ProjectStore.relocate(reopened, frameID: missing.id,
      to: newURL, folder: folder)
    let restoredFrame = try #require(reconnected.frames.first { $0.id == missing.id })
    #expect(!restoredFrame.isMissing && restoredFrame.crop == expected)
    #expect(restoredFrame.orientation == .transpose)
    try FileManager.default.moveItem(at: newURL, to: oldURL)

    model.open(folder)
    try await waitForProxyImport(model)
    try await prepareCalibratedPreview(model)
    try await until("legacy restoration source loaded", { model.histogram != nil })
    model.beginCrop()
    model.resetCropDraft()
    model.commitCrop()
    #expect(model.activeFrame?.crop == nil)
    try model.restoreBackup(data: backup)
    #expect(model.project?.frames.allSatisfy { $0.crop == expected } == true)
    #expect(try ProjectStore.open(folder: folder).frames.allSatisfy { $0.crop == expected })
    try await until("restored legacy original preview", {
      model.hasImage && !model.isRendering
        && (model.previewImage?.width ?? 0) * (model.previewImage?.height ?? 0) == 42 * 36
    })
    #expect(!model.hasFilmBase && model.histogram == nil)
    #expect(model.errorMessage == nil)
  }

  @Test func legacyDisplayedCropMigratesWithoutChangingPixelsAndBacksUpExactSettings() async throws {
    let assets = try AppAssets()
    let folder = try fixture(count: 2, profile: assets.profile)
    defer { try? FileManager.default.removeItem(at: folder) }
    var legacy = try ProjectStore.open(folder: folder)
    let orientations: [FrameOrientation] = [.rotate90CW, .transpose]
    for index in legacy.frames.indices {
      legacy.frames[index].orientation = orientations[index]
      legacy.frames[index].crop = FrameCrop(aspect: .sevenSix, portrait: true,
        centerX: 0.45, centerY: 0.4, width: 0.6, angleDegrees: -3.25, geometryVersion: 1)
    }
    let originalJSON = try JSONEncoder().encode(legacy)
    let settings = folder.appendingPathComponent(ProjectStore.filename)
    try originalJSON.write(to: settings)
    let sourceURL = folder.appendingPathComponent("0.tif")
    let originalSourceBytes = try Data(contentsOf: sourceURL)
    let source = try await ImageService().preview(sourceURL)
    let migrated = try ProjectStore.open(folder: folder)
    #expect(migrated.schemaVersion == RollProject.currentSchemaVersion)
    #expect(migrated.frames.map(\.orientation) == legacy.frames.map(\.orientation))
    #expect(migrated.frames.allSatisfy { $0.crop?.geometryVersion == 2 })
    // Read-only migration must leave the old sidecar untouched until a successful save.
    #expect(try Data(contentsOf: settings) == originalJSON)
    for index in legacy.frames.indices {
      let old = legacy.frames[index], current = migrated.frames[index]
      let before = try CropGeometry(crop: old.crop, sourceWidth: 84, sourceHeight: 60,
        orientation: old.orientation).render(source.0)
      let after = try CropGeometry(crop: current.crop, sourceWidth: 84, sourceHeight: 60,
        orientation: current.orientation).render(source.0)
      #expect(before.width == after.width && before.height == after.height)
      for pixel in before.pixels.indices {
        for channel in 0..<3 {
          #expect(abs(before.pixels[pixel][channel] - after.pixels[pixel][channel]) < 2e-6)
        }
      }
    }
    let firstSave = try ProjectStore.save(migrated, folder: folder,
      expectedModification: migrated.loadedModificationDate)
    let backups = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
      .filter { $0.lastPathComponent.hasPrefix(".printroom-") && $0.pathExtension == "json" }
    #expect(backups.count == 1)
    let backupURL = try #require(backups.first)
    #expect(try Data(contentsOf: backupURL) == originalJSON)
    try ProjectStore.save(migrated, folder: folder, expectedModification: firstSave)
    let afterSecondSave = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
      .filter { $0.lastPathComponent.hasPrefix(".printroom-") && $0.pathExtension == "json" }
    #expect(afterSecondSave == backups)
    #expect(try ProjectStore.open(folder: folder).frames == migrated.frames)
    #expect(try Data(contentsOf: sourceURL) == originalSourceBytes)
  }
}
