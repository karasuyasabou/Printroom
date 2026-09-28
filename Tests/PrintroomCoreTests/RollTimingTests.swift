import Foundation
import XCTest
@testable import PrintroomCore

final class RollTimingTests: XCTestCase {
  private func profile() throws -> Data {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try Data(contentsOf: root.appendingPathComponent("ICC/DCIP3_D65.icc"))
  }
  private func lut() throws -> CubeLUT {
    try CubeLUT(size: 2, values: (0..<8).map {
      SIMD4(Float($0 & 1), Float(($0 >> 1) & 1), Float(($0 >> 2) & 1), 1)
    })
  }
  func testP95RetainsBrighterLightsAndDeterminism() throws {
    // 95 diffuse pixels at 600, five lights at 900: independent expected E=85.
    let pixels = Array(repeating: SIMD3<Float>(repeating: 600), count: 95)
      + Array(repeating: SIMD3<Float>(repeating: 900), count: 5)
    let frames = [RollTiming.Frame(densityCV: pixels, lut: try lut())]
    let result = try RollTiming.solve(frames, profile: profile())
    XCTAssertEqual(result, TimingParameters(red: 85, green: 85, blue: 85))
    XCTAssertEqual(try RollTiming.solve(frames, profile: profile()), result)
    XCTAssertEqual(pixels.last!.x + Float(result.red), 985)
  }
  func testSharedCastRecoveredWithoutChangingExposureAnchor() throws {
    let frames = [RollTiming.Frame(densityCV: Array(repeating: SIMD3<Float>(630,600,570), count: 100), lut: try lut())]
    let t = try RollTiming.solve(frames, profile: profile())
    XCTAssertLessThanOrEqual(abs(t.red - 55), 1)
    XCTAssertLessThanOrEqual(abs(t.green - 85), 1)
    XCTAssertLessThanOrEqual(abs(t.blue - 115), 1)
    XCTAssertEqual(t.red + t.green + t.blue, 255)
    XCTAssertEqual(t.master, 0)
  }
  func testFractionalExposureIntegerAnchor() throws {
    let frames = [RollTiming.Frame(densityCV: Array(repeating: SIMD3<Float>(repeating: 600.4), count: 20), lut: try lut())]
    let t = try RollTiming.solve(frames, profile: profile())
    XCTAssertLessThanOrEqual(abs(600.4 + Double(t.red+t.green+t.blue)/3 - 685), 1.0/6 + 0.0001)
  }
  func testNoDataNonfiniteAndUnreachableExposureFail() throws {
    XCTAssertThrowsError(try RollTiming.solve([], profile: profile()))
    for value: Float in [0, 1300, .nan] {
      XCTAssertThrowsError(try RollTiming.solve([.init(densityCV: [SIMD3(repeating: value)], lut: lut())], profile: profile()))
    }
  }
  func testSamplingUsesCalibratedDensityAndExcludesClippedPixels() throws {
    let p = PixelBuffer(width: 2, height: 1, pixels: [SIMD4(0.1,0.1,0.1,1), SIMD4(0,0,0,1)])
    let values = try RollTiming.samples(p, calibration: .init())
    XCTAssertEqual(values.count, 1024)
    for v in values { XCTAssertEqual(v.x, 500, accuracy: 0.001) }
    XCTAssertThrowsError(try RollTiming.samples(PixelBuffer(width: 1,height: 1,pixels: [SIMD4(0,0,0,1)]), calibration: .init()))
  }
}
