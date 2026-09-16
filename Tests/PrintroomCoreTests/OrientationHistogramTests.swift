import Foundation
import XCTest

@testable import PrintroomCore

final class OrientationHistogramTests: XCTestCase {
  func testPreviewGridMatchesIndependentSamplesAndPreservesCounts() throws {
    let width = 513, height = 259
    let values: [Float] = [-1, 0, 0.25, 1, 2, .nan, .infinity]
    let pixels = (0..<(width * height)).map { index in
      SIMD4<Float>(repeating: values[(index / width + index % width) % values.count])
    }
    let buffer = PixelBuffer(width: width, height: height, pixels: pixels)
    let result = try HistogramStatistics.computePreview(buffer, stage: .d3)
    var reference = [SIMD4<Float>]()
    for y in 0..<65 {
      for x in 0..<129 {
        reference.append(pixels[min(y * 4 + 2, height - 1) * width + min(x * 4 + 2, width - 1)])
      }
    }
    let exact = try HistogramStatistics.compute(
      PixelBuffer(width: 129, height: 65, pixels: reference), stage: .d3)
    XCTAssertEqual(result.channels, exact.channels)
    XCTAssertEqual(result.pixelCount, width * height)
    XCTAssertEqual(result.sampleCount, 129 * 65)
    XCTAssertTrue(result.isApproximate)
    for channel in result.channels {
      XCTAssertEqual(channel.bins.reduce(0, +) + channel.belowRange + channel.aboveRange
        + channel.nonFinite, UInt64(result.sampleCount))
    }
    XCTAssertThrowsError(try HistogramStatistics.computePreview(buffer, stage: .d3, cancelled: { true }))
  }

  func testSmallPreviewKeepsExactStatistics() throws {
    let result = try HistogramStatistics.computePreview(image, stage: .l0)
    XCTAssertEqual(result, try HistogramStatistics.compute(image, stage: .l0))
    XCTAssertFalse(result.isApproximate)
  }
  private let image: PixelBuffer = {
    let pixels: [SIMD4<Float>] = [
      SIMD4(0, 10, 20, 30), SIMD4(1, 11, 21, 31), SIMD4(2, 12, 22, 32),
      SIMD4(3, 13, 23, 33), SIMD4(4, 14, 24, 34), SIMD4(5, 15, 25, 35),
    ]
    return PixelBuffer(width: 3, height: 2, pixels: pixels)
  }()

  func testAllEightDirectionsHaveExpectedPixelsAndDimensions() throws {
    let expected: [[Float]] = [
      [0, 1, 2, 3, 4, 5], [2, 1, 0, 5, 4, 3], [5, 4, 3, 2, 1, 0], [3, 4, 5, 0, 1, 2],
      [0, 3, 1, 4, 2, 5], [3, 0, 4, 1, 5, 2], [5, 2, 4, 1, 3, 0], [2, 5, 1, 4, 0, 3],
    ]
    for orientation in FrameOrientation.allCases {
      let transformed = try orientation.transform(image)
      XCTAssertEqual(transformed.width, orientation.rawValue < 5 ? 3 : 2)
      XCTAssertEqual(transformed.height, orientation.rawValue < 5 ? 2 : 3)
      XCTAssertEqual(transformed.pixels.map(\.x), expected[orientation.rawValue - 1])
      for pixel in transformed.pixels {
        XCTAssertEqual(pixel.y, pixel.x + 10)
        XCTAssertEqual(pixel.z, pixel.x + 20)
        XCTAssertEqual(pixel.w, pixel.x + 30)
      }
    }
  }

