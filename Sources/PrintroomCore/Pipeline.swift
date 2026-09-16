import Foundation

/// A unit-domain 3D LUT. Red varies fastest: r + size*g + size*size*b.
/// RGB values are already output encoded; the fourth component is padding.
public struct CubeLUT: Sendable {
  public let size: Int
  public let values: [SIMD4<Float>]
  public init(size: Int, values: [SIMD4<Float>]) throws {
    let expectedCount = try Self.entryCount(size: size)
    guard values.count == expectedCount else {
      throw PrintroomError.invalid("LUT 格点数应为 \(expectedCount)，实际为 \(values.count)。")
    }
    guard values.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite })
    else {
      throw PrintroomError.invalid("LUT 包含非有限值。")
    }
    self.size = size
    self.values = values
  }

  /// Supports one 3D table, comments, TITLE, and optional unit DOMAIN bounds.
  /// Other domains and 1D/shaper tables are rejected rather than reinterpreted.
  public init(url: URL) throws {
    var source = try String(contentsOf: url, encoding: .utf8)
    if source.first == "\u{FEFF}" { source.removeFirst() }
    var size: Int?
    var expectedCount: Int?
    var values: [SIMD4<Float>] = []
    var seenHeaders: Set<String> = []

    for (lineIndex, rawLine) in source.components(separatedBy: .newlines).enumerated() {
      let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
        .trimmingCharacters(in: .whitespaces)
      if line.isEmpty { continue }
      let tokens = line.split(whereSeparator: { $0.isWhitespace })
      let key = String(tokens[0])
      func invalid(_ detail: String) -> PrintroomError {
        .invalid("LUT 第 \(lineIndex + 1) 行：\(detail)")
      }

      switch key {
      case "TITLE", "LUT_3D_SIZE", "DOMAIN_MIN", "DOMAIN_MAX":
        guard values.isEmpty, seenHeaders.insert(key).inserted else {
          throw invalid("表头重复或出现在格点数据之后。")
        }
        switch key {
        case "TITLE":
          guard tokens.count >= 2 else { throw invalid("TITLE 缺少内容。") }
        case "LUT_3D_SIZE":
          guard tokens.count == 2, let parsedSize = Int(tokens[1]) else {
            throw invalid("LUT_3D_SIZE 必须是整数。")
          }
          expectedCount = try Self.entryCount(size: parsedSize)
          size = parsedSize
        default:
          guard tokens.count == 4 else { throw invalid("DOMAIN 必须包含三个数值。") }
          let expected: Float = key == "DOMAIN_MIN" ? 0 : 1
          guard tokens.dropFirst().allSatisfy({ Float($0) == expected }) else {
            throw invalid("本算法只支持 DOMAIN_MIN 0 0 0 和 DOMAIN_MAX 1 1 1。")
          }
        }
      default:
        guard let expectedCount else { throw invalid("缺少 LUT_3D_SIZE 或存在不支持的表头。") }
        guard tokens.count == 3,
          let r = Float(tokens[0]), let g = Float(tokens[1]), let b = Float(tokens[2]),
          r.isFinite, g.isFinite, b.isFinite
        else {
          throw invalid("格点必须包含三个有限浮点数；不支持 1D LUT 或附加表头。")
        }
        guard values.count < expectedCount else { throw invalid("格点数量超过 LUT_3D_SIZE。") }
        values.append(SIMD4(r, g, b, 1))
      }
    }
    guard let size else { throw PrintroomError.invalid("LUT 缺少 LUT_3D_SIZE。") }
    try self.init(size: size, values: values)
  }

  /// Clamps finite input only at the LUT boundary. Invalid input returns NaN;
  /// Pipeline checks and throws before sampling, so invalid values never reach indexing.
  public func sample(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
    guard rgb.x.isFinite, rgb.y.isFinite, rgb.z.isFinite else {
      return SIMD3(repeating: .nan)
    }
    let position =
      SIMD3(
        min(max(rgb.x, 0), 1), min(max(rgb.y, 0), 1), min(max(rgb.z, 0), 1)
      ) * Float(size - 1)
    let r0 = min(Int(position.x), size - 1)
    let g0 = min(Int(position.y), size - 1)
    let b0 = min(Int(position.z), size - 1)
    let r1 = min(r0 + 1, size - 1)
    let g1 = min(g0 + 1, size - 1)
    let b1 = min(b0 + 1, size - 1)
    let fraction = position - SIMD3(Float(r0), Float(g0), Float(b0))
    func value(_ r: Int, _ g: Int, _ b: Int) -> SIMD3<Float> {
      let v = values[r + size * g + size * size * b]
      return SIMD3(v.x, v.y, v.z)
    }
    func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
      a * (1 - t) + b * t
    }
    let c00 = mix(value(r0, g0, b0), value(r1, g0, b0), fraction.x)
    let c10 = mix(value(r0, g1, b0), value(r1, g1, b0), fraction.x)
    let c01 = mix(value(r0, g0, b1), value(r1, g0, b1), fraction.x)
    let c11 = mix(value(r0, g1, b1), value(r1, g1, b1), fraction.x)
    return mix(mix(c00, c10, fraction.y), mix(c01, c11, fraction.y), fraction.z)
  }

  private static func entryCount(size: Int) throws -> Int {
    let (square, squareOverflow) = size.multipliedReportingOverflow(by: size)
    let (cube, cubeOverflow) = square.multipliedReportingOverflow(by: size)
    guard size >= 2, !squareOverflow, !cubeOverflow else {
      throw PrintroomError.invalid("LUT_3D_SIZE 至少为 2，且格点数量不能溢出。")
    }
    return cube
  }
}

