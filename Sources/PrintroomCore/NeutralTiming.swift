import Foundation

/// Finds RGB Timing for a neutral D3 sample without changing Master or Contrast.
/// Samples must be a small region of original, normalized TIFF RGB values.
public enum NeutralTiming {
  /// The median is taken after the complete density pipeline, including the LED
  /// matrix when enabled. Its mean RGB density is preserved as the neutral target;
  /// this does not attempt to preserve luminance or neutrality after the 2383 LUT.
  ///
  /// Pixels with any clipped channel (0 or 1) are excluded. A strict majority of
  /// the region must remain usable. Other out-of-domain or nonfinite inputs fail.
  /// Integer CV controls limit each result's error to half its effective Contrast
  /// in D3 CV, plus Float32 pipeline rounding. Out-of-range results fail atomically.
  public static func solve(
    _ samples: PixelBuffer, calibration: FilmCalibration, adjustments: FrameAdjustments
  ) throws -> FrameAdjustments {
    try Pipeline.validate(adjustments)
    let (count, overflow) = samples.width.multipliedReportingOverflow(by: samples.height)
    guard samples.width > 0, samples.height > 0, !overflow,
      count == samples.pixels.count
    else { throw PrintroomError.invalid("中性点取样尺寸与像素数量不匹配。") }

    var usable: [SIMD4<Float>] = []
    usable.reserveCapacity(count)
    for pixel in samples.pixels {
      let rgb = [pixel.x, pixel.y, pixel.z]
      guard rgb.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
        throw PrintroomError.invalid("中性点取样必须是 0…1 之间的有限原始 RGB 数值。")
      }
      if rgb.allSatisfy({ $0 > 0 && $0 < 1 }) { usable.append(pixel) }
    }
    guard usable.count > count / 2 else {
      throw PrintroomError.invalid("中性点附近多数像素已剪切，请选择其他位置。")
    }

    let processed = try Pipeline.render(
      PixelBuffer(width: usable.count, height: 1, pixels: usable),
      calibration: calibration, adjustments: adjustments, stage: .d3)
    let medians = (0..<3).map { channel -> Double in
      let values = processed.pixels.map { Double($0[channel]) * 1024 }.sorted()
      let middle = values.count / 2
      return values.count.isMultiple(of: 2)
        ? (values[middle - 1] + values[middle]) / 2 : values[middle]
    }
    let target = medians.reduce(0, +) / 3
    let contrast = adjustments.contrast
    let effectiveContrast = [contrast.red, contrast.green, contrast.blue].map {
      Double($0 * contrast.master)
    }
    let oldTiming = [adjustments.timing.red, adjustments.timing.green, adjustments.timing.blue]
    var solved: [Int] = []
    for channel in 0..<3 {
      let requested = Double(oldTiming[channel])
        + (target - medians[channel]) / effectiveContrast[channel]
      let rounded = requested.rounded()
      // Check the floating point value before conversion, including the finite
      // guard, so even hostile calibration values cannot trap converting to Int.
      guard rounded.isFinite,
        rounded >= Double(TimingParameters.range.lowerBound),
        rounded <= Double(TimingParameters.range.upperBound)
      else {
        throw PrintroomError.invalid("此中性点所需的 RGB Timing 超出 ±512 CV，请选择其他位置。")
      }
      solved.append(Int(rounded))
    }

    var result = adjustments
    result.timing.red = solved[0]
    result.timing.green = solved[1]
    result.timing.blue = solved[2]
    return result
  }
}
