import Combine
import CoreGraphics
import Foundation
import PrintroomCore
import Testing

@testable import PrintroomApp

/// Functional scheduler regressions use small local TIFFs, not wall-clock FPS
/// thresholds. The opt-in performance suite measures the full-sized workload.
@Suite(.serialized) @MainActor
struct AdjustmentSchedulingTests {
  @Test func continuousInputPublishesBeforeReleaseAndSettlesToLatestParameters() async throws {
    let model = EditorModel()
    let assets = try #require(model.assets)
    let folder = try fixture(profile: assets.profile)
    defer { try? FileManager.default.removeItem(at: folder) }
    model.open(folder)
    try await settled(model, thumbnails: 1)
    let probe = SchedulingPublicationProbe()
    let subscription = model.$previewImage.dropFirst().sink { image in
      if image != nil { probe.record() }
    }
    defer { subscription.cancel() }

    model.beginAdjustment()
    // Every interval is shorter than the old 25 ms trailing debounce. This is
    // sustained input, so a scheduler that waits for release cannot pass.
    for step in 1...80 {
      model.edit {
        $0.timing.master = step
        $0.timing.red = -step / 3
        $0.contrast.master = 1 + Float(step) / 500
      }
      try await Task.sleep(for: .milliseconds(8))
    }
    #expect(probe.count > 1, "Continuous input must publish multiple previews before release")
    model.endAdjustment()
    try await settled(model, thumbnails: 1)
    #expect(model.adjustments.timing.master == 80)
    #expect(model.adjustments.timing.red == -26)
    try await verifyFinalPreview(model, folder: folder, assets: assets)
    #expect(model.flushSave())
  }

  @Test func frameStageAndDirectionBurstsCannotPublishOldContext() async throws {
    let model = EditorModel()
    let assets = try #require(model.assets)
    let folder = try fixture(profile: assets.profile, count: 2)
    defer { try? FileManager.default.removeItem(at: folder) }
    model.open(folder)
    try await settled(model, thumbnails: 2)
    let frames = try #require(model.project?.frames)
    for step in 0..<18 {
      model.select(frames[step % 2].id)
      model.stage = step % 3 == 0 ? .d0 : .final
      model.changeOrientation(step % 2 == 0 ? .rotateClockwise : .flipVertical)
      model.edit { $0.timing.blue = step * 7 }
      // Let some older requests actually start rather than only replacing jobs
      // in one MainActor turn.
      if step % 3 == 0 { try await Task.sleep(for: .milliseconds(2)) }
    }
    model.select(frames[1].id)
    model.stage = .d2
    model.changeOrientation(.rotateClockwise)
    model.edit { $0.timing.master = 137; $0.contrast.green = 1.3 }
    try await settled(model, thumbnails: 2)
    #expect(model.activeFrame?.id == frames[1].id)
    #expect(model.histogram?.stage == .d2)
    try await verifyFinalPreview(model, folder: folder, assets: assets)
    let finalImage = try #require(model.previewImage)
    let finalHistogram = model.histogram
    // Previously submitted work can finish, but cannot replace this result.
    try await Task.sleep(for: .milliseconds(200))
    #expect(model.previewImage === finalImage)
    #expect(model.histogram == finalHistogram)
    #expect(model.flushSave())
  }

