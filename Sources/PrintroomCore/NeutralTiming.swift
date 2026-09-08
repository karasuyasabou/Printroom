import Foundation
import simd

/// Fits existing RGB Timing controls to a neutral Final sample. The image
/// pipeline, Master, Contrast, calibration and project format remain unchanged.
public enum NeutralTiming {
  /// Final's per-channel medians define a representative colour. Its ICC-decoded
  /// luminance determines the neutral target. Bounded, damped least squares works
  /// in D3 CV offsets, then nearby integer Timing values are checked through the
  /// actual Float32 pipeline. Unreachable or insufficiently precise fits throw.
  ///
  /// Success requires C*ab <= 1 and |delta L*| <= 0.5, relative to the working
  /// ICC's matrix white. An already neutral sample is unchanged (idempotence).
  /// Only original, unclipped samples are usable; a strict majority must remain.
  public static func solve(
    _ samples: PixelBuffer, calibration: FilmCalibration, adjustments: FrameAdjustments,
    lut: CubeLUT, p3Profile: Data
  ) throws -> FrameAdjustments {
    try Task.checkCancellation()
    try Pipeline.validate(adjustments)
    let (count, overflow) = samples.width.multipliedReportingOverflow(by: samples.height)
    guard samples.width > 0, samples.height > 0, !overflow, count <= 121,
      count == samples.pixels.count
    else { throw PrintroomError.invalid("中性点取样尺寸无效，最多支持 11×11 个原始像素。") }

    var usable: [SIMD4<Float>] = []
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
    guard lut.values.allSatisfy({ (0...1).contains($0.x) && (0...1).contains($0.y)
      && (0...1).contains($0.z) }) else {
      throw PrintroomError.invalid("Final 中性点需要输出范围为 0…1 的 LUT。")
    }
    let color = try FinalColorimetry(p3Profile: p3Profile)
    let input = PixelBuffer(width: usable.count, height: 1, pixels: usable)
    let processed = try Pipeline.render(input, calibration: calibration,
      adjustments: adjustments, stage: .d3)
    let d3 = processed.pixels.map { SIMD3($0.x, $0.y, $0.z) }
    let initialRGB = representative(d3.map { lut.sample($0) })
    let initialLab = color.lab(initialRGB)
    if hypot(initialLab.y, initialLab.z) <= 1 { return adjustments }
    let targetRGB = color.neutralMatchingLuminance(initialRGB)
    let targetLab = color.lab(targetRGB)
    let timing = adjustments.timing, contrast = adjustments.contrast
    let old = SIMD3(Double(timing.red), Double(timing.green), Double(timing.blue))
    let effective = SIMD3(Double(contrast.master * contrast.red),
      Double(contrast.master * contrast.green), Double(contrast.master * contrast.blue))
    let problem = Problem(d3: d3, lut: lut, color: color, target: targetLab,
      lower: (SIMD3(repeating: -512) - old) * effective,
      upper: (SIMD3(repeating: 512) - old) * effective)

    // Multiple deterministic starts reach sloped LUT regions even when the
    // original colour lies on a clipped plateau. A knot is a seed, not an inverse.
    let medianD3 = representative(d3) * 1024
    var nearestIndex = 0, nearestDistance = Double.infinity
    for (index, v) in lut.values.enumerated() {
      if index % 1024 == 0 { try Task.checkCancellation() }
      let delta = SIMD3(Double(v.x), Double(v.y), Double(v.z)) - targetRGB
      let distance = simd_length_squared(delta)
      if distance < nearestDistance { nearestDistance = distance; nearestIndex = index }
    }
    let n = lut.size
    let knot = SIMD3(Double(nearestIndex % n), Double(nearestIndex / n % n),
      Double(nearestIndex / (n * n))) * (1024 / Double(n - 1))
    let neutralD3 = SIMD3<Double>(repeating: (medianD3.x + medianD3.y + medianD3.z) / 3)
    let seeds = [knot - medianD3, SIMD3<Double>(repeating: 0), neutralD3 - medianD3]
    var solutions: [SIMD3<Double>] = []
    for seed in seeds {
      let solution = try problem.fit(from: seed)
      solutions.append(solution.offset)
      if solution.error < 1e-8 { break }
    }

    // Check exact saved integer controls, including Float32 rounding and clipping.
    var best: FrameAdjustments?
    var bestError = Double.infinity
    var bestMove = Double.infinity
    var seen: Set<SIMD3<Int>> = []
    for offset in solutions {
      let requested = old + offset / effective
      let center = SIMD3(Int(requested.x.rounded()), Int(requested.y.rounded()),
        Int(requested.z.rounded()))
      for r in -2...2 { for g in -2...2 { for b in -2...2 {
        try Task.checkCancellation()
        let candidate = SIMD3(center.x + r, center.y + g, center.z + b)
        guard (0..<3).allSatisfy({ TimingParameters.range.contains(candidate[$0]) }),
          seen.insert(candidate).inserted else { continue }
        var result = adjustments
        result.timing.red = candidate.x
        result.timing.green = candidate.y
        result.timing.blue = candidate.z
        let output = try Pipeline.render(input, calibration: calibration,
          adjustments: result, lut: lut, stage: .final)
        let rgb = representative(output.pixels.map { SIMD3($0.x, $0.y, $0.z) })
        let lab = color.lab(rgb)
        guard hypot(lab.y, lab.z) <= 1, abs(lab.x - initialLab.x) <= 0.5 else { continue }
        let error = simd_length_squared(lab - targetLab)
        let move = simd_length_squared(SIMD3(Double(candidate.x), Double(candidate.y),
          Double(candidate.z)) - old)
        if error < bestError - 1e-12 || (abs(error - bestError) <= 1e-12 && move < bestMove) {
          best = result; bestError = error; bestMove = move
        }
      } } }
    }
    guard let best else {
      throw PrintroomError.invalid(
        "此位置无法在保持亮度的同时达到 Final 中性：可能已剪切，或所需调整超出 ±512 CV／整数精度。请选择其他灰白区域。")
    }
    return best
  }

