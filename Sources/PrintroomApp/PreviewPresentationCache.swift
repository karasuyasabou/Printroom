import CoreGraphics
import Foundation
import PrintroomCore

struct PreviewPresentationKey: Equatable {
  let source: SourceStamp
  let frameID: UUID
  let calibration: FilmCalibration
  let adjustments: FrameAdjustments
  let orientation: FrameOrientation
  let crop: FrameCrop?
  let stage: PipelineStage
  var sprocketWhitening: SprocketWhiteningSettings = .init()
  var protectedCrop: FrameCrop? = nil
}

struct PreviewPresentationCache {
  struct Entry {
    let key: PreviewPresentationKey
    let image: CGImage
    let sourceWidth: Int
    let sourceHeight: Int
    var bytes: Int { image.bytesPerRow * image.height }
  }
  private(set) var entries: [Entry] = []
  let byteLimit: Int
  let countLimit: Int
  var bytes: Int { entries.reduce(0) { $0 + $1.bytes } }

  // Match the input cache's twelve frames, including 1600×1600 UInt16 RGBA images.
  init(byteLimit: Int = 256 * 1024 * 1024, countLimit: Int = 12) {
    self.byteLimit = max(0, byteLimit)
    self.countLimit = max(0, countLimit)
  }

  mutating func image(for key: PreviewPresentationKey) -> Entry? {
    guard let index = entries.firstIndex(where: { $0.key == key }) else { return nil }
    let hit = entries.remove(at: index)
    entries.append(hit)
    return hit
  }

  mutating func store(_ entry: Entry) {
    // Keep at most one displayed revision of each frame/stage.
    entries.removeAll { $0.key.frameID == entry.key.frameID && $0.key.stage == entry.key.stage }
    guard countLimit > 0, entry.bytes <= byteLimit else { return }
    while !entries.isEmpty, entries.count >= countLimit || bytes + entry.bytes > byteLimit {
      entries.removeFirst()
    }
    entries.append(entry)
  }

  mutating func clear() { entries.removeAll() }
}
