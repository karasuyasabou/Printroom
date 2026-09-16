import AppKit
import Foundation
import PrintroomCore
import Testing

@testable import PrintroomApp

@Suite(.serialized) @MainActor
struct CropEditingTests {
  private func fixture() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PrintroomCrop-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  private func write(_ name: String, folder: URL, width: Int, height: Int,
                     profile: Data, value: UInt16 = 32768) throws -> URL {
    let url = folder.appendingPathComponent(name)
    try TIFFCodec.write(url: url, width: width, height: height, profile: profile) { rows in
      [UInt16](repeating: value, count: rows.count * width * 3)
    }
    return url
  }

  private func until(_ message: String, _ ready: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(8))
    while !ready(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(15)) }
    #expect(ready(), "\(message)")
    guard ready() else { throw PrintroomError.invalid(message) }
  }

  @Test func cropTransitionsKeepVisibleImageAndGeometryUntilReplacement() async throws {
    let model = EditorModel()
    let assets = try #require(model.assets)
    let folder = try fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    _ = try write("A.tif", folder: folder, width: 120, height: 80, profile: assets.profile)
    model.open(folder)
    try await until("full preview", { !model.isRendering && model.hasImage })
    let canvas = CanvasView(frame: CGRect(x: 0, y: 0, width: 753, height: 460))
    canvas.model = model
    canvas.zoom = 2
    canvas.pan = CGPoint(x: 12, y: -8)
    let originalRect = canvas.imageRect
    let originalImage = model.previewImage
    model.beginCrop()
    #expect(model.previewImage === originalImage)
    #expect(canvas.imageRect == originalRect)
    #expect(!canvas.presentsCrop)
    #expect(!model.hasImage) // Old geometry cannot be used for precise tools.
    try await until("crop full preview", { !model.isRendering })
    #expect(model.cropPreviewTransition == nil && canvas.presentsCrop)
    model.updateCropDraft(FrameCrop(aspect: .square, width: 0.5, angleDegrees: 3.27))
    let cropRect = canvas.cropRect
    let angle = canvas.presentedCropGeometry?.displayCrop?.angleDegrees
    let fullImage = model.previewImage
    model.commitCrop()
    #expect(model.previewImage === fullImage)
    #expect(canvas.displaySize == CGSize(width: 120, height: 80))
    #expect(canvas.cropRect == cropRect)
    #expect(canvas.presentedCropGeometry?.displayCrop?.angleDegrees == angle)
    try await until("committed preview", { !model.isRendering })
    #expect(canvas.displaySize == CGSize(width: 60, height: 60))
    #expect(!canvas.presentsCrop && model.hasImage)
    let committedImage = model.previewImage
    model.beginCrop()
    #expect(model.previewImage === committedImage)
    #expect(canvas.displaySize == CGSize(width: 60, height: 60))
    try await until("reopened crop", { !model.isRendering })
    model.resetCropDraft()
    let resetImage = model.previewImage
    model.cancelCrop()
    #expect(model.previewImage === resetImage)
    #expect(canvas.displaySize == CGSize(width: 120, height: 80))
    try await until("cancelled crop", { !model.isRendering })
    #expect(canvas.displaySize == CGSize(width: 60, height: 60))
    #expect(model.activeFrame?.crop?.angleDegrees == 3.27)
    #expect(model.errorMessage == nil)
  }

  @Test func unifiedSyncUsesCurrentSettingsAndCommitsBothInOneUndo() async throws {
    let model = EditorModel()
    let assets = try #require(model.assets)
    let folder = try fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    for name in ["A.tif", "B.tif", "C.tif"] {
      _ = try write(name, folder: folder, width: 120, height: 80, profile: assets.profile)
    }
    model.open(folder)
    try await until("loaded", { model.histogram != nil })
    model.copyParameters()
    var project = try #require(model.project)
    project.frames[0].adjustments.timing.red = 23
    project.frames[0].crop = FrameCrop(aspect: .square, width: 0.5, angleDegrees: 2, geometryVersion: 2)
    project.frames[1].adjustments.timing.blue = -12
    project.frames[1].orientation = .rotate90CW
    project.frames[2].adjustments.contrast.master = 1.2
    model.project = project
    model.selectAll()
    model.beginSync()
    #expect(!model.hasSyncSelection)
    #expect(model.syncTargetIDs.count == 2)
    #expect(!model.syncCurrentSettings())
    #expect(model.project?.frames == project.frames)
    model.syncTiming = true; model.syncContrast = true; model.syncLUT = true
    model.syncCrop = true
    #expect(model.syncCurrentSettings())
    let applied = try #require(model.project)
    #expect(applied.frames[0] == project.frames[0])
    for i in 1...2 {
      #expect(applied.frames[i].adjustments == project.frames[0].adjustments)
      #expect(applied.frames[i].crop == project.frames[0].crop)
      #expect(applied.frames[i].orientation == project.frames[i].orientation)
    }
    #expect(applied.calibration == project.calibration)
    model.undo()
    #expect(model.project?.frames == project.frames)
    model.redo()
    #expect(model.project?.frames == applied.frames)
    model.beginSync()
    #expect(!model.hasSyncSelection)
    model.syncTiming = true; model.syncContrast = true; model.syncLUT = true
    model.syncCrop = true
    #expect(model.syncCurrentSettings())
    model.undo()
    #expect(model.project?.frames == project.frames)
    // A corrupt last target must reject the combined transaction, including color.
    try Data("invalid TIFF".utf8).write(to: folder.appendingPathComponent("C.tif"))
    model.beginSync()
    model.syncTiming = true; model.syncContrast = true; model.syncLUT = true
    model.syncCrop = true
    #expect(!model.syncCurrentSettings())
    #expect(model.project?.frames == project.frames)
    model.errorMessage = nil
    model.beginSync()
    model.syncTiming = true; model.syncContrast = true; model.syncLUT = true
    #expect(model.syncCurrentSettings())
    #expect(model.project?.frames[1].crop == project.frames[1].crop)
    model.undo()
    // A full-frame source clears only target crops.
    var full = project
    full.frames[0].crop = nil
    full.frames[1].crop = project.frames[0].crop
    model.project = full
    try FileManager.default.removeItem(at: folder.appendingPathComponent("C.tif"))
    _ = try write("C.tif", folder: folder, width: 120, height: 80, profile: assets.profile)
    model.beginSync()
    model.syncCrop = true
    #expect(model.syncCurrentSettings())
    #expect(model.project?.frames[1].crop == nil)
    #expect(model.project?.frames[1].adjustments == full.frames[1].adjustments)
    #expect(model.flushSave())
    let reopened = try ProjectStore.open(folder: folder)
    let saved = try #require(model.project)
    for (actual, expected) in zip(reopened.frames, saved.frames) {
      #expect(actual.id == expected.id)
      #expect(actual.adjustments == expected.adjustments)
      #expect(actual.crop == expected.crop)
      #expect(actual.orientation == expected.orientation)
    }
  }

  @Test func draftCancelAndCommitAreReversibleAndPersistWithoutChangingSource() async throws {
    let model = EditorModel()
    let assets = try #require(model.assets)
    let folder = try fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = try write("A.tif", folder: folder, width: 120, height: 80, profile: assets.profile)
    let sourceBytes = try Data(contentsOf: url)
    model.open(folder)
    try await until("initial full-frame preview", { model.histogram != nil })
    let original = try #require(model.project)
    let token = model.cropViewportToken
    model.beginCrop()
    #expect(model.isCropping)
    #expect(model.cropViewportToken > token)
    model.updateCropDraft(FrameCrop(aspect: .sevenSix, centerX: 0.4, width: 0.5, angleDegrees: 3.27))
    #expect(model.project?.frames == original.frames)
    #expect(!model.canUndo)
    model.cancelCrop()
    #expect(!model.isCropping && model.cropDraft == nil)
    #expect(model.project?.frames == original.frames)
    #expect(!model.canUndo)
    model.beginCrop()
    model.updateCropDraft(FrameCrop(aspect: .square, width: 0.5, angleDegrees: 3.27))
    let draft = try #require(model.cropDraft)
    model.commitCrop()
    let committed = try #require(model.project)
    #expect(committed.frames[0].crop == draft)
    #expect(model.displayWidth == 60 && model.displayHeight == 60)
    #expect(!model.isCropping && model.cropDraft == nil)
    #expect(model.canUndo)
    model.undo()
    #expect(model.project?.frames == original.frames)
    #expect(model.displayWidth == 120 && model.displayHeight == 80)
    #expect(!model.canUndo)
    model.redo()
    #expect(model.project?.frames == committed.frames)
    // A later cancelled reset must retain the existing angle and rectangle.
    model.beginCrop()
    model.resetCropDraft()
    #expect(model.cropDraft == nil)
    model.cancelCrop()
    #expect(model.activeFrame?.crop == draft)
    #expect(model.flushSave())
    let reopened = try ProjectStore.open(folder: folder)
    #expect(reopened.frames == committed.frames)
    #expect(reopened.schemaVersion == RollProject.currentSchemaVersion)
    #expect(try Data(contentsOf: url) == sourceBytes)
    try await until("committed crop preview", { model.histogram?.pixelCount == 3600 })
    #expect(model.previewImage?.width == 60 && model.previewImage?.height == 60)
    #expect(model.errorMessage == nil)
  }

  @Test func multiSelectionSyncPreservesPerFrameEditsAndResetsInOneUndoGroup() async throws {
    let model = EditorModel()
    let assets = try #require(model.assets)
    let folder = try fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let dimensions = [(120, 80), (140, 100), (96, 120)]
    for (index, size) in dimensions.enumerated() {
      _ = try write("\(index).tif", folder: folder, width: size.0, height: size.1,
                    profile: assets.profile)
    }
    model.open(folder)
    let frames = try #require(model.project?.frames)
    for index in frames.indices {
      model.select(frames[index].id)
      try await until("target loaded", { !model.isLoading && model.histogram != nil })
      model.edit { $0.timing.red = 11 + index; $0.contrast.blue = 1 + Float(index) * 0.1 }
      if index == 1 { model.changeOrientation(.rotateClockwise) }
      if index == 2 { model.changeOrientation(.flipHorizontal) }
      model.beginCrop()
      model.updateCropDraft(FrameCrop(aspect: .square, width: 0.4, angleDegrees: Double(index)))
      model.commitCrop()
    }
    model.select(frames[0].id)
    try await until("sync source loaded", { !model.isLoading && model.histogram != nil })
    model.selectAll()
    #expect(model.canSyncCrop)
    let before = try #require(model.project)
    model.undoManager.removeAllActions()
    model.beginCrop()
    model.updateCropDraft(FrameCrop(aspect: .sevenSix, width: 0.7, angleDegrees: 2.3))
    model.commitCrop(syncSelection: true)
    let applied = try #require(model.project)
    #expect(applied.frames.map(\.orientation) == before.frames.map(\.orientation))
    #expect(applied.frames.map(\.adjustments) == before.frames.map(\.adjustments))
    #expect(applied.calibration == before.calibration)
    for (index, frame) in applied.frames.enumerated() {
      let crop = try #require(frame.crop)
      #expect(crop.aspect == .sevenSix && !crop.portrait && crop.angleDegrees == 2.3)
      let geometry = try CropGeometry(crop: crop, sourceWidth: dimensions[index].0,
        sourceHeight: dimensions[index].1, orientation: frame.orientation)
      #expect(crop.geometryVersion == 2)
      if frame.orientation.swapsAxes {
        #expect(geometry.outputWidth * 7 == geometry.outputHeight * 6)
      } else {
        #expect(geometry.outputWidth * 6 == geometry.outputHeight * 7)
      }
      let sourceCrop = try crop.constrained(sourceWidth: dimensions[index].0,
        sourceHeight: dimensions[index].1)
      #expect(sourceCrop == crop)
    }
    // An identical explicit sync must not add an otherwise invisible undo entry.
    model.syncCurrentCropToSelection()
    model.undo()
    #expect(model.project?.frames == before.frames)
    #expect(!model.canUndo)
    model.redo()
    #expect(model.project?.frames == applied.frames)
    #expect(model.flushSave())
    #expect(try ProjectStore.open(folder: folder).frames == applied.frames)
    model.beginCrop()
    model.resetCropDraft()
    model.commitCrop(syncSelection: true)
    #expect(model.project?.frames.allSatisfy { $0.crop == nil } == true)
    #expect(model.project?.frames.map(\.orientation) == before.frames.map(\.orientation))
    #expect(model.project?.frames.map(\.adjustments) == before.frames.map(\.adjustments))
    model.undo()
    #expect(model.project?.frames == applied.frames)
    model.redo()
    #expect(model.project?.frames.allSatisfy { $0.crop == nil } == true)
    try await until("reset full-frame histogram", { model.histogram?.pixelCount == 120 * 80 })
    #expect(model.errorMessage == nil)
  }

  @Test func settingsBackupRestoresCropAndGeometryWithSingleUndoRedo() async throws {
    let model = EditorModel()
    let assets = try #require(model.assets)
    let folder = try fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    _ = try write("A.tif", folder: folder, width: 120, height: 80, profile: assets.profile)
    model.open(folder)
    try await until("backup source loaded", { model.histogram != nil })
    model.beginCrop()
    model.updateCropDraft(FrameCrop(aspect: .square, width: 0.5, angleDegrees: 3.25))
    model.commitCrop()
    #expect(model.flushSave())
    let backedUp = try #require(model.project)
    let backup = try Data(contentsOf: folder.appendingPathComponent(ProjectStore.filename))
    model.beginCrop()
    model.updateCropDraft(FrameCrop(aspect: .threeTwo, width: 0.8, angleDegrees: -1.7))
    model.commitCrop()
    let changed = try #require(model.project)
    #expect(changed.frames[0].crop != backedUp.frames[0].crop)
    try await until("changed crop preview", { model.histogram?.pixelCount == 96 * 64 })
    #expect(model.previewImage?.width == 96 && model.previewImage?.height == 64)
    model.requestDetail(PixelRect(x: 2, y: 3, width: 12, height: 10))
    try await until("detail before restoring settings", { model.detailImage != nil })
    model.undoManager.removeAllActions()
    let token = model.cropViewportToken
    try model.restoreBackup(data: backup)
    #expect(model.project?.frames == backedUp.frames)
    #expect(model.displayGeometry?.crop == backedUp.frames[0].crop)
    #expect(model.displayWidth == 60 && model.displayHeight == 60)
    #expect(model.cropViewportToken > token)
    #expect(model.previewImage == nil && model.detailImage == nil && model.histogram == nil)
    try await until("restored backup crop preview", { model.histogram?.pixelCount == 60 * 60 })
    #expect(model.previewImage?.width == 60 && model.previewImage?.height == 60)
    model.undo()
    #expect(model.project?.frames == changed.frames)
    #expect(model.displayGeometry?.crop == changed.frames[0].crop)
    #expect(model.displayWidth == 96 && model.displayHeight == 64)
    #expect(model.previewImage == nil)
    #expect(!model.canUndo)
    try await until("undo backup restores edited crop", { model.histogram?.pixelCount == 96 * 64 })
    #expect(model.previewImage?.width == 96 && model.previewImage?.height == 64)
    model.redo()
    #expect(model.project?.frames == backedUp.frames)
    #expect(model.displayWidth == 60 && model.displayHeight == 60)
    #expect(model.previewImage == nil)
    #expect(model.flushSave())
    #expect(try ProjectStore.open(folder: folder).frames == backedUp.frames)
    try await until("redo backup crop preview", { model.histogram?.pixelCount == 60 * 60 })
    #expect(model.previewImage?.width == 60 && model.previewImage?.height == 60)
    #expect(model.errorMessage == nil)
  }

  @Test func missingSelectedSourceAbortsCropAndResetWithoutPartialEdits() async throws {
    let model = EditorModel()
    let assets = try #require(model.assets)
    let folder = try fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    for name in ["A.tif", "B.tif", "C.tif"] {
      _ = try write(name, folder: folder, width: 84, height: 72, profile: assets.profile)
    }
    model.open(folder)
    try await until("failure fixture loaded", { model.histogram != nil })
    model.selectAll()
    let before = try #require(model.project)
    model.beginCrop()
    model.updateCropDraft(FrameCrop(aspect: .fourThree, width: 0.6, angleDegrees: -2.12))
    let draft = try #require(model.cropDraft)
    // The final target disappears after selection, so earlier valid targets must
    // not be committed before the source validation for the whole group finishes.
    try FileManager.default.removeItem(at: folder.appendingPathComponent("C.tif"))
    model.commitCrop(syncSelection: true)
    #expect(model.errorMessage != nil)
    #expect(model.project?.frames == before.frames)
    #expect(model.cropDraft == draft && model.isCropping)
    #expect(!model.canUndo)
    model.errorMessage = nil
    model.resetCropDraft()
    model.commitCrop(syncSelection: true)
    #expect(model.errorMessage != nil)
    #expect(model.project?.frames == before.frames)
    #expect(!model.canUndo)
    model.cancelCrop()
    try await until("valid active frame still renders", { model.histogram != nil })
  }

  @Test func angledPreviewAndNativeRegionUseLinearInterpolationBeforeDensity() async throws {
    let assets = try AppAssets()
    let folder = try fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let width = 60, height = 48
    // Affine linear-light channels have an exact bilinear interpolation value.
    // Applying log first would produce a different, independently detectable value.
    let samples: [UInt16] = (0..<(width * height * 3)).map { index in
      let x = (index / 3) % width, y = index / (width * 3)
      switch index % 3 {
      case 0: return UInt16(5000 + 400 * x + 100 * y)
      case 1: return UInt16(9000 + 80 * x + 300 * y)
      default: return UInt16(15000 + 150 * x + 200 * y)
      }
    }
    let url = folder.appendingPathComponent("gradient.tif")
    try TIFFCodec.write(url: url, width: width, height: height, profile: assets.profile) { rows in
      Array(samples[(rows.lowerBound * width * 3)..<(rows.upperBound * width * 3)])
    }
    let originalBytes = try Data(contentsOf: url)
    let crop = FrameCrop(aspect: .square, width: 0.6, angleDegrees: 6)
    let service = ImageService()
    let renderer = PreviewRenderService()
    let source = try await service.preview(url)
    let identity = UUID()
    let preview = try await renderer.render(source.0, calibration: .init(), adjustments: .init(),
      assets: assets, stage: .d0, inputIdentity: identity, crop: crop,
      sourceWidth: width, sourceHeight: height)
    #expect(preview.pixels.width == 36 && preview.pixels.height == 36)
    let geometry = try CropGeometry(crop: crop, sourceWidth: width, sourceHeight: height)
    let rect = PixelRect(x: 3, y: 5, width: 13, height: 9)
    let region = try await service.transformedRegion(url, geometry: geometry, rect: rect)
    let detail = try await renderer.render(region, calibration: .init(), adjustments: .init(),
      assets: assets, stage: .d0)
    #expect(detail.pixels.width == rect.width && detail.pixels.height == rect.height)
    let angle = 6.0 * Double.pi / 180
    for y in 0..<36 {
      for x in 0..<36 {
        let dx = Double(x) - 17.5, dy = Double(y) - 17.5
        let sx = cos(angle) * dx + sin(angle) * dy + 29.5
        let sy = -sin(angle) * dx + cos(angle) * dy + 23.5
        let linear = [5000 + 400 * sx + 100 * sy,
                      9000 + 80 * sx + 300 * sy,
                      15000 + 150 * sx + 200 * sy]
        for channel in 0..<3 {
          let expected = Float(-log10(linear[channel] / 65535) / 2.048)
          #expect(abs(preview.pixels.pixels[y * 36 + x][channel] - expected) < 2e-5)
          if x >= rect.x, x < rect.x + rect.width, y >= rect.y, y < rect.y + rect.height {
            let index = (y - rect.y) * rect.width + x - rect.x
            #expect(abs(detail.pixels.pixels[index][channel] - expected) < 2e-5)
          }
        }
      }
    }
    // The same raw source identity must not reuse a previous angle's prepared pixels.
    let zero = FrameCrop(aspect: .square, width: 0.6)
    let straight = try await renderer.render(source.0, calibration: .init(), adjustments: .init(),
      assets: assets, stage: .l0, inputIdentity: identity, crop: zero,
      sourceWidth: width, sourceHeight: height)
    let straightRed = Float(10400) / Float(65535)
    #expect(abs(straight.pixels.pixels[0].x - straightRed) < 1e-6)
    let full = try await renderer.render(source.0, calibration: .init(), adjustments: .init(),
      assets: assets, stage: .l0, inputIdentity: identity)
    #expect(full.pixels.width == width && full.pixels.height == height)
    #expect(abs(full.pixels.pixels[0].x - Float(5000) / 65535) < 1e-6)
    #expect(try Data(contentsOf: url) == originalBytes)
  }

  @Test func cropHistogramAndDetailRemainCroppedWhileBaseSamplingTemporarilyShowsFullSource() async throws {
    let model = EditorModel()
    let assets = try #require(model.assets)
    let folder = try fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = try write("A.tif", folder: folder, width: 60, height: 48, profile: assets.profile)
    model.open(folder)
    model.stage = .l0
    try await until("base sampling fixture", { model.histogram != nil })
    model.beginCrop()
    model.updateCropDraft(FrameCrop(aspect: .square, width: 0.5))
    model.commitCrop()
    let savedCrop = try #require(model.activeFrame?.crop)
    try await until("cropped histogram", { model.histogram?.pixelCount == 900 })
    let histogram = try #require(model.histogram)
    model.requestDetail(PixelRect(x: 2, y: 3, width: 12, height: 10))
    try await until("cropped native tile", { model.detailImage != nil && !model.isDetailLoading })
    #expect(model.detailImage?.width == 12 && model.detailImage?.height == 10)
    #expect(model.histogram == histogram)
    model.sampling = true
    #expect(model.displayWidth == 60 && model.displayHeight == 48)
    #expect(model.detailImage == nil)
    #expect(model.activeFrame?.crop == savedCrop)
    try await until("uncropped sampling preview", { model.histogram?.pixelCount == 60 * 48 })
    // This strip lies wholly outside the cropped square and remains available as film base.
    let baseRect = PixelRect(x: 0, y: 0, width: 4, height: 4)
    model.sampleDisplayedBase(baseRect)
    try await until("full-source base calibration", { model.project?.calibration.isCalibrated == true })
    let expected = try Pipeline.calibrate(image: TIFFCodec.read(url: url), rect: baseRect,
      matrix: .identity, sourceFrameID: model.activeFrame?.id)
    #expect(model.project?.calibration == expected)
    #expect(!model.sampling)
    #expect(model.activeFrame?.crop == savedCrop)
    #expect(model.displayWidth == 30 && model.displayHeight == 30)
    try await until("cropped preview restored after sampling", { model.histogram?.pixelCount == 900 })
    model.undo()
    #expect(model.project?.calibration.isCalibrated == false)
    #expect(model.activeFrame?.crop == savedCrop)
    try await until("cropped preview after calibration undo", { model.histogram?.pixelCount == 900 })
    #expect(model.errorMessage == nil)
  }

  @Test func rapidCropAndFrameChangesNeverExposeOldGeometryOrHistogram() async throws {
    let model = EditorModel()
    let assets = try #require(model.assets)
    let folder = try fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    _ = try write("A.tif", folder: folder, width: 512, height: 384,
                  profile: assets.profile, value: 8192)
    _ = try write("B.tif", folder: folder, width: 84, height: 72,
                  profile: assets.profile, value: 49152)
    model.open(folder)
    model.stage = .l0
    let frames = try #require(model.project?.frames)
    try await until("race source A loaded", { model.histogram != nil })
    for index in 0..<8 {
      model.beginCrop()
      model.updateCropDraft(FrameCrop(aspect: index % 2 == 0 ? .square : .threeTwo,
        width: 0.6, angleDegrees: Double(index)))
      model.commitCrop()
      if let visible = model.previewImage {
        let size = model.cropPreviewTransition?.size
          ?? CGSize(width: model.displayWidth, height: model.displayHeight)
        #expect(CGFloat(visible.width) * size.height == CGFloat(visible.height) * size.width)
      }
    }
    model.select(frames[1].id)
    try await until("race source B loaded", { model.histogram?.pixelCount == 84 * 72 })
    let sourceHistogram = try #require(model.histogram)
    model.beginCrop()
    model.updateCropDraft(FrameCrop(aspect: .sevenSix, width: 0.5))
    model.commitCrop()
    for index in 0..<10 { model.select(frames[index % 2].id) }
    model.select(frames[1].id)
    try await until("latest cropped B histogram", { model.histogram?.pixelCount == 42 * 36 })
    let result = try #require(model.histogram)
    #expect(model.activeFrame?.id == frames[1].id)
    #expect(model.displayWidth == 42 && model.displayHeight == 36)
    #expect(model.previewImage?.width == 42 && model.previewImage?.height == 36)
    // Histogram stage is independent of the l0 photo preview (defaults to Final).
    // A uniform B must retain its own channel distribution after cropping.
    #expect(result.stage == sourceHistogram.stage)
    for (channel, source) in zip(result.channels, sourceHistogram.channels) {
      #expect(channel.bins == source.bins.map { $0 * (42 * 36) / (84 * 72) })
      #expect(channel.bins.reduce(0, +) == 42 * 36)
    }
    try await Task.sleep(for: .milliseconds(200))
    #expect(model.histogram == result)
    #expect(model.previewImage?.width == 42 && model.previewImage?.height == 36)
    #expect(model.errorMessage == nil)
  }
}
