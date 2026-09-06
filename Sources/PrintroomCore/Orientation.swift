import Foundation

/// An edit is applied after the current orientation, in the displayed coordinate system.
public enum OrientationOperation: String, CaseIterable, Sendable {
  case rotateClockwise, rotateCounterclockwise, flipHorizontal, flipVertical, reset
}

/// User direction relative to the TIFF decoder's already-normalized, top-left source pixels.
/// These values describe all eight lossless square symmetries, independently of the TIFF tag.
public enum FrameOrientation: Int, CaseIterable, Codable, Sendable {
  case identity = 1, flipHorizontal = 2, rotate180 = 3, flipVertical = 4
  case transpose = 5, rotate90CW = 6, transverse = 7, rotate90CCW = 8

  public var swapsAxes: Bool { rawValue >= 5 }

  public func outputSize(sourceWidth: Int, sourceHeight: Int) -> (width: Int, height: Int) {
    swapsAxes ? (sourceHeight, sourceWidth) : (sourceWidth, sourceHeight)
  }

  /// Integer pixel centers: x in 0..<width, y in 0..<height. No scaling or interpolation.
  public func forwardPixel(x: Int, y: Int, sourceWidth: Int, sourceHeight: Int) -> (x: Int, y: Int) {
    switch self {
    case .identity: (x, y)
    case .flipHorizontal: (sourceWidth - 1 - x, y)
    case .rotate180: (sourceWidth - 1 - x, sourceHeight - 1 - y)
    case .flipVertical: (x, sourceHeight - 1 - y)
    case .transpose: (y, x)
    case .rotate90CW: (sourceHeight - 1 - y, x)
    case .transverse: (sourceHeight - 1 - y, sourceWidth - 1 - x)
    case .rotate90CCW: (y, sourceWidth - 1 - x)
    }
  }

  public func inversePixel(x: Int, y: Int, sourceWidth: Int, sourceHeight: Int) -> (x: Int, y: Int) {
    switch self {
    case .identity: (x, y)
    case .flipHorizontal: (sourceWidth - 1 - x, y)
    case .rotate180: (sourceWidth - 1 - x, sourceHeight - 1 - y)
    case .flipVertical: (x, sourceHeight - 1 - y)
    case .transpose: (y, x)
    case .rotate90CW: (y, sourceHeight - 1 - x)
    case .transverse: (sourceWidth - 1 - y, sourceHeight - 1 - x)
    case .rotate90CCW: (sourceWidth - 1 - y, x)
    }
  }

  /// Resolve composition to one canonical value, avoiding an unbounded edit history.
  public func applying(_ operation: OrientationOperation) -> FrameOrientation {
    let appended: FrameOrientation
    switch operation {
    case .rotateClockwise: appended = .rotate90CW
    case .rotateCounterclockwise: appended = .rotate90CCW
    case .flipHorizontal: appended = .flipHorizontal
    case .flipVertical: appended = .flipVertical
    case .reset: return .identity
    }
    let a = appended.matrix
    let b = matrix
    let product = SIMD4(
      a.x * b.x + a.y * b.z, a.x * b.y + a.y * b.w,
      a.z * b.x + a.w * b.z, a.z * b.y + a.w * b.w)
    // The D4 group is closed under multiplication.
    return Self.allCases.first { $0.matrix == product }!
  }

  /// A displayed integer, half-open selection maps exactly to an integer source rectangle.
  /// Zoom/pan must first be inverted by the canvas; these coordinates are image pixels.
  public func inverseRect(_ rect: PixelRect, sourceWidth: Int, sourceHeight: Int) throws -> PixelRect {
    let size = outputSize(sourceWidth: sourceWidth, sourceHeight: sourceHeight)
    guard sourceWidth > 0, sourceHeight > 0,
      rect.x >= 0, rect.y >= 0, rect.width > 0, rect.height > 0,
      rect.width <= size.width, rect.height <= size.height,
      rect.x <= size.width - rect.width, rect.y <= size.height - rect.height
    else { throw PrintroomError.invalid("方向选区超出图像范围") }
    let corners = [
      inversePixel(x: rect.x, y: rect.y, sourceWidth: sourceWidth, sourceHeight: sourceHeight),
      inversePixel(x: rect.x + rect.width - 1, y: rect.y + rect.height - 1,
                   sourceWidth: sourceWidth, sourceHeight: sourceHeight),
    ]
    let minX = min(corners[0].x, corners[1].x), minY = min(corners[0].y, corners[1].y)
    return PixelRect(x: minX, y: minY, width: abs(corners[1].x - corners[0].x) + 1,
                     height: abs(corners[1].y - corners[0].y) + 1)
  }

  /// Reorders all channels verbatim. Direction cannot change pipeline/histogram values.
  public func transform(
    _ buffer: PixelBuffer, cancelled: @Sendable () -> Bool = { false }
  ) throws -> PixelBuffer {
    guard buffer.width > 0, buffer.height > 0, buffer.width <= Int.max / buffer.height,
      buffer.width * buffer.height == buffer.pixels.count
    else { throw PrintroomError.invalid("方向变换的像素缓冲区尺寸无效") }
    if cancelled() { throw CancellationError() }
    if self == .identity { return buffer }
    let size = outputSize(sourceWidth: buffer.width, sourceHeight: buffer.height)
    var pixels = [SIMD4<Float>](repeating: .zero, count: buffer.pixels.count)
    for y in 0..<size.height {
      if cancelled() { throw CancellationError() }
      for x in 0..<size.width {
        let source = inversePixel(x: x, y: y, sourceWidth: buffer.width, sourceHeight: buffer.height)
        pixels[y * size.width + x] = buffer.pixels[source.y * buffer.width + source.x]
      }
    }
    return PixelBuffer(width: size.width, height: size.height, pixels: pixels)
  }

  private var matrix: SIMD4<Int> {
    switch self {
    case .identity: SIMD4(1, 0, 0, 1)
    case .flipHorizontal: SIMD4(-1, 0, 0, 1)
    case .rotate180: SIMD4(-1, 0, 0, -1)
    case .flipVertical: SIMD4(1, 0, 0, -1)
    case .transpose: SIMD4(0, 1, 1, 0)
    case .rotate90CW: SIMD4(0, -1, 1, 0)
    case .transverse: SIMD4(0, -1, -1, 0)
    case .rotate90CCW: SIMD4(0, 1, -1, 0)
    }
  }
}