  func testEveryCompositionMatchesSequentialDisplayedPixelOperations() throws {
    for start in FrameOrientation.allCases {
      let displayed = try start.transform(image)
      for operation in OrientationOperation.allCases {
        let expected: PixelBuffer
        switch operation {
        case .reset: expected = image
        case .rotateClockwise: expected = try FrameOrientation.rotate90CW.transform(displayed)
        case .rotateCounterclockwise: expected = try FrameOrientation.rotate90CCW.transform(displayed)
        case .flipHorizontal: expected = try FrameOrientation.flipHorizontal.transform(displayed)
        case .flipVertical: expected = try FrameOrientation.flipVertical.transform(displayed)
        }
        let combined = try start.applying(operation).transform(image)
        XCTAssertEqual(combined.width, expected.width)
        XCTAssertEqual(combined.height, expected.height)
        XCTAssertEqual(combined.pixels, expected.pixels, "\(start) then \(operation)")
      }
    }
    let clockwiseHorizontal = FrameOrientation.identity.applying(.rotateClockwise).applying(.flipHorizontal)
    let horizontalClockwise = FrameOrientation.identity.applying(.flipHorizontal).applying(.rotateClockwise)
    XCTAssertEqual(clockwiseHorizontal, .transpose)
    XCTAssertEqual(horizontalClockwise, .transverse)
    XCTAssertNotEqual(clockwiseHorizontal, horizontalClockwise)
    var value = FrameOrientation.identity
    for _ in 0..<4 { value = value.applying(.rotateClockwise) }
    XCTAssertEqual(value, .identity)
  }

  func testEveryPixelAndHalfOpenRectangleMapsExactlyBackToSource() throws {
    for orientation in FrameOrientation.allCases {
      let size = orientation.outputSize(sourceWidth: 3, sourceHeight: 2)
      for y in 0..<2 {
        for x in 0..<3 {
          let displayed = orientation.forwardPixel(x: x, y: y, sourceWidth: 3, sourceHeight: 2)
          let original = orientation.inversePixel(x: displayed.x, y: displayed.y, sourceWidth: 3, sourceHeight: 2)
          XCTAssertEqual(original.x, x)
          XCTAssertEqual(original.y, y)
        }
      }
      for y in 0..<size.height {
        for x in 0..<size.width {
          for height in 1...(size.height - y) {
            for width in 1...(size.width - x) {
              let rect = PixelRect(x: x, y: y, width: width, height: height)
              let source = try orientation.inverseRect(rect, sourceWidth: 3, sourceHeight: 2)
              var expected = Set<Int>()
              for yy in y..<(y + height) {
                for xx in x..<(x + width) {
                  let p = orientation.inversePixel(x: xx, y: yy, sourceWidth: 3, sourceHeight: 2)
                  expected.insert(p.y * 3 + p.x)
                }
              }
              let actual = Set((source.y..<(source.y + source.height)).flatMap { yy in
                (source.x..<(source.x + source.width)).map { yy * 3 + $0 }
              })
              XCTAssertEqual(actual, expected)
            }
          }
        }
      }
    }
  }

  func testInverseMappedTileTransformedLocallyMatchesWholeImageCrop() throws {
    let source = PixelBuffer(width: 7, height: 5, pixels: (0..<35).map { SIMD4(repeating: Float($0)) })
    for orientation in FrameOrientation.allCases {
      let full = try orientation.transform(source)
      let viewRect = PixelRect(x: 1, y: 1, width: 3, height: 2)
      let rawRect = try orientation.inverseRect(viewRect, sourceWidth: 7, sourceHeight: 5)
      let pixels = (rawRect.y..<(rawRect.y + rawRect.height)).flatMap { y in
        (rawRect.x..<(rawRect.x + rawRect.width)).map { x in source.pixels[y * 7 + x] }
      }
      let tile = try orientation.transform(PixelBuffer(width: rawRect.width, height: rawRect.height, pixels: pixels))
      let expected = (1..<3).flatMap { y in (1..<4).map { x in full.pixels[y * full.width + x] } }
      XCTAssertEqual(tile.pixels, expected)
      XCTAssertEqual(tile.width, 3)
      XCTAssertEqual(tile.height, 2)
    }
  }

  func testInvalidGeometryAndCancellationAreExplicit() throws {
    for rect in [PixelRect(x: -1, y: 0, width: 1, height: 1),
                 PixelRect(x: 0, y: 0, width: 0, height: 1),
                 PixelRect(x: Int.max, y: 0, width: 1, height: 1),
                 PixelRect(x: 0, y: 0, width: Int.max, height: 1)] {
      XCTAssertThrowsError(try FrameOrientation.rotate90CW.inverseRect(rect, sourceWidth: 3, sourceHeight: 2))
    }
    XCTAssertThrowsError(try FrameOrientation.identity.transform(image, cancelled: { true })) {
      XCTAssertTrue($0 is CancellationError)
    }
    XCTAssertThrowsError(try FrameOrientation.flipVertical.transform(PixelBuffer(width: 2, height: 3, pixels: [])))
    XCTAssertThrowsError(try HistogramStatistics.compute(image, stage: .final, cancelled: { true })) {
      XCTAssertTrue($0 is CancellationError)
    }
    XCTAssertThrowsError(try HistogramStatistics.compute(PixelBuffer(width: Int.max, height: 2, pixels: []), stage: .l0))
  }

