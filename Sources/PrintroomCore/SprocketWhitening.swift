import Foundation

/// Roll-level, independently versioned output treatment. Density and LUT stay unchanged.
public struct SprocketWhiteningSettings: Codable, Equatable, Sendable {
  public static let version = "sprocket-whitening-v1"
  public var version = Self.version
  public var enabled = false
  /// Every calibrated linear channel must exceed film base by this percentage.
  public var thresholdPercent: Double = 25
  public init(enabled: Bool = false, thresholdPercent: Double = 25) {
    self.enabled = enabled
    self.thresholdPercent = thresholdPercent
  }
  public func validate() throws {
    guard version == Self.version, thresholdPercent.isFinite,
      (5...200).contains(thresholdPercent) else {
      throw PrintroomError.invalid("齿孔识别版本或阈值无效。")
    }
  }
}

/// Maps full-frame preview/export pixel centers into the protected crop's unit rectangle.
/// Row offsets belong to the full export, never to the current TIFF/JPEG strip.
public struct SprocketWhiteningContext: Sendable {
  let mapX, mapY: SIMD4<Float>
  let enabled: Bool
  let threshold: Float
  let inputWidth: Int
  let remainingRows: Int
  static let transition: Float = 0.05
  // Conservative Float32 guard includes crop edges; it never expands whitening into the crop.
  static let protectionMargin: Float = 0.000004

  public init(settings: SprocketWhiteningSettings, protectedCrop: FrameCrop,
    sourceWidth: Int, sourceHeight: Int, orientation: FrameOrientation = .identity,
    renderWidth: Int, renderHeight: Int, rowOffset: Int = 0) throws {
    try settings.validate()
    guard renderWidth > 0, renderHeight > 0, rowOffset >= 0, rowOffset < renderHeight else {
      throw PrintroomError.invalid("齿孔蒙版尺寸无效。")
    }
    let canonical = try protectedCrop.sourceCoordinates(sourceWidth: sourceWidth,
      sourceHeight: sourceHeight, orientation: orientation)
    let protected = try CropGeometry(crop: canonical, sourceWidth: sourceWidth, sourceHeight: sourceHeight)
    let full = try CropGeometry(crop: nil, sourceWidth: sourceWidth,
      sourceHeight: sourceHeight, orientation: orientation)
    func position(_ x: Double, _ y: Double) -> SIMD2<Double> {
      let source = full.sourcePoint(
        outputX: (x + 0.5) * Double(full.outputWidth) / Double(renderWidth),
        outputY: (y + Double(rowOffset) + 0.5) * Double(full.outputHeight) / Double(renderHeight))
      let point = protected.outputPoint(sourceX: source.x, sourceY: source.y)
      return point / SIMD2(Double(protected.outputWidth), Double(protected.outputHeight))
    }
    let origin = position(0, 0), dx = position(1, 0) - origin, dy = position(0, 1) - origin
    mapX = SIMD4(Float(dx.x), Float(dy.x), Float(origin.x), 0)
    mapY = SIMD4(Float(dx.y), Float(dy.y), Float(origin.y), 0)
    enabled = settings.enabled
    threshold = 1 + Float(settings.thresholdPercent / 100)
    inputWidth = renderWidth
    remainingRows = renderHeight - rowOffset
  }

  func validate(_ input: PixelBuffer) throws {
    guard input.width == inputWidth, input.height > 0, input.height <= remainingRows,
      input.width <= Int.max / input.height, input.pixels.count == input.width * input.height else {
      throw PrintroomError.invalid("齿孔蒙版与输入尺寸不匹配。")
    }
  }

  /// Independent CPU reference; Metal implements these decisions in its own kernel.
  public func opacity(rawRGB: SIMD3<Float>, x: Int, y: Int, calibration: FilmCalibration) -> Float {
    guard enabled, calibration.isCalibrated else { return 0 }
    let p = SIMD4(Float(x), Float(y), 1, 0)
    let cx = mapX.x * p.x + mapX.y * p.y + mapX.z
    let cy = mapY.x * p.x + mapY.y * p.y + mapY.z
    let margin = Self.protectionMargin
    if cx >= -margin, cx <= 1 + margin, cy >= -margin, cy <= 1 + margin { return 0 }
    let corrected = calibration.cmosMatrix.coefficients.apply(rawRGB) * calibration.gainRGB / 0.75
    let brightness = min(corrected.x, min(corrected.y, corrected.z))
    let t = min(1, max(0, (brightness - threshold) / Self.transition))
    return t * t * (3 - 2 * t)
  }

  /// Can composite either native Final or converted output RGB; pure white is (1,1,1) in both.
  public func apply(raw input: PixelBuffer, to output: PixelBuffer,
    calibration: FilmCalibration, onlyOpaque: Bool = false) throws -> PixelBuffer {
    try validate(input)
    guard output.width == input.width, output.height == input.height,
      output.pixels.count == input.pixels.count else {
      throw PrintroomError.invalid("齿孔合成与输出尺寸不匹配。")
    }
    guard enabled, calibration.isCalibrated else { return output }
    var result = output
    for i in result.pixels.indices {
      if i % 16384 == 0 { try Task.checkCancellation() }
      let raw = input.pixels[i]
      let amount = opacity(rawRGB: SIMD3(raw.x, raw.y, raw.z), x: i % input.width,
        y: i / input.width, calibration: calibration)
      if amount == 0 || (onlyOpaque && amount < 1) { continue }
      let value = result.pixels[i]
      result.pixels[i] = amount == 1 ? SIMD4(repeating: 1)
        : SIMD4(value.x + (1 - value.x) * amount, value.y + (1 - value.y) * amount,
          value.z + (1 - value.z) * amount, 1)
    }
    return result
  }
}
