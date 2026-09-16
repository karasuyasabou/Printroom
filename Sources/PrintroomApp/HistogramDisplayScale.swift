import Foundation

/// Presentation only: no bins or image samples are changed.
enum HistogramDisplayScale {
  static func upperBound(channelBins: [[UInt64]], sampleCount: Int) -> Double {
    let occupied = channelBins.flatMap { $0 }.filter { $0 > 0 }.sorted()
    guard let peak = occupied.last else { return 1 }
    // Ignore empty bins so narrow distributions still have a useful scale.
    // Nearest-rank P90 rejects isolated spikes wherever they fall on the x axis.
    let rank = max(0, Int(ceil(Double(occupied.count) * 0.9)) - 1)
    let typicalPeak = Double(occupied[rank]) * 4
    // Do not magnify tiny sampled populations without bound in near-solid images.
    let floor = max(1, Double(sampleCount) * 0.002)
    return min(Double(peak), max(floor, typicalPeak))
  }

  static func heightFraction(count: UInt64, upperBound: Double) -> Double {
    min(1, Double(count) / max(1, upperBound))
  }
}