/// Fractions count RGB pixels, not individual channels. A pixel is counted once
/// per category when any channel is 0 or 65535; the two categories may overlap.
public struct CalibrationDiagnostics: Equatable, Sendable {
  public let pixelCount: Int
  public let zeroPixelCount: Int
  public let saturatedPixelCount: Int
  public var zeroFraction: Double { Double(zeroPixelCount) / Double(pixelCount) }
  public var saturatedFraction: Double { Double(saturatedPixelCount) / Double(pixelCount) }
}

/// Float32 reference implementation of printroom-density-v6; no ICC or gamma transforms.
public enum Pipeline {
  private static let cvScale: Float = 1024
  private static let densityScale: Float = 2.048
  private static let epsilon: Float = 1e-6
  private static let baseTarget: Float = 0.75
  private static let baseTargetCV: Float = 95
  private static let pivot: Float = Float(contrastPivotCV) / 1024

  public static func matrix(_ rgb: SIMD3<Float>, _ matrix: PrintDensityMatrix) -> SIMD3<Float> {
    matrix.coefficients.apply(rgb)
  }

  public static func calibrate(
    image: LinearImage, rect: PixelRect, matrix: PrintDensityMatrix, sourceFrameID: UUID?,
    cmosMatrix: MatrixPreset = .identity
  ) throws -> FilmCalibration {
    let count = try checkedSelectionPixelCount(image: image, rect: rect)
    guard count >= 16 else { throw PrintroomError.invalid("片基选区至少需要 16 个有效 RGB 像素。") }
    var red: [Float] = []
    var green: [Float] = []
    var blue: [Float] = []
    red.reserveCapacity(count)
    green.reserveCapacity(count)
    blue.reserveCapacity(count)
    // LinearImage is orientation-corrected, interleaved UInt16, so all pixels are finite.
    // Keep finite zero/saturated samples in the median; do not sample the preview.
    for y in rect.y..<(rect.y + rect.height) {
      for x in rect.x..<(rect.x + rect.width) {
        let rgb = try checked(cmosMatrix.coefficients.apply(image.pixel(x: x, y: y)), stage: .l1)
        red.append(rgb.x)
        green.append(rgb.y)
        blue.append(rgb.z)
      }
    }
    func median(_ values: inout [Float]) -> Float {
      values.sort()
      let middle = values.count / 2
      return values.count.isMultiple(of: 2)
        ? (values[middle - 1] + values[middle]) / 2 : values[middle]
    }
    let base = SIMD3(median(&red), median(&green), median(&blue))
    guard base.x > 0, base.y > 0, base.z > 0 else {
      throw PrintroomError.invalid("片基任一通道的中位数不能为零或负数。")
    }
    var calibration = FilmCalibration()
    calibration.matrix = matrix
    calibration.cmosMatrix = cmosMatrix
    calibration.sampledCMOSMatrix = cmosMatrix
    calibration.baseRGB = base
    calibration.gainRGB = SIMD3(repeating: baseTarget) / base
    calibration.sourceFrameID = sourceFrameID
    calibration.selection = rect
    calibration.sourceWidth = image.width
    calibration.sourceHeight = image.height
    return try recalibrate(calibration, matrix: matrix)
  }

