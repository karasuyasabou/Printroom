import CoreGraphics
import Foundation
import PrintroomCore
import Testing
@testable import PrintroomApp

@Suite(.serialized) @MainActor
struct EditorRefinementTests {
  private func fixture(_ model: EditorModel, count: Int = 2) throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PrintroomRefinement-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let profile = try #require(model.assets).profile
    for i in 0..<count {
      try TIFFCodec.write(url: folder.appendingPathComponent("\(i).tif"),
        width: 64, height: 48, profile: profile) { rows in
        var samples: [UInt16] = []
        for y in rows { for x in 0..<64 {
          samples += [UInt16(10000 + x * 80), UInt16(16000 + y * 80), UInt16(23000 + i * 3000)]
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
    #expect(model.histogram?.stage == .l0)
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
    #expect(model.histogram?.stage == .d2)
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
    // Source crop is x=16...48, y=8...40; clockwise output pixel (0,0)
    // corresponds to source (16,39). Neighbourhood is x=11...21,y=34...44.
    let samples = try await model.imageService.region(folder.appendingPathComponent(frame.filename),
      rect: PixelRect(x: 11, y: 34, width: 11, height: 11))
    let expected = try NeutralTiming.solve(samples, calibration: before.calibration,
      adjustments: frame.adjustments)
    model.toggleNeutralPicker()
    #expect(model.neutralPicking)
    model.pickNeutralDisplayed(x: 0, y: 0)
    #expect(!model.neutralPicking && model.isNeutralSampling)
    try await until("neutral sample") { !model.isNeutralSampling }
    #expect(model.adjustments == expected)
    #expect(model.adjustments.timing.master == 200)
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
