import Foundation
import XCTest
@testable import PrintroomCore

final class NeutralTimingTests: XCTestCase {
  private func patch(_ values: [SIMD3<Float>]) -> PixelBuffer {
    PixelBuffer(width: values.count, height: 1, pixels: values.map { SIMD4($0, 1) })
  }

  private func transmittance(_ cv: SIMD3<Double>) -> SIMD3<Float> {
    SIMD3(Float(pow(10, -cv.x / 500)), Float(pow(10, -cv.y / 500)),
      Float(pow(10, -cv.z / 500)))
  }

  /// Independent Double oracle in CV, using physical density rather than the
  /// production implementation's normalized-density operations.
  private func d3CV(
    _ rgb: SIMD3<Float>, calibration: FilmCalibration, adjustments: FrameAdjustments
  ) -> SIMD3<Double> {
    let density = (0..<3).map {
      -500 * log10(max(Double(rgb[$0]) * Double(calibration.gainRGB[$0]), 1e-6))
    }
    var d1 = SIMD3(density[0], density[1], density[2])
    if calibration.matrix == .ledLightSource {
      d1 = SIMD3(
        1.0584 * d1.x - 0.0204 * d1.y + 0.0023 * d1.z,
        0.0753 * d1.x + 1.0120 * d1.y - 0.0693 * d1.z,
        -0.0147 * d1.x + 0.1420 * d1.y + 0.7774 * d1.z)
    }
    let timing = adjustments.timing
    let contrast = adjustments.contrast
    let channelTiming = [timing.red, timing.green, timing.blue]
    let channelContrast = [contrast.red, contrast.green, contrast.blue]
    for channel in 0..<3 {
      let d2 = d1[channel] + Double(calibration.filmBaseOffsetCV[channel])
        + Double(timing.master + channelTiming[channel])
      d1[channel] = 685 + (d2 - 685) * Double(contrast.master) * Double(channelContrast[channel])
    }
    return d1
  }

