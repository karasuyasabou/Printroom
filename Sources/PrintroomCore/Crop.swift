import Foundation
import CoreGraphics

public enum CropAspectRatio: String, CaseIterable, Codable, Sendable {
  case threeTwo = "3:2", fourThree = "4:3", square = "1:1", sevenSix = "7:6"
  public var label: String { rawValue }
  public var ratio: Double { Double(units.width) / Double(units.height) }
  public var units: (width: Int, height: Int) {
    switch self {
    case .threeTwo: (3, 2)
    case .fourThree: (4, 3)
    case .square: (1, 1)
    case .sevenSix: (7, 6)
    }
  }
}

/// Non-destructive geometry, independent of the density algorithm. Version 2 uses
/// the TIFF-normalized original image BEFORE user D4 orientation, so one crop can
/// be shared by frames with different directions. Positive angles rotate clockwise
/// in this source basis. Version 1 is retained for old projects and displayed drafts.
public struct FrameCrop: Codable, Equatable, Hashable, Sendable {
  public static let currentGeometryVersion = 2
  public var geometryVersion: Int
  public var aspect: CropAspectRatio
  public var portrait: Bool
  public var centerX: Double
  public var centerY: Double
  /// Width divided by full source width (v2), or oriented full width (legacy v1).
  public var width: Double
  public var angleDegrees: Double
  public var ratio: Double { portrait ? 1 / aspect.ratio : aspect.ratio }

  public init(
    aspect: CropAspectRatio = .threeTwo, portrait: Bool = false,
    centerX: Double = 0.5, centerY: Double = 0.5, width: Double = 1,
    angleDegrees: Double = 0, geometryVersion: Int = currentGeometryVersion
  ) {
    self.aspect = aspect
    self.portrait = portrait
    self.centerX = centerX
    self.centerY = centerY
    self.width = width
    self.angleDegrees = angleDegrees
    self.geometryVersion = geometryVersion
  }

  public func validate() throws {
    guard [1, Self.currentGeometryVersion].contains(geometryVersion),
      centerX.isFinite, centerY.isFinite, width.isFinite, angleDegrees.isFinite,
      (-1...2).contains(centerX), (-1...2).contains(centerY), width > 0, width <= 2,
      (-10...10).contains(angleDegrees)
    else { throw PrintroomError.invalid("裁剪版本、范围或角度无效。") }
  }

  public func constrained(
    sourceWidth: Int, sourceHeight: Int, orientation: FrameOrientation = .identity
  ) throws -> FrameCrop {
    try CropGeometry(crop: self, sourceWidth: sourceWidth, sourceHeight: sourceHeight,
                     orientation: geometryVersion == 2 ? .identity : orientation).crop!
  }

  /// Resolve an old displayed crop using its own frame direction before copying or
  /// persisting it. A version 2 crop already describes the same original region for
  /// every user direction; fitting it never depends on that direction.
  public func sourceCoordinates(
    sourceWidth: Int, sourceHeight: Int, orientation: FrameOrientation = .identity
  ) throws -> FrameCrop {
    try validate()
    if geometryVersion == 2 {
      return try constrained(sourceWidth: sourceWidth, sourceHeight: sourceHeight)
    }
    var source = try transformed(from: orientation, to: .identity,
                                 sourceWidth: sourceWidth, sourceHeight: sourceHeight)
    source.geometryVersion = 2
    return source
  }

  /// UI-only version 1 draft. Conjugation changes angle sign for reflections and
  /// exchanges ratio direction for quarter turns, while preserving the source crop.
  /// Convert back with sourceCoordinates before persisting or synchronizing it.
  public func displayCoordinates(
    sourceWidth: Int, sourceHeight: Int, orientation: FrameOrientation = .identity
  ) throws -> FrameCrop {
    try validate()
    if geometryVersion == 1 {
      return try constrained(sourceWidth: sourceWidth, sourceHeight: sourceHeight,
                              orientation: orientation)
    }
    var display = try constrained(sourceWidth: sourceWidth, sourceHeight: sourceHeight)
    display.geometryVersion = 1
    return try display.transformed(from: .identity, to: orientation,
                                    sourceWidth: sourceWidth, sourceHeight: sourceHeight)
  }

