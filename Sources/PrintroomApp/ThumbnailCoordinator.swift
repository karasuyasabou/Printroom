import CoreGraphics
import CryptoKit
import Foundation
import PrintroomCore

/// Owns the disposable thumbnail queue and its independent input/render/cache lane.
/// Project snapshots are read-only; the editor decides whether an image may be published.
@MainActor final class ThumbnailCoordinator {
  private let thumbnailRenderer = PreviewRenderService()
  private let thumbnailService = ImageService(cacheLimitBytes: 16 * 1024 * 1024, cacheLimitEntries: 12)
  private var pendingThumbnailIDs: Set<UUID> = []
  private var thumbnailTask: Task<Void, Never>?
  private var thumbnailGeneration = UUID()
  var isRunning: Bool { thumbnailTask != nil }

  func reset() {
    thumbnailTask?.cancel()
    thumbnailTask = nil
    thumbnailGeneration = UUID()
    pendingThumbnailIDs = []
  }

  func waitForCompletion() async -> Bool {
    await thumbnailTask?.value
    return pendingThumbnailIDs.isEmpty
  }

  private func sourceIsCurrent(_ source: SourceStamp) -> Bool {
    (try? SourceStamp(url: source.url)) == source
  }

  func refresh(project: RollProject, folder: URL, assets: AppAssets,
    activeFrameID: UUID?, affectedIDs: Set<UUID>? = nil,
    publish: @escaping @MainActor (CGImage, PreviewPresentationKey) -> Bool,
    finished: @escaping @MainActor () -> Void) {
    let available = Set(project.frames.filter { !$0.isMissing }.map(\.id))
    pendingThumbnailIDs.formUnion(affectedIDs ?? available)
    pendingThumbnailIDs.formIntersection(available)
    thumbnailTask?.cancel()
    thumbnailGeneration = UUID()
    let generation = thumbnailGeneration
    let frames = project.frames.filter { pendingThumbnailIDs.contains($0.id) }
      .sorted { $0.id == activeFrameID && $1.id != activeFrameID }
    let cache = DiskThumbnailCache.forRoll(folder: folder, projectID: project.id)
    let queuedTrace = PerformanceTrace.begin()
    thumbnailTask = Task { [weak self] in
      guard let self else { return }
      PerformanceTrace.end("thumbnail.initial_queue_wait", queuedTrace)
      let rollTrace = PerformanceTrace.begin()
      defer { PerformanceTrace.end("thumbnail.roll_refresh_inclusive", rollTrace) }
      defer {
        if generation == thumbnailGeneration {
          thumbnailTask = nil
          finished()
        }
      }
      if affectedIDs == nil {
        try? await cache.migrateLegacy(from: folder)
        _ = try? await cache.maintain()
      }
      await cache.beginMaintenanceBatch()
      defer { cache.endMaintenanceBatch() }
      for frame in frames {
        PerformanceTrace.end("thumbnail.frame_queue_delay_inclusive", queuedTrace)
        guard !Task.isCancelled, generation == thumbnailGeneration else { return }
        do {
          let sourceURL = folder.appendingPathComponent(frame.filename)
          let stamp = try SourceStamp(url: sourceURL)
          let presentationKey = PreviewPresentationKey(source: stamp, frameID: frame.id,
            calibration: project.calibration, adjustments: frame.adjustments,
            orientation: frame.orientation, crop: frame.crop, stage: .final,
            sprocketWhitening: project.sprocketWhitening,
            protectedCrop: frame.crop)
          let encoder = JSONEncoder()
          encoder.outputFormatting = .sortedKeys
          let keyData = try encoder.encode(
            ThumbnailKey(
              filename: frame.filename,
              modified: stamp.modified?.timeIntervalSince1970 ?? 0,
              size: stamp.size,
              inode: stamp.inode,
              calibration: project.calibration, adjustments: frame.adjustments,
              orientation: frame.orientation,
              crop: frame.crop,
              sprocketWhitening: project.sprocketWhitening,
              algorithm: algorithmVersion, icc: ProjectAssetIdentity.expectedICCSHA256,
              lut: frame.adjustments.cineonLogLUT.sha256, dimension: 240,
              presentationVersion: DisplayImage.presentationVersion,
              rawProcessing: stamp.rawProcessing))
          let key = SHA256.hash(data: keyData).map { String(format: "%02x", $0) }.joined()
          let cacheTrace = PerformanceTrace.begin()
          let cachedImage = try? await cache.image(for: key)
          PerformanceTrace.end("thumbnail.cache_lookup", cacheTrace)
          if let cg = cachedImage {
            guard !Task.isCancelled, generation == thumbnailGeneration else { return }
            let accepted = sourceIsCurrent(stamp) && publish(cg, presentationKey)
            // Publication can synchronously enqueue/reset work through observers.
            guard !Task.isCancelled, generation == thumbnailGeneration else { return }
            if accepted { pendingThumbnailIDs.remove(frame.id) }
            continue
          }
          let readTrace = PerformanceTrace.begin()
          let source = try await thumbnailService.thumbnailSource(sourceURL)
          PerformanceTrace.end("thumbnail.source_read", readTrace)
          let renderTrace = PerformanceTrace.begin()
          let output = try await thumbnailRenderer.render(source.0,
            calibration: project.calibration, adjustments: frame.adjustments,
            assets: assets, original: !project.calibration.isCalibrated,
            orientation: frame.orientation, crop: frame.crop,
            sourceWidth: source.1, sourceHeight: source.2,
            sprocketWhitening: project.sprocketWhitening,
            protectedCrop: frame.crop)
          guard !Task.isCancelled, generation == thumbnailGeneration else { return }
          PerformanceTrace.end("thumbnail.render_display_inclusive", renderTrace)
          let accepted = sourceIsCurrent(stamp) && publish(output.image, presentationKey)
          // Expendable disk cache failures never prevent editing or project save.
          try? await cache.store(output.image, for: key)
          guard !Task.isCancelled, generation == thumbnailGeneration else { return }
          if accepted { pendingThumbnailIDs.remove(frame.id) }
        } catch {
          // Keep the frame pending for a later refresh; disposable thumbnails
          // must not interrupt editing or replace the main preview's error.
        }
      }
    }
  }
  private struct ThumbnailKey: Codable {
    let filename: String
    let modified: Double
    let size: Int64
    let inode: UInt64
    let calibration: FilmCalibration
    let adjustments: FrameAdjustments
    let orientation: FrameOrientation
    let crop: FrameCrop?
    let sprocketWhitening: SprocketWhiteningSettings
    let algorithm: String
    let icc: String
    let lut: String
    let dimension: Int
    let presentationVersion: String
    let rawProcessing: RAWProcessingIdentity?
  }
}