  @Test func releasingOneFrameRefreshesOnlyItsThumbnail() async throws {
    let model = EditorModel()
    let assets = try #require(model.assets)
    let folder = try fixture(profile: assets.profile, count: 2)
    defer { try? FileManager.default.removeItem(at: folder) }
    model.open(folder)
    try await settled(model, thumbnails: 2)
    let frames = try #require(model.project?.frames)
    let first = try #require(model.thumbnails[frames[0].id])
    let untouched = try #require(model.thumbnails[frames[1].id])
    model.beginAdjustment()
    for step in 1...12 {
      model.edit { $0.timing.red = step * 5 }
      try await Task.sleep(for: .milliseconds(3))
    }
    #expect(model.thumbnails[frames[0].id] === first)
    #expect(model.thumbnails[frames[1].id] === untouched)
    model.endAdjustment()
    try await until("edited thumbnail after release") {
      model.thumbnails[frames[0].id] !== first
    }
    try await settled(model, thumbnails: 2)
    #expect(model.thumbnails[frames[1].id] === untouched)
    let expected = try await referenceThumbnail(model, frameID: frames[0].id,
      folder: folder, assets: assets)
    try expectSameThumbnail(try #require(model.thumbnails[frames[0].id]), expected)
    #expect(model.flushSave())
  }

  @Test func applyUndoAndRollMatrixInvalidateTheCorrectThumbnails() async throws {
    let model = EditorModel()
    let assets = try #require(model.assets)
    let folder = try fixture(profile: assets.profile, count: 3)
    defer { try? FileManager.default.removeItem(at: folder) }
    model.open(folder)
    try await settled(model, thumbnails: 3)
    let frames = try #require(model.project?.frames)
    let initialA = try #require(model.thumbnails[frames[0].id])
    model.edit { $0.timing.green = 83; $0.contrast.blue = 1.25 }
    try await until("source thumbnail") { model.thumbnails[frames[0].id] !== initialA }
    try await settled(model, thumbnails: 3)
    model.copyParameters()
    let sourceThumbnail = try #require(model.thumbnails[frames[0].id])
    let beforeApply = model.thumbnails
    model.select(frames[1].id)
    model.select(frames[2].id, command: true)
    let beforeProject = try #require(model.project)
    model.applyParameters()
    try await until("both apply targets refreshed") {
      model.thumbnails[frames[1].id] !== beforeApply[frames[1].id]
        && model.thumbnails[frames[2].id] !== beforeApply[frames[2].id]
    }
    try await settled(model, thumbnails: 3)
    #expect(model.thumbnails[frames[0].id] === sourceThumbnail)
    #expect(model.project?.frames.allSatisfy { $0.adjustments.timing.green == 83 } == true)
    for frame in frames.dropFirst() {
      let expected = try await referenceThumbnail(model, frameID: frame.id, folder: folder, assets: assets)
      try expectSameThumbnail(try #require(model.thumbnails[frame.id]), expected)
    }

    let applied = model.thumbnails
    model.undo()
    try await until("both undo targets refreshed") {
      model.thumbnails[frames[1].id] !== applied[frames[1].id]
        && model.thumbnails[frames[2].id] !== applied[frames[2].id]
    }
    try await settled(model, thumbnails: 3)
    #expect(model.project?.frames == beforeProject.frames)
    #expect(model.thumbnails[frames[0].id] === sourceThumbnail)
    let beforeMatrix = model.thumbnails
    model.setMatrix(.ledLightSource)
    try await until("roll matrix refreshes every thumbnail") {
      frames.allSatisfy { model.thumbnails[$0.id] !== beforeMatrix[$0.id] }
    }
    try await settled(model, thumbnails: 3)
    #expect(model.project?.calibration.matrix == .ledLightSource)
    for frame in frames {
      let expected = try await referenceThumbnail(model, frameID: frame.id, folder: folder, assets: assets)
      try expectSameThumbnail(try #require(model.thumbnails[frame.id]), expected)
    }
    #expect(model.flushSave())
  }

  @Test func editsDuringInitialThumbnailWorkPreserveAllPendingFrames() async throws {
    let model = EditorModel()
    let assets = try #require(model.assets)
    let folder = try fixture(profile: assets.profile, count: 16)
    defer { try? FileManager.default.removeItem(at: folder) }
    model.open(folder)
    let frames = try #require(model.project?.frames)
    #expect(model.thumbnails.isEmpty)
    // These refreshes cancel the initial worker before it gets its first turn.
    // Its remaining frame IDs must survive every replacement generation.
    for step in 1...4 { model.edit { $0.timing.red = step * 9 } }
    for step in 5...24 {
      try await Task.sleep(for: .milliseconds(2))
      model.edit { $0.timing.red = step * 9 }
    }
    try await settled(model, thumbnails: frames.count)
    #expect(Set(model.thumbnails.keys) == Set(frames.map(\.id)))
    #expect(model.adjustments.timing.red == 216)
    for frame in frames {
      let expected = try await referenceThumbnail(model, frameID: frame.id, folder: folder, assets: assets)
      try expectSameThumbnail(try #require(model.thumbnails[frame.id]), expected)
    }
    try await verifyFinalPreview(model, folder: folder, assets: assets)
    #expect(model.flushSave())
  }

  private func fixture(profile: Data, count: Int = 1) throws -> URL {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PrintroomScheduling-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for index in 0..<count {
      let width = 96 + index * 2, height = 64 + index
      try TIFFCodec.write(url: folder.appendingPathComponent(String(format: "%02d.tif", index)),
        width: width, height: height, profile: profile) { rows in
        (rows.lowerBound * width * 3..<rows.upperBound * width * 3).map {
          UInt16(1800 + ($0 * 173 + index * 991) % 57000)
        }
      }
    }
    return folder
  }

  private func until(_ message: String, _ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(15))
    while !predicate(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    try #require(predicate(), "Timed out waiting for \(message)")
  }

  private func settled(_ model: EditorModel, thumbnails: Int) async throws {
    try await until("latest preview, histogram and \(thumbnails) thumbnails") {
      !model.isLoading && !model.isRendering && !model.isHistogramUpdating
        && model.previewImage != nil && model.histogram != nil
        && model.thumbnails.count == thumbnails
    }
    #expect(model.errorMessage == nil)
  }

  private func verifyFinalPreview(_ model: EditorModel, folder: URL, assets: AppAssets) async throws {
    let frame = try #require(model.activeFrame)
    let calibration = try #require(model.project?.calibration)
    let input = try await ImageService().preview(folder.appendingPathComponent(frame.filename)).0
    // Use the stateless GPU entry point so the reference cannot hit the new
    // session's reused input or intermediate cache.
    let reference = try assets.gpu.render(input, calibration: calibration,
      adjustments: frame.adjustments, lut: assets.lut, stage: model.stage)
    let oriented = try frame.orientation.transform(reference)
    let image = try DisplayImage.make(oriented, profile: assets.profile, diagnostic: model.stage != .final)
    try expectSameImage(try #require(model.previewImage), image)
    #expect(model.histogram == (try HistogramStatistics.computePreview(oriented, stage: model.stage)))
    let cpu = try Pipeline.render(input, calibration: calibration,
      adjustments: frame.adjustments, lut: assets.lut, stage: model.stage)
    var maxError: Float = 0
    for (actual, expected) in zip(reference.pixels, cpu.pixels) {
      for channel in 0..<3 { maxError = max(maxError, abs(actual[channel] - expected[channel])) }
    }
    #expect(maxError <= 0.0002, "Whole-image CPU/GPU maximum absolute error: \(maxError)")
  }

  private func referenceThumbnail(_ model: EditorModel, frameID: UUID,
    folder: URL, assets: AppAssets) async throws -> CGImage {
    let project = try #require(model.project)
    let frame = try #require(project.frames.first { $0.id == frameID })
    let input = try await ImageService().thumbnail(folder.appendingPathComponent(frame.filename))
    let pixels = try assets.gpu.render(input, calibration: project.calibration,
      adjustments: frame.adjustments, lut: assets.lut)
    return try DisplayImage.make(frame.orientation.transform(pixels), profile: assets.profile)
  }

  private func expectSameThumbnail(_ actual: CGImage, _ expected: CGImage) throws {
    #expect(actual.width == expected.width && actual.height == expected.height)
    // PNG cache reads can use a different component packing/byte order. Drawing
    // both through the same color space compares visible content independently
    // of that disposable storage representation.
    func canonicalBytes(_ image: CGImage) throws -> [UInt8] {
      var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
      try bytes.withUnsafeMutableBytes { storage in
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: storage.baseAddress,
          width: image.width, height: image.height, bitsPerComponent: 8,
          bytesPerRow: image.width * 4,
          space: space,
          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
      }
      return bytes
    }
    let actualBytes = try canonicalBytes(actual)
    let expectedBytes = try canonicalBytes(expected)
    let maximumDifference = zip(actualBytes, expectedBytes).map { abs(Int($0) - Int($1)) }.max() ?? 0
    #expect(maximumDifference <= 1)
  }

  private func expectSameImage(_ actual: CGImage, _ expected: CGImage) throws {
    #expect(actual.width == expected.width && actual.height == expected.height)
    #expect(actual.bitsPerComponent == 16 && actual.bitsPerPixel == 64)
    let actualBytes = try #require(actual.dataProvider?.data as Data?)
    let expectedBytes = try #require(expected.dataProvider?.data as Data?)
    #expect(actualBytes == expectedBytes)
  }
}

private final class SchedulingPublicationProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var publications = 0
  func record() {
    lock.lock()
    publications += 1
    lock.unlock()
  }
  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return publications
  }
}
