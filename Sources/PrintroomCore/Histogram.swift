import Foundation

public struct HistogramChannel: Equatable, Sendable {
  public fileprivate(set) var bins = [UInt64](repeating: 0, count: 256)
  public fileprivate(set) var belowRange: UInt64 = 0
  public fileprivate(set) var aboveRange: UInt64 = 0
  public fileprivate(set) var nonFinite: UInt64 = 0
  public fileprivate(set) var blackEndpoint: UInt64 = 0
  public fileprivate(set) var whiteEndpoint: UInt64 = 0
  /// Finite values at/beyond the diagnostic/export range. Non-finite values are separate.
  public var blackClipped: UInt64 { belowRange + blackEndpoint }
  public var whiteClipped: UInt64 { aboveRange + whiteEndpoint }
}

public struct HistogramStatistics: Equatable, Sendable {
  public let channels: [HistogramChannel]
  public let stage: PipelineStage
  public let pixelCount: Int
  public let sampleCount: Int
  public var isApproximate: Bool { sampleCount != pixelCount }
  public let isPreview: Bool
  public var unit: String {
    switch stage {
    case .l0, .l1: "线性透射率（0–1）"
    case .d0, .d1, .d2, .d3: "归一化密度 N（CV / 1024）"
    case .final: "P3-D65 Gamma 2.6 编码值（0–1）"
    }
  }

  /// Whole buffer statistics before presentation color management. Caller must supply the whole
  /// photograph (possibly a preview), never a visible viewport or 1:1 tile. In-range [0,1] samples
  /// use min(255, floor(value*256)); finite outliers and nonfinite values are reported separately,
  /// never folded into edge bins. Pixel values are not clipped or otherwise changed.
  public static func compute(
    _ buffer: PixelBuffer, stage: PipelineStage, isPreview: Bool = true,
    cancelled: @Sendable () -> Bool = { false }
  ) throws -> HistogramStatistics {
    guard buffer.width > 0, buffer.height > 0, buffer.width <= Int.max / buffer.height,
      buffer.width * buffer.height == buffer.pixels.count
    else { throw PrintroomError.invalid("直方图像素缓冲区尺寸无效") }
    if cancelled() { throw CancellationError() }
    var channels = [HistogramChannel(), HistogramChannel(), HistogramChannel()]
    for (index, pixel) in buffer.pixels.enumerated() {
      if index % 4096 == 0, cancelled() { throw CancellationError() }
      for channel in 0..<3 {
        let value = pixel[channel]
        if !value.isFinite { channels[channel].nonFinite += 1 }
        else if value < 0 { channels[channel].belowRange += 1 }
        else if value > 1 { channels[channel].aboveRange += 1 }
        else {
          if value == 0 { channels[channel].blackEndpoint += 1 }
          if value == 1 { channels[channel].whiteEndpoint += 1 }
          channels[channel].bins[min(255, Int(value * 256))] += 1
        }
      }
    }
    if cancelled() { throw CancellationError() }
    return Self(channels: channels, stage: stage, pixelCount: buffer.pixels.count,
                sampleCount: buffer.pixels.count,
                isPreview: isPreview)
  }

  /// Deterministic whole-image grid: one sample per 4×4 cell for large previews.
  /// Counts describe actual samples, never extrapolated full-image counts.
  public static func computePreview(
    _ buffer: PixelBuffer, stage: PipelineStage,
    cancelled: @Sendable () -> Bool = { false }
  ) throws -> HistogramStatistics {
    guard buffer.width > 0, buffer.height > 0, buffer.width <= Int.max / buffer.height,
      buffer.width * buffer.height == buffer.pixels.count
    else { throw PrintroomError.invalid("直方图像素缓冲区尺寸无效") }
    guard buffer.pixels.count > 131_072 else {
      return try compute(buffer, stage: stage, cancelled: cancelled)
    }
    let width = (buffer.width - 1) / 4 + 1
    let height = (buffer.height - 1) / 4 + 1
    var sampled = PixelBuffer(width: width, height: height,
      pixels: [])
    sampled.pixels.reserveCapacity(width * height)
    for y in stride(from: 0, to: buffer.height, by: 4) {
      if cancelled() { throw CancellationError() }
      let row = min(y + 2, buffer.height - 1) * buffer.width
      for x in stride(from: 0, to: buffer.width, by: 4) {
        sampled.pixels.append(buffer.pixels[row + min(x + 2, buffer.width - 1)])
      }
    }
    let result = try compute(sampled, stage: stage, cancelled: cancelled)
    return Self(channels: result.channels, stage: stage, pixelCount: buffer.pixels.count,
      sampleCount: result.sampleCount, isPreview: true)
  }
}