  /// Reads original UInt16 samples without excluding finite extreme values.
  /// Small valid selections can be inspected even when calibration's 16-pixel minimum fails.
  public static func calibrationDiagnostics(image: LinearImage, rect: PixelRect) throws
    -> CalibrationDiagnostics
  {
    let count = try checkedSelectionPixelCount(image: image, rect: rect)
    var zeroCount = 0
    var saturatedCount = 0
    for y in rect.y..<(rect.y + rect.height) {
      for x in rect.x..<(rect.x + rect.width) {
        let index = (y * image.width + x) * 3
        let r = image.samples[index]
        let g = image.samples[index + 1]
        let b = image.samples[index + 2]
        if r == 0 || g == 0 || b == 0 { zeroCount += 1 }
        if r == 65535 || g == 65535 || b == 65535 { saturatedCount += 1 }
      }
    }
    return CalibrationDiagnostics(
      pixelCount: count, zeroPixelCount: zeroCount, saturatedPixelCount: saturatedCount)
  }

  public static func recalibrate(
    _ calibration: FilmCalibration, matrix: PrintDensityMatrix
  ) throws -> FilmCalibration {
    var result = calibration
    result.matrix = matrix
    result.sampledDensityMatrix = matrix
    guard let base = calibration.baseRGB else {
      result.gainRGB = SIMD3(repeating: 1)
      result.filmBaseOffsetCV = SIMD3(repeating: 0)
      return result
    }
    try requirePositive(base, label: "片基")
    try requirePositive(calibration.gainRGB, label: "Linear Gain")
    let baseL1 = try checked(base * calibration.gainRGB, stage: .l2)
    let baseD1 = try checked(Self.matrix(normalizedDensity(baseL1), matrix), stage: .d1)
    result.filmBaseOffsetCV = SIMD3(repeating: baseTargetCV) - cvScale * baseD1
    guard isFinite(result.filmBaseOffsetCV) else {
      throw PrintroomError.invalid("片基偏移计算产生非有限值。")
    }
    return result
  }

  public static func process(
    _ rgb: SIMD3<Float>, calibration: FilmCalibration, adjustments: FrameAdjustments,
    lut: CubeLUT? = nil, stage: PipelineStage = .final
  ) throws -> SIMD3<Float> {
    try Prepared(calibration: calibration, adjustments: adjustments).process(
      rgb, lut: lut, stage: stage)
  }

  public static func render(
    _ input: PixelBuffer, calibration: FilmCalibration, adjustments: FrameAdjustments,
    lut: CubeLUT? = nil, stage: PipelineStage = .final
  ) throws -> PixelBuffer {
    let count = try checkedPixelCount(width: input.width, height: input.height)
    guard input.pixels.count == count else {
      throw PrintroomError.invalid("像素缓冲区尺寸与像素数量不匹配。")
    }
    let prepared = try Prepared(calibration: calibration, adjustments: adjustments)
    var pixels: [SIMD4<Float>] = []
    pixels.reserveCapacity(count)
    for pixel in input.pixels {
      let rgb = try prepared.process(SIMD3(pixel.x, pixel.y, pixel.z), lut: lut, stage: stage)
      pixels.append(SIMD4(rgb, 1))
    }
    return PixelBuffer(width: input.width, height: input.height, pixels: pixels)
  }

  public static func validate(_ adjustments: FrameAdjustments) throws {
    let timing = adjustments.timing
    guard
      [timing.master, timing.red, timing.green, timing.blue].allSatisfy({
        TimingParameters.range.contains($0)
      })
    else {
      throw PrintroomError.invalid("每个 Timing 控件必须为 -512…512 CV 的整数。")
    }
    let contrast = adjustments.contrast
    guard
      [contrast.master, contrast.red, contrast.green, contrast.blue].allSatisfy({
        $0.isFinite && (0.25...4).contains($0)
      })
    else {
      throw PrintroomError.invalid("每个 Contrast 控件必须为 0.25…4.0 的有限数值。")
    }
  }

  private struct Prepared {
    let gain: SIMD3<Float>
    let densityMatrix: PrintDensityMatrix
    let cmosMatrix: RGBMatrix
    let offsetNormalizedDensity: SIMD3<Float>
    let contrast: SIMD3<Float>

