import CoreGraphics
import Foundation
import PrintroomCore

struct RenderedPreview: Sendable {
  let pixels: PixelBuffer
  let image: CGImage
  var histogram: HistogramStatistics? = nil
}

/// Serializes one interactive render lane, including UInt16 display preparation.
/// A cancelled queued request exits before allocating Metal buffers. The GPU's
/// already submitted command completes, then its stale result is discarded.
actor PreviewRenderService {
  private var pipeline: MetalPipeline?
  private var session: MetalPipeline.Session?
  private struct GeometryKey: Equatable {
    let source: UUID
    let crop: FrameCrop
    let orientation: FrameOrientation
    let width: Int
    let height: Int
  }
  private var geometryKey: GeometryKey?
  private var geometryInput: PixelBuffer?
  private var geometryIdentity = UUID()
  func render(
    _ input: PixelBuffer, calibration: FilmCalibration, adjustments: FrameAdjustments,
    assets: AppAssets, stage: PipelineStage = .final,
    orientation: FrameOrientation = .identity, inputIdentity: UUID? = nil,
    crop: FrameCrop? = nil, sourceWidth: Int? = nil, sourceHeight: Int? = nil,
    includeHistogram: Bool = false
  ) throws -> RenderedPreview {
    try autoreleasepool {
      try Task.checkCancellation()
      if pipeline !== assets.gpu || session == nil {
        pipeline = assets.gpu
        session = assets.gpu.makeSession()
      }
      var prepared = input
      var preparedIdentity = inputIdentity
      if let crop {
        let width = sourceWidth ?? input.width, height = sourceHeight ?? input.height
        let key = inputIdentity.map { GeometryKey(source: $0, crop: crop,
          orientation: orientation, width: width, height: height) }
        if let key, key == geometryKey, let cached = geometryInput {
          prepared = cached
        } else {
          let geometry = try CropGeometry(crop: crop, sourceWidth: width,
            sourceHeight: height, orientation: orientation)
          prepared = try geometry.render(input, maxDimension: max(input.width, input.height),
            cancelled: { Task.isCancelled })
          geometryKey = key
          geometryInput = key == nil ? nil : prepared
          geometryIdentity = UUID()
        }
        preparedIdentity = key == nil ? nil : geometryIdentity
      } else {
        geometryKey = nil
        geometryInput = nil
      }
      let output = try session!.render(
        prepared, calibration: calibration, adjustments: adjustments, lut: assets.lut, stage: stage,
        inputIdentity: preparedIdentity)
      try Task.checkCancellation()
      let oriented = crop == nil
        ? try orientation.transform(output, cancelled: { Task.isCancelled }) : output
      try Task.checkCancellation()
      let image = try DisplayImage.make(
        oriented, profile: assets.profile, diagnostic: stage != .final)
      try Task.checkCancellation()
      let histogram = includeHistogram
        ? try HistogramStatistics.computePreview(oriented, stage: stage,
            cancelled: { Task.isCancelled }) : nil
      return RenderedPreview(pixels: oriented, image: image, histogram: histogram)
    }
  }
}
