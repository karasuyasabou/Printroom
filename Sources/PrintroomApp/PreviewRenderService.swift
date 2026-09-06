import CoreGraphics
import Foundation
import PrintroomCore

struct RenderedPreview: Sendable {
  let pixels: PixelBuffer
  let image: CGImage
}

/// Serializes one interactive render lane, including UInt16 display preparation.
/// A cancelled queued request exits before allocating Metal buffers. The GPU's
/// already submitted command completes, then its stale result is discarded.
actor PreviewRenderService {
  func render(
    _ input: PixelBuffer, calibration: FilmCalibration, adjustments: FrameAdjustments,
    assets: AppAssets, stage: PipelineStage = .final,
    orientation: FrameOrientation = .identity
  ) throws -> RenderedPreview {
    try autoreleasepool {
      try Task.checkCancellation()
      let output = try assets.gpu.render(
        input, calibration: calibration, adjustments: adjustments, lut: assets.lut, stage: stage)
      try Task.checkCancellation()
      let oriented = try orientation.transform(output, cancelled: { Task.isCancelled })
      try Task.checkCancellation()
      let image = try DisplayImage.make(
        oriented, profile: assets.profile, diagnostic: stage != .final)
      try Task.checkCancellation()
      return RenderedPreview(pixels: oriented, image: image)
    }
  }
}
