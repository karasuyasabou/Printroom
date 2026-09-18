import PrintroomCore

/// The same source neighbourhood as the neutral picker, without its rejection
/// of clipped samples. Transform every pixel before taking channel medians.
enum HistogramProbe {
  static func median(_ samples: PixelBuffer, calibration: FilmCalibration,
    adjustments: FrameAdjustments, lut: CubeLUT, stage: PipelineStage
  ) throws -> SIMD3<Float> {
    let output = try Pipeline.render(samples, calibration: calibration,
      adjustments: adjustments, lut: lut, stage: stage)
    var result = SIMD3<Float>(repeating: 0)
    for channel in 0..<3 {
      let values = output.pixels.map { $0[channel] }.sorted()
      let middle = values.count / 2
      result[channel] = values.count.isMultiple(of: 2)
        ? (values[middle - 1] + values[middle]) / 2 : values[middle]
    }
    return result
  }
}
