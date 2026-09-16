import Foundation
import XCTest
@testable import PrintroomCore

final class DiffuseWhiteTests: XCTestCase {
  func testBakedWhiteBrightnessAndContrastFixedPointCPUAndMetal() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let color = try FinalColorimetry(p3Profile: Data(contentsOf: root.appendingPathComponent("ICC/DCIP3_D65.icc")))
    let gpu = try MetalPipeline()
    for selection in CineonLogLUT.allCases {
      let lut = try CubeLUT(url: root.appendingPathComponent(selection.path))
      let original = try CubeLUT(url: root.appendingPathComponent("LUT/DCI-P3 \(selection.label) D65.cube"))
      let p = SIMD3<Float>(repeating: 685 / 1024)
      let expected = color.neutralMatchingLuminance(SIMD3<Double>(original.sample(p)))
      let actual = lut.sample(p)
      for c in 0..<3 { XCTAssertEqual(Double(actual[c]), expected[c], accuracy: 2e-6) }
      let linear = Float(pow(10.0, -685.0 / 500))
      let input = PixelBuffer(width: 1, height: 1, pixels: [SIMD4(linear, linear, linear, 1)])
      for contrast: Float in [0.25, 1, 2, 4] {
        let a = FrameAdjustments(contrast: .init(master: contrast, red: 0.8, green: 1.1, blue: 1.4))
        let density = try Pipeline.render(input, calibration: .init(), adjustments: a, stage: .d3)
        let cpu = try Pipeline.render(input, calibration: .init(), adjustments: a, lut: lut)
        let metal = try gpu.render(input, calibration: .init(), adjustments: a, lut: lut)
        for c in 0..<3 {
          XCTAssertEqual(density.pixels[0][c], p[c], accuracy: 2e-6)
          XCTAssertEqual(cpu.pixels[0][c], actual[c], accuracy: 2e-6)
          XCTAssertEqual(metal.pixels[0][c], actual[c], accuracy: 2e-6)
        }
      }
    }
  }
}