  func testHistogramKnownValuesEndpointsOutliersAndNonfiniteAreSeparate() throws {
    let values: [Float] = [-1, 0, 1 / 256, 0.5, 255 / 256, 1, 1.001, .nan, .infinity, -.infinity]
    let buffer = PixelBuffer(width: 5, height: 2,
      pixels: values.map { SIMD4($0, 0.25, 0.75, .nan) })
    let histogram = try HistogramStatistics.compute(buffer, stage: .final)
    XCTAssertEqual(histogram.pixelCount, 10)
    XCTAssertTrue(histogram.isPreview)
    let red = histogram.channels[0]
    XCTAssertEqual(red.bins[0], 1)
    XCTAssertEqual(red.bins[1], 1)
    XCTAssertEqual(red.bins[128], 1)
    XCTAssertEqual(red.bins[255], 2)
    XCTAssertEqual(red.bins.reduce(0, +), 5)
    XCTAssertEqual(red.blackEndpoint, 1)
    XCTAssertEqual(red.whiteEndpoint, 1)
    XCTAssertEqual(red.belowRange, 1)
    XCTAssertEqual(red.aboveRange, 1)
    XCTAssertEqual(red.nonFinite, 3)
    XCTAssertEqual(red.blackClipped, 2)
    XCTAssertEqual(red.whiteClipped, 2)
    XCTAssertEqual(histogram.channels[1].bins[64], 10)
    XCTAssertEqual(histogram.channels[2].bins[192], 10)
    XCTAssertEqual(histogram.channels[1].nonFinite, 0)
    for (index, value) in values.enumerated() {
      XCTAssertEqual(buffer.pixels[index].x.bitPattern, value.bitPattern)
    }
  }

  func testHistogramAllBinsAndStageUnitsWithoutChangingNumericDomain() throws {
    let buffer = PixelBuffer(width: 256, height: 1,
      pixels: (0..<256).map { SIMD4(repeating: (Float($0) + 0.5) / 256) })
    for stage in PipelineStage.allCases {
      let histogram = try HistogramStatistics.compute(buffer, stage: stage, isPreview: false)
      XCTAssertEqual(histogram.channels[0].bins, [UInt64](repeating: 1, count: 256))
      XCTAssertEqual(histogram.stage, stage)
      XCTAssertFalse(histogram.isPreview)
      switch stage {
      case .l0, .l1, .l2: XCTAssertTrue(histogram.unit.contains("线性"))
      case .d0, .d1, .d2, .d3: XCTAssertTrue(histogram.unit.contains("1024"))
      case .final: XCTAssertTrue(histogram.unit.contains("P3-D65 Gamma 2.6"))
      }
    }
  }

  func testHistogramIsInvariantUnderAllDirectionsAndIgnoresAlpha() throws {
    let original = try HistogramStatistics.compute(image, stage: .d3)
    for orientation in FrameOrientation.allCases {
      let result = try HistogramStatistics.compute(orientation.transform(image), stage: .d3)
      XCTAssertEqual(result, original)
    }
  }

  func testHistogramCancellationDuringLongScan() throws {
    let calls = CancellationCounter(limit: 3)
    let buffer = PixelBuffer(width: 10_000, height: 1,
      pixels: [SIMD4<Float>](repeating: SIMD4(repeating: 0.5), count: 10_000))
    XCTAssertThrowsError(try HistogramStatistics.compute(buffer, stage: .final, cancelled: { calls.check() })) {
      XCTAssertTrue($0 is CancellationError)
    }
    XCTAssertEqual(calls.count, 3)
  }
}

private final class CancellationCounter: @unchecked Sendable {
  private let lock = NSLock()
  let limit: Int
  private(set) var count = 0
  init(limit: Int) { self.limit = limit }
  func check() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    count += 1
    return count >= limit
  }
}
