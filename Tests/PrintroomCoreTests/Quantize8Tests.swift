import Foundation
import XCTest
@testable import PrintroomCore

final class Quantize8Tests: XCTestCase, @unchecked Sendable {
  private func legacy(_ input: PixelBuffer) -> [UInt8] {
    input.pixels.flatMap { pixel in
      (0..<3).map { UInt8(floor(min(1, max(0, pixel[$0])) * 255 + 0.5)) }
    }
  }

  func testExactRGBBytesAtRoundingBoundariesAndFiniteExtremes() throws {
    var values: [Float] = [-Float.greatestFiniteMagnitude, -1, -0.0, 0,
      Float.leastNonzeroMagnitude, 1, 2, Float.greatestFiniteMagnitude]
    for code in 0..<255 {
      let midpoint = (Float(code) + 0.5) / 255
      values += [midpoint.nextDown, midpoint, midpoint.nextUp]
    }
    // Cover every normalized UInt16 value and a reproducible sample of Float bit patterns.
    values += (0...65535).map { Float($0) / 65535 }
    var state: UInt32 = 0x7a51_209b
    for _ in 0..<65536 {
      state = state &* 1664525 &+ 1013904223
      let value = Float(bitPattern: state)
      if value.isFinite { values.append(value) }
    }
    let pixels = values.indices.map { SIMD4<Float>(values[$0], values[($0 + 1) % values.count],
      values[($0 + 2) % values.count], .nan) }
    let input = PixelBuffer(width: pixels.count, height: 1, pixels: pixels)
    XCTAssertEqual(try OutputColorConverter.quantize8(input), legacy(input))
    let ordered = PixelBuffer(width: 2, height: 1,
      pixels: [SIMD4(0, 0.5, 1, .nan), SIMD4(1, 0, 0.5, .infinity)])
    XCTAssertEqual(try OutputColorConverter.quantize8(ordered), [0, 128, 255, 255, 0, 128])
  }

  func testInvalidDimensionsAndNonFiniteRGBKeepError() {
    var inputs = [PixelBuffer(width: 0, height: 1, pixels: []),
      PixelBuffer(width: -1, height: 1, pixels: []),
      PixelBuffer(width: Int.max, height: 2, pixels: []),
      PixelBuffer(width: 2, height: 1, pixels: [SIMD4(0, 0, 0, 1)])]
    for channel in 0..<3 {
      for value: Float in [.nan, .infinity, -.infinity] {
        var pixel = SIMD4<Float>(0, 0, 0, 1); pixel[channel] = value
        inputs.append(PixelBuffer(width: 1, height: 1, pixels: [pixel]))
      }
    }
    for input in inputs {
      XCTAssertThrowsError(try OutputColorConverter.quantize8(input)) { error in
        guard case PrintroomError.invalid(let message) = error else {
          return XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(message, "输出量化输入尺寸或数值无效。")
      }
    }
  }

  func testAlreadyCancelledTaskKeepsQuantizerContract() async throws {
    let result = try await Task {
      withUnsafeCurrentTask { $0?.cancel() }
      // Quantization itself has no cancellation checkpoint; callers retain their checkpoints.
      return try OutputColorConverter.quantize8(
        PixelBuffer(width: 1, height: 1, pixels: [SIMD4(0, 0.5, 1, 1)]))
    }.value
    XCTAssertEqual(result, [0, 128, 255])
  }
}
