import Testing
@testable import PrintroomApp

struct HistogramDisplayScaleTests {
  @Test func nightSceneRetainsSubjectAndLinearRatios() {
    var bins = [UInt64](repeating: 0, count: 256)
    bins[0] = 90_000
    for i in 70..<170 { bins[i] = 100 }
    let limit = HistogramDisplayScale.upperBound(channelBins: [bins], sampleCount: 100_000)
    #expect(HistogramDisplayScale.heightFraction(count: 100, upperBound: limit) == 0.25)
    #expect(HistogramDisplayScale.heightFraction(count: 90_000, upperBound: limit) == 1)
    let low = HistogramDisplayScale.heightFraction(count: 40, upperBound: limit)
    let high = HistogramDisplayScale.heightFraction(count: 80, upperBound: limit)
    #expect(abs(high / low - 2) < 1e-12)
    #expect(HistogramDisplayScale.heightFraction(count: 200, upperBound: limit) == 0.5)
    #expect(bins[0] == 90_000)
  }

  @Test func broadDarkPeakAndSamplingScale() {
    var bins = [UInt64](repeating: 100, count: 256)
    for i in 4..<20 { bins[i] = 10_000 }
    let count = Int(bins.reduce(0, +))
    let limit = HistogramDisplayScale.upperBound(channelBins: [bins], sampleCount: count)
    #expect(limit < 1_000)
    let scaled = HistogramDisplayScale.upperBound(
      channelBins: [bins.map { $0 * 4 }], sampleCount: count * 4)
    #expect(abs(scaled / limit - 4) < 1e-12)
    #expect(HistogramDisplayScale.upperBound(channelBins: [Array(bins.reversed())],
      sampleCount: count) == limit)
  }

  @Test func emptyFlatAndSparseDistributions() {
    #expect(HistogramDisplayScale.upperBound(channelBins: [], sampleCount: 0) == 1)
    #expect(HistogramDisplayScale.upperBound(channelBins: [[0, 0]], sampleCount: 100) == 1)
    #expect(HistogramDisplayScale.upperBound(channelBins: [[0, 100_000, 0]],
      sampleCount: 100_000) == 100_000)
    #expect(HistogramDisplayScale.upperBound(channelBins: [[2, 2, 2]], sampleCount: 6) == 2)
    #expect(HistogramDisplayScale.heightFraction(count: 0, upperBound: 1) == 0)
  }

  @Test func sharedRGBScaleAndRareSampleFloor() {
    let red = [UInt64](repeating: 100, count: 256)
    let green = [UInt64](repeating: 50, count: 256)
    let blue = [UInt64](repeating: 25, count: 256)
    let limit = HistogramDisplayScale.upperBound(channelBins: [red, green, blue], sampleCount: 25_600)
    #expect(HistogramDisplayScale.heightFraction(count: 100, upperBound: limit) == 1)
    #expect(HistogramDisplayScale.heightFraction(count: 50, upperBound: limit) == 0.5)
    #expect(HistogramDisplayScale.heightFraction(count: 25, upperBound: limit) == 0.25)
    let rare = [UInt64(99_900)] + [UInt64](repeating: 1, count: 100)
    #expect(HistogramDisplayScale.upperBound(channelBins: [rare], sampleCount: 100_000) >= 200)
  }
}