  /// Source-coordinate crops do not change when the frame direction changes.
  /// Legacy version 1 crops retain their compatibility transform until migrated.
  public func transformed(
    from old: FrameOrientation, to new: FrameOrientation, sourceWidth: Int, sourceHeight: Int
  ) throws -> FrameCrop {
    try validate()
    if geometryVersion == 2 { return self }
    let geometry = try CropGeometry(crop: self, sourceWidth: sourceWidth,
                                    sourceHeight: sourceHeight, orientation: old)
    let sourceCenter = old.inverseEdge(
      x: geometry.rect.midX, y: geometry.rect.midY,
      sourceWidth: Double(sourceWidth), sourceHeight: Double(sourceHeight))
    let center = new.forwardEdge(x: sourceCenter.x, y: sourceCenter.y,
                                sourceWidth: Double(sourceWidth), sourceHeight: Double(sourceHeight))
    let size = new.outputSize(sourceWidth: sourceWidth, sourceHeight: sourceHeight)
    var result = geometry.crop!
    if old.swapsAxes != new.swapsAxes { result.portrait.toggle() }
    result.centerX = center.x / Double(size.width)
    result.centerY = center.y / Double(size.height)
    result.width = (old.swapsAxes == new.swapsAxes ? geometry.rect.width : geometry.rect.height)
      / Double(size.width)
    if old.isReflection != new.isReflection { result.angleDegrees = -result.angleDegrees }
    return try result.constrained(sourceWidth: sourceWidth, sourceHeight: sourceHeight,
                                  orientation: new)
  }
}

/// One geometry implementation is shared by UI, preview, original ROI and export.
/// Mapping uses pixel-edge coordinates; the center of pixel (x,y) is (x+.5,y+.5).
public struct CropGeometry: Sendable {
  /// Fitted crop in the same version/basis as the caller supplied.
  public let crop: FrameCrop?
  /// Direction-adjusted version 1 draft used by the rectangle and canvas angle.
  public let displayCrop: FrameCrop?
  public let sourceWidth: Int
  public let sourceHeight: Int
  public let orientation: FrameOrientation
  public let orientedWidth: Int
  public let orientedHeight: Int
  public let outputWidth: Int
  public let outputHeight: Int
  public let rect: CGRect
  private let cosine: Double
  private let sine: Double

