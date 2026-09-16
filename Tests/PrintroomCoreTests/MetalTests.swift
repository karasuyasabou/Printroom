import XCTest

@testable import PrintroomCore

final class MetalTests: XCTestCase {
  func testCPUAgreementAcrossStagesAndExtremes() throws {
    let gpu = try MetalPipeline()
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let lut = try CubeLUT(url: root.appendingPathComponent("LUT/DCI-P3 Kodak 2383 D65.cube"))
    var seed: UInt64 = 734912
    func random() -> Float {
      seed = seed &* 6_364_136_223_846_793_005 &+ 1
      return Float((seed >> 32) & 0xffff) / 65535
    }
    var pixels = (0..<4096).map { _ in SIMD4<Float>(random(), random(), random(), 1) }
    pixels += [SIMD4(0, 0, 0, 1), SIMD4(1, 1, 1, 1), SIMD4(-0.1, 1.2, 0.000001, 1)]
    let input = PixelBuffer(width: pixels.count, height: 1, pixels: pixels)
    let image = LinearImage(
      width: 4, height: 4,
      samples: Array(repeating: [UInt16(13107), 26214, 39321], count: 16).flatMap { $0 })
    var maximum: Float = 0
    var stageMaximum = [Float](repeating: 0, count: PipelineStage.allCases.count)
    var stageMaximumRMS = [Double](repeating: 0, count: PipelineStage.allCases.count)
    for matrix in PrintDensityMatrix.allCases {
      let calibration = try Pipeline.calibrate(
        image: image, rect: PixelRect(x: 0, y: 0, width: 4, height: 4), matrix: matrix,
        sourceFrameID: nil)
      for adjustment in [
        FrameAdjustments(),
        FrameAdjustments(
          timing: .init(master: 37, red: -12, green: 23, blue: 8),
          contrast: .init(master: 1.13, red: 0.8, green: 1.2, blue: 1.5)),
        FrameAdjustments(
          timing: .init(master: -512, red: 512, green: -512, blue: 512),
          contrast: .init(master: 4, red: 4, green: 0.25, blue: 4)),
      ] {
        for stage in PipelineStage.allCases {
          let cpu = try Pipeline.render(
            input, calibration: calibration, adjustments: adjustment, lut: lut, stage: stage)
          let actual = try gpu.render(
            input, calibration: calibration, adjustments: adjustment, lut: lut, stage: stage)
          var sum: Double = 0
          for i in pixels.indices {
            for c in 0..<3 {
              let diff = abs(cpu.pixels[i][c] - actual.pixels[i][c])
              maximum = max(maximum, diff)
              stageMaximum[stage.rawValue] = max(stageMaximum[stage.rawValue], diff)
              let bound: Float = stage == .final ? 2e-4 : 2e-5 + 2e-5 * abs(cpu.pixels[i][c])
              XCTAssertLessThanOrEqual(diff, bound, "\(matrix) \(stage) sample \(i) channel \(c)")
              sum += Double(diff) * Double(diff)
            }
          }
          stageMaximumRMS[stage.rawValue] = max(stageMaximumRMS[stage.rawValue], sqrt(sum / Double(pixels.count * 3)))
          if stage == .final {
            XCTAssertLessThanOrEqual(sqrt(sum / Double(pixels.count * 3)), 2e-5)
          }
        }
      }
    }
    for stage in PipelineStage.allCases {
      print("Metal stage \(stage.label): max=\(stageMaximum[stage.rawValue]) worst-run RMS=\(stageMaximumRMS[stage.rawValue])")
    }
    print(
      "Metal agreement: \(gpu.deviceName), \(pixels.count) pixels × 2 matrices × 3 adjustments × \(PipelineStage.allCases.count) stages; max error \(maximum)"
    )
  }
}
