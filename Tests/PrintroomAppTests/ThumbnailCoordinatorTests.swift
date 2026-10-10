import CoreGraphics
import Foundation
@testable import PrintroomCore
import Testing
@testable import PrintroomApp

@Suite(.serialized) @MainActor
struct ThumbnailCoordinatorTests {
  private func fixture() throws -> (URL, RollProject, AppAssets) {
    let assets = try AppAssets()
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("thumbnail-coordinator-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for name in ["A.tif", "B.tif"] {
      try TIFFCodec.write(url: folder.appendingPathComponent(name), width: 12, height: 8,
        profile: assets.profile) { rows in
        [UInt16](repeating: 32768, count: rows.count * 12 * 3)
      }
    }
    return (folder, try ProjectStore.open(folder: folder), assets)
  }

  // PNG is RGB while the render result is RGBA. Compare every RGB UInt16
  // sample directly, respecting row stride/endian order and checking opaque alpha.
  private func normalizedPixels(_ image: CGImage) throws -> [UInt16] {
    try #require(image.bitsPerComponent == 16)
    let alpha = image.alphaInfo
    try #require(alpha == .none || alpha == .noneSkipLast)
    let order = image.bitmapInfo.intersection(.byteOrderMask)
    try #require(order == .byteOrder16Little || order == .byteOrder16Big)
    let bytes = Array(try #require(image.dataProvider?.data) as Data)
    let pixelStride = image.bitsPerPixel / 8
    func sample(_ offset: Int) -> UInt16 {
      let a = UInt16(bytes[offset]), b = UInt16(bytes[offset + 1])
      return order == .byteOrder16Little ? a | (b << 8) : (a << 8) | b
    }
    var result: [UInt16] = []
    for y in 0..<image.height {
      for x in 0..<image.width {
        let offset = y * image.bytesPerRow + x * pixelStride
        result.append(contentsOf: (0..<3).map { sample(offset + $0 * 2) })
        if alpha == .noneSkipLast { #expect(sample(offset + 6) == 65535) }
      }
    }
    return result
  }

  @Test func supersedingRefreshKeepsPendingFramesAndOnlyPublishesLatestSnapshot() async throws {
    let (folder, roll, assets) = try fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let coordinator = ThumbnailCoordinator()
    var obsoletePublications = 0, obsoleteFinishes = 0, finishes = 0
    coordinator.refresh(project: roll, folder: folder, assets: assets, activeFrameID: nil,
      publish: { _, _ in obsoletePublications += 1; return true },
      finished: { obsoleteFinishes += 1 })
    var latest = roll
    latest.frames[1].orientation = .rotate90CW
    latest.frames[1].adjustments.timing.red = 37
    var published: [UUID: PreviewPresentationKey] = [:]
    var dimensions: [UUID: [Int]] = [:]
    coordinator.refresh(project: latest, folder: folder, assets: assets,
      activeFrameID: latest.frames[1].id, affectedIDs: [latest.frames[1].id],
      publish: { image, key in
        published[key.frameID] = key
        dimensions[key.frameID] = [image.width, image.height]
        return true
      }, finished: { finishes += 1 })
    #expect(await coordinator.waitForCompletion())
    #expect(!coordinator.isRunning && finishes == 1)
    #expect(obsoletePublications == 0 && obsoleteFinishes == 0)
    #expect(Set(published.keys) == Set(roll.frames.map(\.id)))
    #expect(published[latest.frames[1].id]?.adjustments == latest.frames[1].adjustments)
    #expect(dimensions[latest.frames[1].id] == [8, 12])
  }

  @Test(arguments: [false, true])
  func resetDuringPublicationPreventsOldFramesAndCompletionFromLeakingIntoNextRun(warmCache: Bool) async throws {
    let (folder, roll, assets) = try fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let coordinator = ThumbnailCoordinator()
    if warmCache {
      coordinator.refresh(project: roll, folder: folder, assets: assets, activeFrameID: nil,
        publish: { _, _ in true }, finished: {})
      #expect(await coordinator.waitForCompletion())
    }
    var oldPublications = 0, oldFinishes = 0, newFinishes = 0
    var newFrames: Set<UUID> = []
    coordinator.refresh(project: roll, folder: folder, assets: assets,
      activeFrameID: roll.frames[0].id, publish: { _, _ in
        oldPublications += 1
        coordinator.reset()
        #expect(!coordinator.isRunning)
        coordinator.refresh(project: roll, folder: folder, assets: assets,
          activeFrameID: roll.frames[1].id, publish: { _, key in
            newFrames.insert(key.frameID)
            return true
          }, finished: { newFinishes += 1 })
        return true
      }, finished: { oldFinishes += 1 })
    // The old task is cancelled from its publication callback, after rendering has finished.
    _ = await coordinator.waitForCompletion()
    #expect(await coordinator.waitForCompletion())
    #expect(oldPublications == 1 && oldFinishes == 0 && newFinishes == 1)
    #expect(newFrames == Set(roll.frames.map(\.id)))
    #expect(!coordinator.isRunning)
  }

  @Test func rejectedPublicationStaysPendingAndCanRetryFromDiskCache() async throws {
    let (folder, roll, assets) = try fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let coordinator = ThumbnailCoordinator()
    var rejected: [UUID: CGImage] = [:]
    coordinator.refresh(project: roll, folder: folder, assets: assets, activeFrameID: nil,
      publish: { image, key in rejected[key.frameID] = image; return false }, finished: {})
    #expect(!(await coordinator.waitForCompletion()))
    #expect(rejected.count == 2 && !coordinator.isRunning)
    var accepted: Set<UUID> = []
    coordinator.refresh(project: roll, folder: folder, assets: assets,
      activeFrameID: nil, affectedIDs: [], publish: { image, key in
        accepted.insert(key.frameID)
        #expect(image.width == rejected[key.frameID]?.width)
        do {
          let previous = try #require(rejected[key.frameID])
          #expect(image.height == previous.height && image.bitsPerComponent == 16)
          #expect(image.colorSpace?.copyICCData() == previous.colorSpace?.copyICCData())
          #expect(try normalizedPixels(image) == normalizedPixels(previous))
        } catch { /* #require records the failed pixel-layout expectation. */ }
        return true
      }, finished: {})
    #expect(await coordinator.waitForCompletion())
    #expect(accepted == Set(roll.frames.map(\.id)))
  }

  private func waitForEditorThumbnails(_ model: EditorModel) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while model.thumbnails.count != model.project?.frames.count, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(model.thumbnails.count == model.project?.frames.count)
  }

  @Test(arguments: [false, true])
  func editorAcceptsThumbnailAfterProcessingMetadataArrives(warmCache: Bool) async throws {
    let (folder, _, _) = try fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let model = EditorModel()
    _ = try #require(model.assets)
    model.open(folder)
    try await waitForProxyImport(model)
    try await waitForEditorThumbnails(model)
    let frameID = try #require(model.activeFrame?.id)
    if warmCache {
      model.thumbnails[frameID] = nil
      model.changeOrientation(.rotateClockwise)
      try await waitForEditorThumbnails(model)
      model.thumbnails[frameID] = nil
      model.changeOrientation(.rotateCounterclockwise)
      try await waitForEditorThumbnails(model)
    }
    model.thumbnails[frameID] = nil
    model.changeOrientation(.rotateClockwise)
    // Reproduce loadActive's RAW identity publication while the thumbnail's
    // immutable snapshot is queued. Synthetic TIFF avoids Adobe/real RAW input.
    let index = try #require(model.project?.frames.firstIndex { $0.id == frameID })
    model.project?.frames[index].rawProcessing = RAWProcessingIdentity(
      sourceRevision: "metadata-arrived", adobeVersion: "18.1.1", libRawVersion: "0.22.1",
      strategyVersion: "adobe-linear-camera-rgb-v1", proxySamplingVersion: "nearest-original-v1")
    try await waitForEditorThumbnails(model)
    let thumbnail = try #require(model.thumbnails[frameID])
    #expect(thumbnail.width == 8 && thumbnail.height == 12)
    model.returnHome()
  }
}