  public init(
    crop: FrameCrop?, sourceWidth: Int, sourceHeight: Int,
    orientation: FrameOrientation = .identity
  ) throws {
    guard sourceWidth > 0, sourceHeight > 0, sourceWidth <= Int.max / sourceHeight,
      sourceWidth * sourceHeight <= Int.max / 4
    else { throw PrintroomError.invalid("裁剪源图像尺寸无效。") }
    self.sourceWidth = sourceWidth
    self.sourceHeight = sourceHeight
    self.orientation = orientation
    let size = orientation.outputSize(sourceWidth: sourceWidth, sourceHeight: sourceHeight)
    orientedWidth = size.width
    orientedHeight = size.height
    let w = Double(size.width), h = Double(size.height)
    var requested = crop
    var fittedSource: FrameCrop?
    if let crop, crop.geometryVersion == 2 {
      // Fit in the original image basis. Re-expressing that geometry
      // in the display basis makes the existing pixel/ROI paths equivalent to
      // original crop + fine rotation, followed by the frame's lossless D4 edit.
      var legacySource = crop
      legacySource.geometryVersion = 1
      var canonical = try legacySource.constrained(sourceWidth: sourceWidth,
                                                    sourceHeight: sourceHeight)
      legacySource = canonical
      canonical.geometryVersion = 2
      fittedSource = canonical
      requested = try legacySource.transformed(from: .identity, to: orientation,
        sourceWidth: sourceWidth, sourceHeight: sourceHeight)
    }
    guard var fitted = requested else {
      self.crop = nil
      displayCrop = nil
      outputWidth = size.width
      outputHeight = size.height
      rect = CGRect(x: 0, y: 0, width: w, height: h)
      cosine = 1
      sine = 0
      return
    }
    try fitted.validate()
    fitted.angleDegrees = (fitted.angleDegrees * 100).rounded() / 100
    let radians = fitted.angleDegrees * .pi / 180
    let c = cos(radians), s = sin(radians)
    cosine = c
    sine = s
    let base = fitted.aspect.units
    let unitW = fitted.portrait ? base.height : base.width
    let unitH = fitted.portrait ? base.width : base.height
    // Exact integer ratios also make every zero-angle crop an integer copy.
    let maximum = min(w / (abs(c) * Double(unitW) + abs(s) * Double(unitH)),
                      h / (abs(s) * Double(unitW) + abs(c) * Double(unitH)))
    let maximumUnits = Int(floor(maximum + 1e-9))
    guard maximumUnits >= 1 else { throw PrintroomError.invalid("图像太小，无法容纳所选裁剪比例。") }
    let count = max(1, min(maximumUnits, Int(floor(fitted.width * w / Double(unitW) + 1e-9))))
    outputWidth = count * unitW
    outputHeight = count * unitH
    let cw = Double(outputWidth), ch = Double(outputHeight)
    let ex = (abs(c) * cw + abs(s) * ch) / 2
    let ey = (abs(s) * cw + abs(c) * ch) / 2
    let dx = fitted.centerX * w - w / 2
    let dy = fitted.centerY * h - h / 2
    // Move the inverse-rotated center within its valid box. Translation preserves
    // the chosen crop size; only a ratio/angle/size edit can require shrinking it.
    let sx = min(w - ex, max(ex, c * dx + s * dy + w / 2))
    let sy = min(h - ey, max(ey, -s * dx + c * dy + h / 2))
    var x = c * (sx - w / 2) - s * (sy - h / 2) + w / 2 - cw / 2
    var y = s * (sx - w / 2) + c * (sy - h / 2) + h / 2 - ch / 2
    if fitted.angleDegrees == 0 {
      x = min(w - cw, max(0, x.rounded()))
      y = min(h - ch, max(0, y.rounded()))
    }
    rect = CGRect(x: x, y: y, width: cw, height: ch)
    fitted.centerX = (x + cw / 2) / w
    fitted.centerY = (y + ch / 2) / h
    fitted.width = cw / w
    self.crop = fittedSource ?? fitted
    displayCrop = fitted
  }

  public func sourcePoint(outputX: Double, outputY: Double) -> SIMD2<Double> {
    let dx = outputX + rect.minX - Double(orientedWidth) / 2
    let dy = outputY + rect.minY - Double(orientedHeight) / 2
    return orientation.inverseEdge(
      x: cosine * dx + sine * dy + Double(orientedWidth) / 2,
      y: -sine * dx + cosine * dy + Double(orientedHeight) / 2,
      sourceWidth: Double(sourceWidth), sourceHeight: Double(sourceHeight))
  }

  public func outputPoint(sourceX: Double, sourceY: Double) -> SIMD2<Double> {
    let p = orientation.forwardEdge(x: sourceX, y: sourceY,
                                    sourceWidth: Double(sourceWidth), sourceHeight: Double(sourceHeight))
    let dx = p.x - Double(orientedWidth) / 2
    let dy = p.y - Double(orientedHeight) / 2
    return SIMD2(cosine * dx - sine * dy + Double(orientedWidth) / 2 - rect.minX,
                 sine * dx + cosine * dy + Double(orientedHeight) / 2 - rect.minY)
  }

  public func sourceRegion(for region: PixelRect) throws -> PixelRect {
    try validateOutputRegion(region)
    if sine == 0 {
      // No interpolation support is needed for an integer crop/D4 transform.
      // In particular, a region exactly at the native memory limit stays valid.
      return try orientation.inverseRect(
        PixelRect(x: region.x + Int(rect.minX), y: region.y + Int(rect.minY),
                  width: region.width, height: region.height),
        sourceWidth: sourceWidth, sourceHeight: sourceHeight)
    }
    let points = [
      sourcePoint(outputX: Double(region.x) + 0.5, outputY: Double(region.y) + 0.5),
      sourcePoint(outputX: Double(region.x + region.width) - 0.5, outputY: Double(region.y) + 0.5),
      sourcePoint(outputX: Double(region.x) + 0.5, outputY: Double(region.y + region.height) - 0.5),
      sourcePoint(outputX: Double(region.x + region.width) - 0.5,
                  outputY: Double(region.y + region.height) - 0.5),
    ]
    let x = max(0, Int(floor(Self.snapPixelCoordinate(points.map(\.x).min()! - 0.5))))
    let y = max(0, Int(floor(Self.snapPixelCoordinate(points.map(\.y).min()! - 0.5))))
    let endX = min(sourceWidth, Int(ceil(Self.snapPixelCoordinate(points.map(\.x).max()! - 0.5))) + 1)
    let endY = min(sourceHeight, Int(ceil(Self.snapPixelCoordinate(points.map(\.y).max()! - 0.5))) + 1)
    return PixelRect(x: x, y: y, width: endX - x, height: endY - y)
  }

