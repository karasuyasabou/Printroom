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
    var histogram: HistogramStatistics? = nil
    var bytes: Int {
      image.bytesPerRow * image.height + (histogram.map { stats in
        stats.channels.count * MemoryLayout<HistogramChannel>.stride
          + stats.channels.reduce(0) { $0 + $1.bins.count * MemoryLayout<UInt64>.stride }
      } ?? 0)
    }
  }
  private(set) var entries: [Entry] = []
  let byteLimit: Int
  let countLimit: Int
  var bytes: Int { entries.reduce(0) { $0 + $1.bytes } }

  // Forty square UInt16 RGBA previews and their histograms fit in this budget.
  init(byteLimit: Int = 832 * 1024 * 1024, countLimit: Int = 40) {
    self.byteLimit = max(0, byteLimit)
    self.countLimit = max(0, countLimit)
  }

  mutating func image(for key: PreviewPresentationKey) -> Entry? {
    guard let index = entries.firstIndex(where: { $0.key == key }) else { return nil }
    let hit = entries.remove(at: index)
    entries.append(hit)
    return hit
  }

  func contains(_ key: PreviewPresentationKey, histogramStage: PipelineStage?) -> Bool {
    entries.contains { $0.key == key && (histogramStage == nil || $0.histogram?.stage == histogramStage) }
  }

  mutating func store(_ entry: Entry) {
    var entry = entry
    // Crop editing does not compute statistics, but may share the same full-image key.
    if entry.histogram == nil, let previous = entries.first(where: { $0.key == entry.key }) {
      entry.histogram = previous.histogram
    }
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