  private static func representative(_ pixels: [SIMD3<Float>]) -> SIMD3<Double> {
    var result = SIMD3<Double>(repeating: 0)
    for c in 0..<3 {
      let values = pixels.map { Double($0[c]) }.sorted()
      let middle = values.count / 2
      result[c] = values.count.isMultiple(of: 2)
        ? (values[middle - 1] + values[middle]) / 2 : values[middle]
    }
    return result
  }

  private struct Evaluation {
    let offset: SIMD3<Double>
    let residual: SIMD3<Double>
    var error: Double { simd_length_squared(residual) }
  }

  private struct Problem {
    let d3: [SIMD3<Float>]
    let lut: CubeLUT
    let color: FinalColorimetry
    let target: SIMD3<Double>
    let lower: SIMD3<Double>
    let upper: SIMD3<Double>

    func bounded(_ offset: SIMD3<Double>) -> SIMD3<Double> {
      simd_clamp(offset, lower, upper)
    }

    func evaluate(_ offset: SIMD3<Double>) throws -> Evaluation {
      try Task.checkCancellation()
      let shift = SIMD3(Float(offset.x / 1024), Float(offset.y / 1024), Float(offset.z / 1024))
      let rgb = representative(d3.map { lut.sample($0 + shift) })
      return Evaluation(offset: offset, residual: color.lab(rgb) - target)
    }

    func fit(from seed: SIMD3<Double>) throws -> Evaluation {
      var current = try evaluate(bounded(seed))
      var damping = 0.01
      for _ in 0..<48 {
        if current.error < 1e-8 { break }
        var jacobian = simd_double3x3()
        for c in 0..<3 {
          var a = current.offset, b = current.offset
          a[c] = max(lower[c], a[c] - 0.5)
          b[c] = min(upper[c], b[c] + 0.5)
          jacobian[c] = (try evaluate(b).residual - evaluate(a).residual) / (b[c] - a[c])
        }
        let normal = jacobian.transpose * jacobian
        let gradient = jacobian.transpose * current.residual
        var improved = false
        for _ in 0..<8 {
          var damped = normal
          for c in 0..<3 { damped[c][c] += damping * max(normal[c][c], 1e-6) }
          var step = -(damped.inverse * gradient)
          guard (0..<3).allSatisfy({ step[$0].isFinite }) else { break }
          let largest = max(abs(step.x), abs(step.y), abs(step.z))
          if largest > 128 { step *= 128 / largest }
          let next = try evaluate(bounded(current.offset + step))
          if next.error < current.error - 1e-12 {
            current = next; damping = max(1e-7, damping / 3); improved = true; break
          }
          damping *= 10
        }
        if !improved { break }
      }
      return current
    }
  }
}