  /// Resample raw LINEAR values before gain/density/LUT. A smaller full-image
  /// input is a preview; an original ROI must declare its canonical sourceRegion.
  public func render(
    _ input: PixelBuffer, sourceRegion: PixelRect? = nil, outputRegion: PixelRect? = nil,
    maxDimension: Int? = nil, cancelled: @Sendable () -> Bool = { false }
  ) throws -> PixelBuffer {
    guard input.width > 0, input.height > 0, input.width <= Int.max / input.height,
      input.width * input.height == input.pixels.count
    else { throw PrintroomError.invalid("裁剪输入像素缓冲区无效。") }
    let source = sourceRegion ?? PixelRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight)
    guard source.x >= 0, source.y >= 0, source.width > 0, source.height > 0,
      source.width <= sourceWidth, source.height <= sourceHeight,
      source.x <= sourceWidth - source.width, source.y <= sourceHeight - source.height
    else { throw PrintroomError.invalid("裁剪读取区域超出原图。") }
    let region = outputRegion ?? PixelRect(x: 0, y: 0, width: outputWidth, height: outputHeight)
    try validateOutputRegion(region)
    let limit = maxDimension ?? (sourceRegion == nil ? max(input.width, input.height)
                                 : max(region.width, region.height))
    guard limit > 0 else { throw PrintroomError.invalid("裁剪输出尺寸无效。") }
    let scale = min(1, Double(limit) / Double(max(region.width, region.height)))
    let width = max(1, Int(Double(region.width) * scale))
    let height = max(1, Int(Double(region.height) * scale))
    if crop == nil, sourceRegion == nil, outputRegion == nil,
      width == (orientation.swapsAxes ? input.height : input.width),
      height == (orientation.swapsAxes ? input.width : input.height)
    { return try orientation.transform(input, cancelled: cancelled) }
    if cancelled() { throw CancellationError() }
    var pixels = [SIMD4<Float>]()
    pixels.reserveCapacity(width * height)
    for y in 0..<height {
      if cancelled() { throw CancellationError() }
      for x in 0..<width {
        let p = sourcePoint(
          outputX: Double(region.x) + (Double(x) + 0.5) * Double(region.width) / Double(width),
          outputY: Double(region.y) + (Double(y) + 0.5) * Double(region.height) / Double(height))
        let ix = (p.x - Double(source.x)) * Double(input.width) / Double(source.width) - 0.5
        let iy = (p.y - Double(source.y)) * Double(input.height) / Double(source.height) - 0.5
        pixels.append(Self.bilinear(x: ix, y: iy, width: input.width, height: input.height) {
          input.pixels[$1 * input.width + $0]
        })
      }
    }
    return PixelBuffer(width: width, height: height, pixels: pixels)
  }

  /// Full-size export reads UInt16 once and creates only a bounded Float32 row block.
  public func renderRows(_ image: LinearImage, rows: Range<Int>) throws -> PixelBuffer {
    guard image.width == sourceWidth, image.height == sourceHeight,
      image.samples.count == sourceWidth * sourceHeight * 3 else {
      throw PrintroomError.invalid("裁剪原始样本尺寸不匹配。")
    }
    guard rows.lowerBound >= 0, rows.upperBound <= outputHeight, !rows.isEmpty else {
      throw PrintroomError.invalid("裁剪输出区域超出范围。")
    }
    try Task.checkCancellation()
    var pixels = [SIMD4<Float>]()
    pixels.reserveCapacity(rows.count * outputWidth)
    if sine == 0 {
      // Keep the historical full-frame export's integer path and cost. A plain
      // crop is the same exact sample reorder with an integer origin offset.
      let originX = Int(rect.minX), originY = Int(rect.minY)
      for y in rows {
        try Task.checkCancellation()
        for x in 0..<outputWidth {
          let p = orientation.inversePixel(x: x + originX, y: y + originY,
                                           sourceWidth: sourceWidth, sourceHeight: sourceHeight)
          pixels.append(SIMD4(image.pixel(x: p.x, y: p.y), 1))
        }
      }
      return PixelBuffer(width: outputWidth, height: rows.count, pixels: pixels)
    }
    for y in rows {
      try Task.checkCancellation()
      for x in 0..<outputWidth {
        let p = sourcePoint(outputX: Double(x) + 0.5, outputY: Double(y) + 0.5)
        pixels.append(Self.bilinear(x: p.x - 0.5, y: p.y - 0.5,
                                    width: sourceWidth, height: sourceHeight) {
          SIMD4(image.pixel(x: $0, y: $1), 1)
        })
      }
    }
    return PixelBuffer(width: outputWidth, height: rows.count, pixels: pixels)
  }

  private func validateOutputRegion(_ region: PixelRect) throws {
    guard region.x >= 0, region.y >= 0, region.width > 0, region.height > 0,
      region.width <= outputWidth, region.height <= outputHeight,
      region.x <= outputWidth - region.width, region.y <= outputHeight - region.height
    else { throw PrintroomError.invalid("裁剪输出区域超出范围。") }
  }

  private static func bilinear(
    x: Double, y: Double, width: Int, height: Int,
    pixel: (Int, Int) -> SIMD4<Float>
  ) -> SIMD4<Float> {
    // Edge extension covers only the outer half-pixel support. Geometry itself
    // guarantees that every requested output pixel lies within the photograph.
    let sx = max(0, min(Double(width - 1), snapPixelCoordinate(x)))
    let sy = max(0, min(Double(height - 1), snapPixelCoordinate(y)))
    let x0 = Int(floor(sx)), y0 = Int(floor(sy))
    let fx = Float(sx - Double(x0)), fy = Float(sy - Double(y0))
    let a = pixel(x0, y0)
    if fx == 0, fy == 0 { return a }
    let b = pixel(min(width - 1, x0 + 1), y0)
    let c = pixel(x0, min(height - 1, y0 + 1))
    let d = pixel(min(width - 1, x0 + 1), min(height - 1, y0 + 1))
    return (a + (b - a) * fx) + ((c + (d - c) * fx) - (a + (b - a) * fx)) * fy
  }

  /// Rotation arithmetic can land a few ulps either side of an integer center.
  /// Treat sub-nanopixel noise consistently in the ROI bounds and interpolation,
  /// so an exact center does not require an otherwise unused neighboring pixel.
  private static func snapPixelCoordinate(_ value: Double) -> Double {
    let integer = value.rounded()
    return abs(value - integer) <= 1e-9 ? integer : value
  }
}