    init(calibration: FilmCalibration, adjustments: FrameAdjustments) throws {
      try validate(adjustments)
      try requirePositive(calibration.gainRGB, label: "Linear Gain")
      if let base = calibration.baseRGB { try requirePositive(base, label: "片基") }
      guard isFinite(calibration.filmBaseOffsetCV) else {
        throw PrintroomError.invalid("片基偏移必须是有限 CV 数值。")
      }
      gain = calibration.gainRGB
      densityMatrix = calibration.matrix
      cmosMatrix = calibration.cmosMatrix.coefficients
      let timing = adjustments.timing
      let effectiveCV =
        calibration.filmBaseOffsetCV + SIMD3(repeating: Float(timing.master))
        + SIMD3(Float(timing.red), Float(timing.green), Float(timing.blue))
      offsetNormalizedDensity = effectiveCV / cvScale
      let c = adjustments.contrast
      contrast = SIMD3(c.red, c.green, c.blue) * c.master
    }

    func process(_ rgb: SIMD3<Float>, lut: CubeLUT?, stage: PipelineStage) throws -> SIMD3<Float> {
      let l0 = try checked(rgb, stage: .l0)
      if stage == .l0 { return l0 }
      let l1 = try checked(cmosMatrix.apply(l0), stage: .l1)
      if stage == .l1 { return l1 }
      let l2 = try checked(l1 * gain, stage: .l2)
      if stage == .l2 { return l2 }
      let d0 = try checked(normalizedDensity(l2), stage: .d0)
      if stage == .d0 { return d0 }
      let d1 = try checked(matrix(d0, densityMatrix), stage: .d1)
      if stage == .d1 { return d1 }
      let d2 = try checked(d1 + offsetNormalizedDensity, stage: .d2)
      if stage == .d2 { return d2 }
      let d3 = try checked(
        SIMD3(repeating: pivot) + contrast * (d2 - SIMD3(repeating: pivot)), stage: .d3)
      if stage == .d3 { return d3 }
      guard let lut else { throw PrintroomError.invalid("Final 阶段需要 Cineon Log LUT。") }
      return try checked(lut.sample(d3), stage: .final)
    }
  }

  private static func normalizedDensity(_ linear: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3(
      -log10(max(linear.x, epsilon)), -log10(max(linear.y, epsilon)), -log10(max(linear.z, epsilon))
    ) / densityScale
  }

  private static func checkedPixelCount(width: Int, height: Int) throws -> Int {
    let (count, overflow) = width.multipliedReportingOverflow(by: height)
    guard width > 0, height > 0, !overflow else {
      throw PrintroomError.invalid("图像尺寸必须为正整数且不能溢出。")
    }
    return count
  }

  private static func checkedSelectionPixelCount(image: LinearImage, rect: PixelRect) throws -> Int
  {
    let pixelCount = try checkedPixelCount(width: image.width, height: image.height)
    let (sampleCount, overflow) = pixelCount.multipliedReportingOverflow(by: 3)
    guard !overflow, image.samples.count == sampleCount else {
      throw PrintroomError.invalid("原始 RGB 图像尺寸与样本数量不匹配。")
    }
    // Subtraction avoids overflow for hostile rectangles restored from a project.
    guard rect.x >= 0, rect.y >= 0, rect.width > 0, rect.height > 0,
      rect.x < image.width, rect.y < image.height,
      rect.width <= image.width - rect.x, rect.height <= image.height - rect.y
    else {
      throw PrintroomError.invalid("片基选区必须完全位于原始图像内。")
    }
    return rect.width * rect.height  // Bounded by the checked image dimensions.
  }

  private static func isFinite(_ rgb: SIMD3<Float>) -> Bool {
    rgb.x.isFinite && rgb.y.isFinite && rgb.z.isFinite
  }

  private static func checked(_ rgb: SIMD3<Float>, stage: PipelineStage) throws -> SIMD3<Float> {
    guard isFinite(rgb) else { throw PrintroomError.invalid("\(stage.label) 阶段包含非有限 RGB 数值。") }
    return rgb
  }

  private static func requirePositive(_ rgb: SIMD3<Float>, label: String) throws {
    guard isFinite(rgb), rgb.x > 0, rgb.y > 0, rgb.z > 0 else {
      throw PrintroomError.invalid("\(label) 各通道必须是有限正数。")
    }
  }
}
