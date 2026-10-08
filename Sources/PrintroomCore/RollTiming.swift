import Foundation
import simd

/// Analysis only: no changes to the rendering pipeline or stored parameter format.
public enum RollTiming {
  public struct Frame: Sendable {
    public let densityCV: [SIMD3<Float>]
    public let lut: CubeLUT
    public init(densityCV: [SIMD3<Float>], lut: CubeLUT) {
      self.densityCV = densityCV; self.lut = lut
    }
  }

  /// Deterministic stratified samples, equally resampled after rejecting clipped input.
  public static func samples(_ image: PixelBuffer, calibration: FilmCalibration) throws -> [SIMD3<Float>] {
    guard image.width > 0, image.height > 0,
      image.width <= Int.max / image.height,
      image.pixels.count == image.width * image.height else {
      throw PrintroomError.invalid("整卷调色图像尺寸无效。")
    }
    try Task.checkCancellation()
    var valid: [SIMD4<Float>] = []
    for y in 0..<64 { for x in 0..<64 {
      let px = min(image.width - 1, (2 * x + 1) * image.width / 128)
      let py = min(image.height - 1, (2 * y + 1) * image.height / 128)
      let p = image.pixels[py * image.width + px]
      if (0..<3).allSatisfy({ p[$0].isFinite && p[$0] > 0 && p[$0] < 1 }) { valid.append(p) }
    } }
    guard valid.count >= 64 else { throw PrintroomError.invalid("照片有效样本不足，无法进行整卷自动调色。") }
    let points = (0..<1024).map { valid[min(valid.count - 1, (2 * $0 + 1) * valid.count / 2048)] }
    let input = PixelBuffer(width: points.count, height: 1, pixels: points)
    return try Pipeline.render(input, calibration: calibration, adjustments: .init(), stage: .d3)
      .pixels.map { SIMD3($0.x, $0.y, $0.z) * 1024 }
  }

  /// Optional second pass, after the shared RGB solution. Never subtract exposure.
  public static func automaticMaster(densityCV: [SIMD3<Float>], timing: TimingParameters) throws -> Int {
    try Task.checkCancellation()
    guard !densityCV.isEmpty, densityCV.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else {
      throw PrintroomError.invalid("自动曝光样本无效。")
    }
    let shift = (Double(timing.red) + Double(timing.green) + Double(timing.blue)) / 3
    let values = densityCV.map { (Double($0.x) + Double($0.y) + Double($0.z)) / 3 + shift }.sorted()
    let p95 = values[Int(ceil(Double(values.count) * 0.95)) - 1]
    return Int(min(512, max(0, (685 - p95).rounded())))
  }

  public static func solve(_ frames: [Frame], profile: Data) throws -> TimingParameters {
    try Task.checkCancellation()
    guard let count = frames.first?.densityCV.count, count > 0,
      frames.allSatisfy({ $0.densityCV.count == count && $0.densityCV.allSatisfy {
        $0.x.isFinite && $0.y.isFinite && $0.z.isFinite
      } }) else { throw PrintroomError.invalid("整卷调色样本无效。") }
    let values = frames.flatMap { $0.densityCV.map { Double(($0.x + $0.y + $0.z) / 3) } }.sorted()
    let exposure = 685 - values[Int(ceil(Double(values.count) * 0.95)) - 1]
    guard (-512...512).contains(exposure) else {
      throw PrintroomError.invalid("整卷曝光所需调整超出 ±512 CV，未修改照片。")
    }
    let color = try FinalColorimetry(p3Profile: profile)
    // Fixed weights from exposure-only output prevent a candidate from hiding
    // inconvenient colours by pushing them into black or clipping.
    let weights = frames.map { frame in frame.densityCV.map { p -> Double in
      let rgb = frame.lut.sample((p + SIMD3(repeating: Float(exposure))) / 1024)
      let y = color.linearRGB(SIMD3(Double(rgb.x), Double(rgb.y), Double(rgb.z)))
      let level = (y.x + y.y + y.z) / 3
      return 0.05 + 0.95 * min(1, max(0, level / 0.02)) * min(1, max(0, (1 - level) / 0.15))
    } }
    func score(_ t: SIMD3<Double>) throws -> Double {
      guard (0..<3).allSatisfy({ (-512...512).contains(t[$0]) }) else { return .infinity }
      var means: [SIMD3<Double>] = []
      for (i, frame) in frames.enumerated() {
        try Task.checkCancellation()
        var sum = SIMD3<Double>(repeating: 0), total = 0.0
        for (j, p) in frame.densityCV.enumerated() {
          let rgb = frame.lut.sample((p + SIMD3(Float(t.x), Float(t.y), Float(t.z))) / 1024)
          let linear = color.linearRGB(SIMD3(Double(rgb.x), Double(rgb.y), Double(rgb.z)))
          sum += linear * weights[i][j]; total += weights[i][j]
        }
        means.append(sum / total)
      }
      var mean = SIMD3<Double>(repeating: 0)
      let trim = means.count / 10
      for c in 0..<3 {
        let sorted = means.map { $0[c] }.sorted()
        let kept = sorted[trim..<(sorted.count - trim)]
        mean[c] = kept.reduce(0, +) / Double(kept.count)
      }
      let level = (mean.x + mean.y + mean.z) / 3
      guard level > 1e-8 else { return .infinity }
      // Compare chromaticity at a common brightness, not a smaller C* caused by darkening.
      let lab = color.labFromLinear(mean * (0.18 / level))
      return lab.y * lab.y + lab.z * lab.z
    }
    var best = SIMD3<Double>(repeating: exposure)
    var error = try score(best)
    // Search the zero-sum plane; the P95 anchor remains unchanged.
    let directions: [SIMD3<Double>] = [SIMD3(1,-1,0), SIMD3(1,0,-1), SIMD3(0,1,-1)]
    for step in [64.0, 32, 16, 8, 4, 2, 1, 0.5, 0.25] {
      for _ in 0..<12 {
        var next = best, nextError = error
        for d in directions { for sign in [-1.0, 1.0] {
          let candidate = best + d * step * sign
          let e = try score(candidate)
          if e < nextError - 1e-10 { next = candidate; nextError = e }
        } }
        if next == best { break }
        best = next; error = nextError
      }
    }
    let total = Int((3 * exposure).rounded())
    var saved: SIMD3<Int>?, savedError = Double.infinity
    for r in (Int(best.x.rounded()) - 2)...(Int(best.x.rounded()) + 2) {
      for g in (Int(best.y.rounded()) - 2)...(Int(best.y.rounded()) + 2) {
        let b = total - r - g
        let candidate = SIMD3(Double(r), Double(g), Double(b))
        let e = try score(candidate)
        if e < savedError { saved = SIMD3(r,g,b); savedError = e }
      }
    }
    guard let saved else { throw PrintroomError.invalid("无法在 Timing 范围内完成整卷调色。") }
    return TimingParameters(red: saved.x, green: saved.y, blue: saved.z)
  }
}