private extension FrameOrientation {
  var isReflection: Bool { [.flipHorizontal, .flipVertical, .transpose, .transverse].contains(self) }
  func forwardEdge(x: Double, y: Double, sourceWidth w: Double, sourceHeight h: Double) -> SIMD2<Double> {
    switch self {
    case .identity: SIMD2(x, y)
    case .flipHorizontal: SIMD2(w - x, y)
    case .rotate180: SIMD2(w - x, h - y)
    case .flipVertical: SIMD2(x, h - y)
    case .transpose: SIMD2(y, x)
    case .rotate90CW: SIMD2(h - y, x)
    case .transverse: SIMD2(h - y, w - x)
    case .rotate90CCW: SIMD2(y, w - x)
    }
  }
  func inverseEdge(x: Double, y: Double, sourceWidth w: Double, sourceHeight h: Double) -> SIMD2<Double> {
    switch self {
    case .identity: SIMD2(x, y)
    case .flipHorizontal: SIMD2(w - x, y)
    case .rotate180: SIMD2(w - x, h - y)
    case .flipVertical: SIMD2(x, h - y)
    case .transpose: SIMD2(y, x)
    case .rotate90CW: SIMD2(y, h - x)
    case .transverse: SIMD2(w - y, h - x)
    case .rotate90CCW: SIMD2(w - y, x)
    }
  }
}