  private func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    let middle = sorted.count / 2
    return sorted.count.isMultiple(of: 2)
      ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
  }

  private func assertNeutral(
    _ pixels: [SIMD3<Float>], calibration: FilmCalibration = .init(),
    adjustments: FrameAdjustments = .init(), file: StaticString = #filePath, line: UInt = #line
  ) throws -> FrameAdjustments {
    let original = pixels.map { d3CV($0, calibration: calibration, adjustments: adjustments) }
    let medians = (0..<3).map { channel in median(original.map { $0[channel] }) }
    let target = medians.reduce(0, +) / 3
    let solved = try NeutralTiming.solve(patch(pixels), calibration: calibration, adjustments: adjustments)
    XCTAssertEqual(solved.timing.master, adjustments.timing.master, file: file, line: line)
    XCTAssertEqual(solved.contrast, adjustments.contrast, file: file, line: line)
    let final = pixels.map { d3CV($0, calibration: calibration, adjustments: solved) }
    let effective = [solved.contrast.red, solved.contrast.green, solved.contrast.blue].map {
      Double($0) * Double(solved.contrast.master)
    }
    var mean: Double = 0
    for channel in 0..<3 {
      let value = median(final.map { $0[channel] })
      XCTAssertEqual(value, target, accuracy: effective[channel] / 2 + 0.002, file: file, line: line)
      mean += value / 3
    }
    XCTAssertEqual(mean, target, accuracy: effective.reduce(0, +) / 6 + 0.002, file: file, line: line)
    return solved
  }

  func testNeutralizesD3WithIndependentChannelContrastAndKeepsMaster() throws {
    let adjustments = FrameAdjustments(
      timing: .init(master: 79, red: -30, green: 20, blue: 60),
      contrast: .init(master: 1.25, red: 0.8, green: 1.4, blue: 0.65))
    let result = try assertNeutral(
      [SIMD3(0.2, 0.3, 0.4)], adjustments: adjustments)
    XCTAssertNotEqual(result.timing, adjustments.timing)
  }

  func testLEDUsesCalibratedTransformedDensityMedians() throws {
    var calibration = FilmCalibration()
    calibration.matrix = .ledLightSource
    calibration.baseRGB = SIMD3(0.5, 0.375, 0.9375)
    calibration.gainRGB = SIMD3(1.5, 2, 0.8)
    calibration = try Pipeline.recalibrate(calibration, matrix: .ledLightSource)
    let snapshot = calibration
    let adjustments = FrameAdjustments(
      timing: .init(master: 31, red: 15, green: -20, blue: 8),
      contrast: .init(master: 0.8, red: 1.5, green: 0.7, blue: 1.2))
    let pixels: [SIMD3<Float>] = [
      SIMD3(0.1, 0.3, 0.4), SIMD3(0.2, 0.05, 0.6), SIMD3(0.3, 0.2, 0.1),
      SIMD3(0.4, 0.1, 0.3), SIMD3(0.05, 0.4, 0.2),
    ]
    _ = try assertNeutral(pixels, calibration: calibration, adjustments: adjustments)
    XCTAssertEqual(calibration, snapshot)
  }

  func testGrainAndFiniteDustOutliersUseRobustMedian() throws {
    let center = SIMD3<Double>(350, 420, 530)
    var pixels = (-10...10).map { step in
      transmittance(center + SIMD3(Double(step), Double(step) * 2, Double(step) * 0.5))
    }
    pixels += [SIMD3(repeating: 0.0001), SIMD3(repeating: 0.95)]
    let clean = try NeutralTiming.solve(patch([transmittance(center)]), calibration: .init(), adjustments: .init())
    let noisy = try assertNeutral(pixels)
    XCTAssertEqual(noisy, clean)
  }

  func testEvenPopulationMediansAreTakenInD3RatherThanLinearSamples() throws {
    let pixels = [transmittance(SIMD3(200, 300, 450)), transmittance(SIMD3(400, 350, 750))]
    let result = try assertNeutral(pixels)
    // Median D3 CV = (300,325,600); target = 408 1/3 CV.
    XCTAssertEqual(result.timing, .init(red: 108, green: 83, blue: -192))
  }

  func testBothTimingEndpointsAreReachableWithoutClamping() throws {
    let positive = try assertNeutral([transmittance(SIMD3(100, 868, 868))])
    XCTAssertEqual(positive.timing, .init(red: 512, green: -256, blue: -256))
    let negative = try assertNeutral([transmittance(SIMD3(868, 100, 100))])
    XCTAssertEqual(negative.timing, .init(red: -512, green: 256, blue: 256))
  }

  func testUnreachableTargetsFailWithoutMutatingAdjustments() throws {
    let adjustments = FrameAdjustments(timing: .init(master: 47))
    let snapshot = adjustments
    for cv: SIMD3<Double> in [SIMD3(100, 871, 871), SIMD3(871, 100, 100)] {
      XCTAssertThrowsError(try NeutralTiming.solve(
        patch([transmittance(cv)]), calibration: .init(), adjustments: adjustments)) { error in
          XCTAssertTrue(error.localizedDescription.contains("超出"))
        }
    }
    XCTAssertEqual(adjustments, snapshot)
  }

  func testAlreadyNeutralIsUnchangedAndExtremeEffectiveContrastsMeetCVErrorBound() throws {
    for master: Float in [0.25, 4] {
      let adjustments = FrameAdjustments(
        timing: .init(master: 111, red: 7, green: 7, blue: 7),
        contrast: .init(master: master, red: master, green: master, blue: master))
      let result = try assertNeutral([SIMD3(repeating: 0.25)], adjustments: adjustments)
      XCTAssertEqual(result, adjustments)
      _ = try assertNeutral([transmittance(SIMD3(310.37, 377.11, 420.73))], adjustments: adjustments)
    }
  }

  func testMinorityClippedPixelsAreExcludedButMajorityClippingFails() throws {
    let valid: SIMD3<Float> = SIMD3(0.2, 0.3, 0.4)
    let clipped: [SIMD3<Float>] = [SIMD3(0, 0.3, 0.4), SIMD3(0.2, 1, 0.4)]
    let reference = try NeutralTiming.solve(patch([valid]), calibration: .init(), adjustments: .init())
    XCTAssertEqual(try NeutralTiming.solve(
      patch([valid, valid, valid] + clipped), calibration: .init(), adjustments: .init()), reference)
    for values in [clipped, [valid] + clipped, [valid, clipped[0]]] {
      XCTAssertThrowsError(try NeutralTiming.solve(
        patch(values), calibration: .init(), adjustments: .init())) { error in
          XCTAssertTrue(error.localizedDescription.contains("剪切"))
        }
    }
  }

  func testMalformedAndNonfiniteInputsAndInvalidCalibrationFail() throws {
    for input in [
      PixelBuffer(width: 0, height: 1, pixels: []),
      PixelBuffer(width: 2, height: 1, pixels: [SIMD4(repeating: 0.5)]),
      PixelBuffer(width: Int.max, height: 2, pixels: []),
      patch([SIMD3(.nan, 0.3, 0.4)]), patch([SIMD3(0.2, .infinity, 0.4)]),
      patch([SIMD3(-0.1, 0.3, 0.4)]), patch([SIMD3(0.2, 0.3, 1.01)]),
    ] {
      XCTAssertThrowsError(try NeutralTiming.solve(input, calibration: .init(), adjustments: .init()))
    }
    let valid = patch([SIMD3(0.2, 0.3, 0.4)])
    var calibration = FilmCalibration()
    calibration.gainRGB.y = 0
    XCTAssertThrowsError(try NeutralTiming.solve(valid, calibration: calibration, adjustments: .init()))
    calibration.gainRGB.y = 1
    calibration.filmBaseOffsetCV.x = .infinity
    XCTAssertThrowsError(try NeutralTiming.solve(valid, calibration: calibration, adjustments: .init()))
    XCTAssertThrowsError(try NeutralTiming.solve(
      valid, calibration: .init(), adjustments: .init(contrast: .init(red: .nan))))
  }

  func testDensityStagesNeedNoLUTAndFinalRequiresOne() throws {
    let rgb = SIMD3<Float>(0.2, 0.3, 0.4)
    for stage in PipelineStage.allCases where stage != .final {
      XCTAssertNoThrow(try Pipeline.process(rgb, calibration: .init(), adjustments: .init(), stage: stage))
      XCTAssertNoThrow(try Pipeline.render(patch([rgb]), calibration: .init(), adjustments: .init(), stage: stage))
    }
    XCTAssertThrowsError(try Pipeline.process(rgb, calibration: .init(), adjustments: .init()))
    XCTAssertThrowsError(try Pipeline.render(patch([rgb]), calibration: .init(), adjustments: .init()))
  }
}
