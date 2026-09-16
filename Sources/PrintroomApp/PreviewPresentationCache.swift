import CoreGraphics
import Foundation
import PrintroomCore

/// Display-only snapshots. Their exact identity prevents a cached photo from
/// being paired with another crop, stage, source revision, or set of controls.
struct PreviewSourceStamp: Equatable {
  let url: URL
  let size: Int64
  let modified: Date?
  let inode: UInt64
  let rawProcessing: RAWProcessingIdentity?

  init(url: URL) throws {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    rawProcessing = try SourceImageIO.processingIdentity(url: url)
    self.url = url.standardizedFileURL
    size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
    modified = attributes[.modificationDate] as? Date
    inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
  }
}

struct PreviewPresentationKey: Equatable {
  let source: PreviewSourceStamp
  let frameID: UUID
  let calibration: FilmCalibration
  let adjustments: FrameAdjustments
  let orientation: FrameOrientation
  let crop: FrameCrop?
  let stage: PipelineStage
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

  init(byteLimit: Int = 64 * 1024 * 1024, countLimit: Int = 4) {
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
