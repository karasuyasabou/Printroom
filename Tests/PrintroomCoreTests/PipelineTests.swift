import Foundation
import XCTest

@testable import PrintroomCore

final class PipelineTests: XCTestCase {
  private func assertRGB(
    _ actual: SIMD3<Float>, _ expected: SIMD3<Float>, accuracy: Float = 1e-6,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    for channel in 0..<3 {
      XCTAssertTrue(
        actual[channel].isFinite, "Non-finite channel \(channel)", file: file, line: line)
      XCTAssertEqual(
        actual[channel], expected[channel], accuracy: accuracy,
        "Channel \(channel)", file: file, line: line)
    }
  }

  private func identityLUT(size: Int = 2) throws -> CubeLUT {
    var values: [SIMD4<Float>] = []
    for b in 0..<size {
      for g in 0..<size {
        for r in 0..<size {
          values.append(
            SIMD4(
              Float(r) / Float(size - 1), Float(g) / Float(size - 1), Float(b) / Float(size - 1), 1)
          )
        }
      }
    }
    return try CubeLUT(size: size, values: values)
  }

  private func constantImage(_ rgb: [UInt16] = [13107, 26214, 39321]) -> LinearImage {
    LinearImage(width: 4, height: 4, samples: Array(repeating: rgb, count: 16).flatMap { $0 })
  }

  private func withCube(_ source: String, _ body: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "printroom-cube-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("test.cube")
    try source.write(to: url, atomically: true, encoding: .utf8)
    try body(url)
  }

  private let cubeRows = "0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n"

  func testMatrixBasisVectorsKeepOriginalLEDColumns() {
    let basis: [SIMD3<Float>] = [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)]
    let columns: [SIMD3<Float>] = [
      SIMD3(1.0584, 0.0753, -0.0147),
      SIMD3(-0.0204, 1.0120, 0.1420),
      SIMD3(0.0023, -0.0693, 0.7774),
    ]
    for (vector, column) in zip(basis, columns) {
      assertRGB(Pipeline.matrix(vector, .identity), vector, accuracy: 0)
      assertRGB(Pipeline.matrix(vector, .ledLightSource), column, accuracy: 0)
    }
    assertRGB(
      Pipeline.matrix(SIMD3(0.2, 0.4, 0.6), .ledLightSource), SIMD3(0.2049, 0.37828, 0.5203))
    assertRGB(Pipeline.matrix(SIMD3(repeating: 1), .ledLightSource), SIMD3(1.0403, 1.0180, 0.9047))
  }

  func testAnalyticGainOffsetAnd95CVTargetForBothMatrices() throws {
    let lut = try identityLUT()
    let image = constantImage()
    let frameID = UUID()
    let rect = PixelRect(x: 0, y: 0, width: 4, height: 4)
    for matrix in PrintDensityMatrix.allCases {
      let calibration = try Pipeline.calibrate(
        image: image, rect: rect, matrix: matrix, sourceFrameID: frameID)
      XCTAssertTrue(calibration.isCalibrated)
      assertRGB(try XCTUnwrap(calibration.baseRGB), SIMD3(0.2, 0.4, 0.6))
      assertRGB(calibration.gainRGB, SIMD3(3.75, 1.875, 1.25))
      let expectedOffset: SIMD3<Float> =
        matrix == .identity
        ? SIMD3(repeating: 32.530631695850026)
        : SIMD3(30.013116153192783, 31.406183066375327, 38.483962495235524)
      assertRGB(calibration.filmBaseOffsetCV, expectedOffset, accuracy: 2e-5)
      let base = image.pixel(x: 0, y: 0)
      assertRGB(
        try Pipeline.process(
          base, calibration: calibration, adjustments: .init(), lut: lut, stage: .l1),
        SIMD3(repeating: 0.75))
      for stage in [PipelineStage.d2, .d3] {
        let actualCV =
          try Pipeline.process(
            base, calibration: calibration, adjustments: .init(), lut: lut, stage: stage) * 1024
        assertRGB(actualCV, SIMD3(repeating: 95), accuracy: 0.01)
      }
      XCTAssertEqual(calibration.sourceFrameID, frameID)
      XCTAssertEqual(calibration.selection, rect)
      XCTAssertEqual(calibration.sourceWidth, 4)
      XCTAssertEqual(calibration.sourceHeight, 4)
    }
  }

  func testEvenMedianIsIndependentForEachChannel() throws {
    var samples: [UInt16] = []
    for i in 0..<16 {
      samples += [
        UInt16((i + 1) * 1000), UInt16((16 - i) * 2000),
        UInt16(i.isMultiple(of: 2) ? 5000 + i * 100 : 30000 + i * 100),
      ]
    }
    let image = LinearImage(width: 4, height: 4, samples: samples)
    let result = try Pipeline.calibrate(
      image: image, rect: .init(x: 0, y: 0, width: 4, height: 4), matrix: .identity,
      sourceFrameID: nil)
    assertRGB(try XCTUnwrap(result.baseRGB), SIMD3(8500, 17000, 18250) / 65535)
  }

  func testOddMedianIncludesFiniteZerosAndSaturatedOutliers() throws {
    var samples: [UInt16] = []
    // Eight dark and eight saturated samples leave the one central RGB sample as the median.
    // Filtering those finite extremes would leave fewer than the required 16 pixels.
    for i in 0..<17 {
      samples += i < 8 ? [0, 0, 0] : (i == 8 ? [12345, 23456, 34567] : [65535, 65535, 65535])
    }
    let image = LinearImage(width: 17, height: 1, samples: samples)
    let result = try Pipeline.calibrate(
      image: image, rect: .init(x: 0, y: 0, width: 17, height: 1), matrix: .identity,
      sourceFrameID: nil)
    assertRGB(try XCTUnwrap(result.baseRGB), SIMD3(12345, 23456, 34567) / 65535)
  }

  func testCalibrationUsesHalfOpenOriginalPixelRectangle() throws {
    var samples: [UInt16] = []
    for y in 0..<6 {
      for x in 0..<7 {
        samples += (x >= 2 && x < 6 && y >= 1 && y < 5) ? [13107, 26214, 39321] : [65535, 0, 0]
      }
    }
    let image = LinearImage(width: 7, height: 6, samples: samples)
    let rect = PixelRect(x: 2, y: 1, width: 4, height: 4)
    let result = try Pipeline.calibrate(
      image: image, rect: rect, matrix: .identity, sourceFrameID: nil)
    assertRGB(try XCTUnwrap(result.baseRGB), SIMD3(0.2, 0.4, 0.6))
    XCTAssertEqual(result.selection, rect)
    XCTAssertEqual(result.sourceWidth, 7)
    XCTAssertEqual(result.sourceHeight, 6)
  }

  func testCalibrationDiagnosticsCountsPixelsInROIWithoutFilteringChannels() throws {
    let image = LinearImage(
      width: 3, height: 2,
      samples: [
        0, 0, 0, 0, 0, 65535, 100, 200, 300,
        65535, 0, 0, 65535, 65535, 50, 0, 5, 6,
      ])
    let diagnostics = try Pipeline.calibrationDiagnostics(
      image: image, rect: .init(x: 1, y: 0, width: 2, height: 2))
    XCTAssertEqual(diagnostics.pixelCount, 4)
    XCTAssertEqual(diagnostics.zeroPixelCount, 2)
    XCTAssertEqual(diagnostics.saturatedPixelCount, 2)
    XCTAssertEqual(diagnostics.zeroFraction, 0.5)
    XCTAssertEqual(diagnostics.saturatedFraction, 0.5)
    let ordinary = try Pipeline.calibrationDiagnostics(
      image: constantImage(), rect: .init(x: 0, y: 0, width: 4, height: 4))
    XCTAssertEqual(ordinary.zeroFraction, 0)
    XCTAssertEqual(ordinary.saturatedFraction, 0)
    XCTAssertThrowsError(
      try Pipeline.calibrationDiagnostics(
        image: image, rect: .init(x: 1, y: 0, width: Int.max, height: 2)))
    XCTAssertThrowsError(
      try Pipeline.calibrationDiagnostics(
        image: image, rect: .init(x: 0, y: 0, width: 0, height: 2)))
    XCTAssertThrowsError(
      try Pipeline.calibrationDiagnostics(
        image: .init(width: 3, height: 2, samples: []),
        rect: .init(x: 0, y: 0, width: 3, height: 2)))
  }

  func testInvalidCalibrationRegionsAndMalformedImagesThrow() throws {
    let image = constantImage()
    let invalidRects: [PixelRect] = [
      .init(x: 0, y: 0, width: 3, height: 4), .init(x: -1, y: 0, width: 4, height: 4),
      .init(x: 0, y: -1, width: 4, height: 4), .init(x: 1, y: 0, width: 4, height: 4),
      .init(x: 0, y: 1, width: 4, height: 4), .init(x: 0, y: 0, width: 0, height: 4),
      .init(x: Int.max, y: 0, width: 4, height: 4), .init(x: 0, y: 0, width: Int.max, height: 4),
    ]
    for rect in invalidRects {
      XCTAssertThrowsError(
        try Pipeline.calibrate(image: image, rect: rect, matrix: .identity, sourceFrameID: nil))
    }
    let rect = PixelRect(x: 0, y: 0, width: 4, height: 4)
    for badImage in [
      constantImage([0, 2000, 3000]),
      LinearImage(width: 4, height: 4, samples: [1, 2, 3]),
      LinearImage(width: 0, height: 4, samples: []),
      LinearImage(width: Int.max, height: 2, samples: []),
      LinearImage(width: Int.max / 2, height: 1, samples: []),
    ] {
      XCTAssertThrowsError(
        try Pipeline.calibrate(image: badImage, rect: rect, matrix: .identity, sourceFrameID: nil))
    }
  }

  func testMatrixChangeReusesSavedBaseAndGainWithoutTouchingOriginal() throws {
    let original = try Pipeline.calibrate(
      image: constantImage(), rect: .init(x: 0, y: 0, width: 4, height: 4),
      matrix: .identity, sourceFrameID: UUID())
    let switched = try Pipeline.recalibrate(original, matrix: .ledLightSource)
    XCTAssertEqual(original.matrix, .identity)
    XCTAssertEqual(switched.matrix, .ledLightSource)
    XCTAssertEqual(switched.baseRGB, original.baseRGB)
    XCTAssertEqual(switched.gainRGB, original.gainRGB)
    XCTAssertEqual(switched.sourceFrameID, original.sourceFrameID)
    XCTAssertEqual(switched.selection, original.selection)
    XCTAssertNotEqual(switched.filmBaseOffsetCV, original.filmBaseOffsetCV)
    let restored = try Pipeline.recalibrate(switched, matrix: .identity)
    assertRGB(restored.filmBaseOffsetCV, original.filmBaseOffsetCV, accuracy: 0)
    let adjustments = FrameAdjustments(timing: .init(master: 20, red: 3, green: -7, blue: 1))
    let actual =
      try Pipeline.process(
        XCTUnwrap(switched.baseRGB), calibration: switched, adjustments: adjustments,
        lut: identityLUT(), stage: .d2) * 1024
    assertRGB(actual, SIMD3(118, 108, 116), accuracy: 0.01)

    var nonstandard = original
    nonstandard.gainRGB = SIMD3(2, 1, 0.5)
    let result = try Pipeline.recalibrate(nonstandard, matrix: .identity)
    let expectedOffset = SIMD3<Float>(
      Float(95 + 500 * log10(Double(0.2 as Float) * 2)),
      Float(95 + 500 * log10(Double(0.4 as Float))),
      Float(95 + 500 * log10(Double(0.6 as Float) * 0.5)))
    // The published CPU error budget is 1e-6 in normalized density, not CV.
    assertRGB(result.filmBaseOffsetCV / 1024, expectedOffset / 1024)
    XCTAssertEqual(result.gainRGB, nonstandard.gainRGB)
  }

  func testUncalibratedMatrixChangeKeepsNeutralGainAndZeroOffset() throws {
    let calibration = try Pipeline.recalibrate(FilmCalibration(), matrix: .ledLightSource)
    XCTAssertFalse(calibration.isCalibrated)
    XCTAssertEqual(calibration.matrix, .ledLightSource)
    assertRGB(calibration.gainRGB, SIMD3(repeating: 1), accuracy: 0)
    assertRGB(calibration.filmBaseOffsetCV, SIMD3(repeating: 0), accuracy: 0)
  }

  func testInvalidRecalibrationDoesNotPartiallyMutateExistingValue() throws {
    var calibration = try Pipeline.calibrate(
      image: constantImage(), rect: .init(x: 0, y: 0, width: 4, height: 4),
      matrix: .identity, sourceFrameID: nil)
    calibration.gainRGB.x = 0
    let snapshot = calibration
    XCTAssertThrowsError(try Pipeline.recalibrate(calibration, matrix: .ledLightSource))
    XCTAssertEqual(calibration, snapshot)
    calibration.gainRGB.x = .infinity
    XCTAssertThrowsError(try Pipeline.recalibrate(calibration, matrix: .ledLightSource))
    calibration.gainRGB.x = 1
    calibration.baseRGB = SIMD3(0.2, .nan, 0.6)
    XCTAssertThrowsError(try Pipeline.recalibrate(calibration, matrix: .identity))
  }

  func testDensityAnalyticValuesEpsilonAndUnclippedStages() throws {
    let lut = try identityLUT()
    let calibration = FilmCalibration()
    assertRGB(
      try Pipeline.process(
        SIMD3(1, 0.1, 10), calibration: calibration, adjustments: .init(), lut: lut, stage: .d0),
      SIMD3(0, 0.48828125, -0.48828125))
    assertRGB(
      try Pipeline.process(
        SIMD3(0, -3, 1e-6), calibration: calibration, adjustments: .init(), lut: lut, stage: .d0),
      SIMD3(repeating: 2.9296875))
    let raw = SIMD3<Float>(-0.2, 1.2, 0.4)
    for stage in [PipelineStage.l0, .l1] {
      assertRGB(
        try Pipeline.process(
          raw, calibration: calibration, adjustments: .init(), lut: lut, stage: stage), raw,
        accuracy: 0)
    }
    let density = try Pipeline.process(
      SIMD3(10, 0, 0.1), calibration: calibration, adjustments: .init(), lut: lut, stage: .d3)
    assertRGB(density, SIMD3(-0.48828125, 2.9296875, 0.48828125))
    let final = try Pipeline.process(
      SIMD3(10, 0, 0.1), calibration: calibration, adjustments: .init(), lut: lut)
    assertRGB(final, SIMD3(0, 1, 0.48828125))
  }

  func testTimingUses1024AndDoesNotClampCombinedControls() throws {
    let lut = try identityLUT()
    let calibration = FilmCalibration()
    let oneCV = try Pipeline.process(
      SIMD3(repeating: 1), calibration: calibration,
      adjustments: .init(timing: .init(red: 1, green: -1)), lut: lut, stage: .d2)
    assertRGB(oneCV, SIMD3(1 / 1024, -1 / 1024, 0), accuracy: 0)
    XCTAssertEqual(Double(oneCV.x) * 2.048, 0.002, accuracy: 1e-12)
    let combined = try Pipeline.process(
      SIMD3(repeating: 1), calibration: calibration,
      adjustments: .init(timing: .init(master: 256, red: 256, green: -256, blue: 0)), lut: lut,
      stage: .d2)
    assertRGB(combined, SIMD3(0.5, 0, 0.25), accuracy: 0)
  }

  func testFractionalCalibrationOffsetRemainsInCV() throws {
    var calibration = FilmCalibration()
    calibration.baseRGB = SIMD3(repeating: 0.75)
    calibration.filmBaseOffsetCV = SIMD3(32.53063, -15.25, 0.5)
    let result = try Pipeline.process(
      SIMD3(repeating: 1), calibration: calibration,
      adjustments: .init(timing: .init(master: 1, red: -2, green: 4)), lut: identityLUT(),
      stage: .d2)
    assertRGB(result, SIMD3(31.53063, -10.25, 1.5) / 1024, accuracy: 1e-7)
  }

  func testContrastUses470PivotAndUnclampedProduct() throws {
    let lut = try identityLUT()
    let pivot: Float = 470 / 1024
    var calibration = FilmCalibration()
    calibration.baseRGB = SIMD3(repeating: 0.75)
    calibration.filmBaseOffsetCV = SIMD3(repeating: 470)
    let extremes = FrameAdjustments(contrast: .init(master: 4, red: 4, green: 0.25, blue: 2))
    let atPivot = try Pipeline.process(
      SIMD3(repeating: 1), calibration: calibration,
      adjustments: extremes, lut: lut, stage: .d3)
    assertRGB(atPivot, SIMD3(repeating: pivot), accuracy: 0)
    calibration.filmBaseOffsetCV = SIMD3(repeating: 685)
    let awayFromPivot = try Pipeline.process(
      SIMD3(repeating: 1), calibration: calibration,
      adjustments: extremes, lut: lut, stage: .d3)
    assertRGB(awayFromPivot, SIMD3(3910, 685, 2190) / 1024, accuracy: 0)
    calibration.filmBaseOffsetCV = SIMD3(repeating: 0)
    let lowProduct = try Pipeline.process(
      SIMD3(repeating: 1), calibration: calibration,
      adjustments: .init(contrast: .init(master: 0.25, red: 0.25)), lut: lut, stage: .d3)
    XCTAssertEqual(lowProduct.x, pivot * 0.9375, accuracy: 1e-7)
  }

  func testFinalUses1024ReferenceCVWithoutAdditionalTransfer() throws {
    let lut = try identityLUT()
    let input = SIMD3<Float>(
      Float(pow(10.0, -0.19)), Float(pow(10.0, -0.94)), Float(pow(10.0, -1.37)))
    assertRGB(
      try Pipeline.process(input, calibration: .init(), adjustments: .init(), lut: lut),
      SIMD3(95, 470, 685) / 1024)
    let encodedRGB = SIMD3<Float>(0.1, 0.25, 0.7)
    let constant = try CubeLUT(size: 2, values: Array(repeating: SIMD4(encodedRGB, 1), count: 8))
    assertRGB(
      try Pipeline.process(input, calibration: .init(), adjustments: .init(), lut: constant),
      encodedRGB)
  }

  func testInvalidAdjustmentsRejectEveryControlAndNonfiniteContrast() throws {
    for index in 0..<4 {
      for value in [-257, 257, Int.min, Int.max] {
        var t = [0, 0, 0, 0]
        t[index] = value
        XCTAssertThrowsError(
          try Pipeline.validate(
            .init(timing: .init(master: t[0], red: t[1], green: t[2], blue: t[3]))))
      }
      for value: Float in [0.249, 4.001, 0, -1, .nan, .infinity, -.infinity] {
        var c: [Float] = [1, 1, 1, 1]
        c[index] = value
        XCTAssertThrowsError(
          try Pipeline.validate(
            .init(contrast: .init(master: c[0], red: c[1], green: c[2], blue: c[3]))))
      }
    }
    XCTAssertNoThrow(
      try Pipeline.validate(
        .init(
          timing: .init(master: -256, red: 256, green: -256, blue: 256),
          contrast: .init(master: 0.25, red: 4, green: 0.25, blue: 4))))
    XCTAssertNoThrow(try Pipeline.validate(.init(contrast: .init(master: 1.234))))
  }

  func testNonfiniteInputsAndIntermediateOverflowThrow() throws {
    let lut = try identityLUT()
    for stage in PipelineStage.allCases {
      for badValue: Float in [.nan, .infinity, -.infinity] {
        for channel in 0..<3 {
          var input = SIMD3<Float>(repeating: 0.3)
          input[channel] = badValue
          XCTAssertThrowsError(
            try Pipeline.process(
              input, calibration: .init(), adjustments: .init(), lut: lut, stage: stage))
        }
      }
    }
    for invalid: Float in [0, -1, .nan, .infinity] {
      var calibration = FilmCalibration()
      calibration.gainRGB.y = invalid
      XCTAssertThrowsError(
        try Pipeline.process(
          SIMD3(repeating: 1), calibration: calibration, adjustments: .init(), lut: lut))
    }
    var calibration = FilmCalibration()
    calibration.filmBaseOffsetCV.z = .nan
    XCTAssertThrowsError(
      try Pipeline.process(
        SIMD3(repeating: 1), calibration: calibration, adjustments: .init(), lut: lut))
    calibration.filmBaseOffsetCV.z = 0
    calibration.gainRGB.x = Float.greatestFiniteMagnitude
    XCTAssertThrowsError(
      try Pipeline.process(
        SIMD3(repeating: 2), calibration: calibration, adjustments: .init(), lut: lut))
  }

  func testIdentityLUTGridBoundsAndFractionalCoordinates() throws {
    for size in [2, 3, 5] {
      let lut = try identityLUT(size: size)
      let inputs: [SIMD3<Float>] = [
        SIMD3(0, 0, 0), SIMD3(1, 1, 1), SIMD3(1, 0, 0),
        SIMD3(0, 1, 0), SIMD3(0, 0, 1), SIMD3(0.123, 0.456, 0.789),
        SIMD3(0.5, 0.5, 0.5), SIMD3(Float(1).nextDown, 0, 1),
      ]
      for rgb in inputs {
        assertRGB(lut.sample(rgb), rgb)
      }
      assertRGB(lut.sample(SIMD3(-12, 4, 0.25)), SIMD3(0, 1, 0.25))
    }
  }

  func testLUTEightCornerInterpolationHasIndependentDoubleOracle() throws {
    let corners: [SIMD4<Float>] = [
      SIMD4(0.1, 0.8, 0.3, 1), SIMD4(0.9, 0.2, 0.6, 1),
      SIMD4(0.3, 0.5, 0.1, 1), SIMD4(0.7, 0.4, 0.9, 1),
      SIMD4(0.4, 0.9, 0.2, 1), SIMD4(0.2, 0.1, 0.8, 1),
      SIMD4(0.8, 0.3, 0.5, 1), SIMD4(0.6, 0.7, 0.4, 1),
    ]
    let lut = try CubeLUT(size: 2, values: corners)
    for input: SIMD3<Float> in [SIMD3(0.2, 0.35, 0.8), SIMD3(0.5, 0.5, 0.5), SIMD3(0, 0.25, 1)] {
      var expected = SIMD3<Double>(repeating: 0)
      // Direct barycentric corner sum, independently of the implementation's nested mixes.
      for (index, corner) in corners.enumerated() {
        let r = Double(input.x)
        let g = Double(input.y)
        let b = Double(input.z)
        let weight =
          (index & 1 == 0 ? 1 - r : r)
          * (index & 2 == 0 ? 1 - g : g) * (index & 4 == 0 ? 1 - b : b)
        expected += SIMD3(Double(corner.x), Double(corner.y), Double(corner.z)) * weight
      }
      assertRGB(
        lut.sample(input), SIMD3(Float(expected.x), Float(expected.y), Float(expected.z)),
        accuracy: 2e-7)
    }
  }

  func testAxisColoredLUTRevealsRedFastestIndexing() throws {
    var values: [SIMD4<Float>] = []
    for b in 0..<3 {
      for g in 0..<3 {
        for r in 0..<3 {
          values.append(SIMD4(Float(b) / 2, Float(r) / 2, Float(g) / 2, 1))
        }
      }
    }
    let lut = try CubeLUT(size: 3, values: values)
    assertRGB(lut.sample(SIMD3(0.1, 0.7, 0.3)), SIMD3(0.3, 0.1, 0.7))
    assertRGB(lut.sample(SIMD3(1, 0, 0)), SIMD3(0, 1, 0), accuracy: 0)
  }

  func testCubeParserAcceptsCommentsBOMCRLFAndUnitDomainDefaults() throws {
    let source =
      "\u{FEFF}# comment\nTITLE \"Synthetic # identity\"\nDOMAIN_MIN 0 0 0\nLUT_3D_SIZE 2 # size\nDOMAIN_MAX 1 1 1\n\n"
      + cubeRows
    try withCube(source.replacingOccurrences(of: "\n", with: "\r\n")) { url in
      let lut = try CubeLUT(url: url)
      XCTAssertEqual(lut.size, 2)
      XCTAssertEqual(lut.values.count, 8)
      assertRGB(lut.sample(SIMD3(0.2, 0.3, 0.4)), SIMD3(0.2, 0.3, 0.4))
    }
    try withCube("LUT_3D_SIZE 2\n" + cubeRows) { url in
      assertRGB(try CubeLUT(url: url).sample(SIMD3(0.3, 0.4, 0.6)), SIMD3(0.3, 0.4, 0.6))
    }
  }

  func testCubeParserRejectsMalformedUnsupportedAndNonfiniteContent() throws {
    let invalidSources = [
      "", cubeRows, "LUT_3D_SIZE 1\n0 0 0", "LUT_3D_SIZE -2\n", "LUT_3D_SIZE 2.5\n",
      "LUT_3D_SIZE \(Int.max)\n", "LUT_3D_SIZE 2\n0 0 0\n",
      "LUT_3D_SIZE 2\n" + cubeRows + "0 0 0\n",
      "LUT_3D_SIZE 2\nLUT_3D_SIZE 2\n" + cubeRows,
      "LUT_3D_SIZE 2\nDOMAIN_MIN -1 0 0\n" + cubeRows,
      "LUT_3D_SIZE 2\nDOMAIN_MAX 1 2 1\n" + cubeRows,
      "LUT_3D_SIZE 2\nDOMAIN_MAX 1 1\n" + cubeRows,
      "LUT_3D_SIZE 2\nDOMAIN_MIN nan 0 0\n" + cubeRows,
      "LUT_3D_SIZE 2\nDOMAIN_MIN 0 0 0\nDOMAIN_MIN 0 0 0\n" + cubeRows,
      "LUT_1D_SIZE 2\n0 0 0\n1 1 1\n", "LUT_3D_SIZE 2\nLUT_1D_SIZE 2\n" + cubeRows,
      "LUT_3D_SIZE 2\n" + cubeRows + "DOMAIN_MAX 1 1 1\n",
      "LUT_3D_SIZE 2\n0 0 0 1\n" + cubeRows,
      "LUT_3D_SIZE 2\nnan 0 0\n" + cubeRows,
      "LUT_3D_SIZE 2\n0 inf 0\n" + cubeRows,
      "LUT_3D_SIZE 2\n0 0 1e999\n" + cubeRows,
      "TITLE\nLUT_3D_SIZE 2\n" + cubeRows,
    ]
    for source in invalidSources {
      try withCube(source) { url in XCTAssertThrowsError(try CubeLUT(url: url), source) }
    }
  }

  func testLUTInitializerRejectsInvalidDimensionsCountsAndValues() throws {
    for size in [Int.min, -2, 0, 1, Int.max] {
      XCTAssertThrowsError(try CubeLUT(size: size, values: []))
    }
    XCTAssertThrowsError(
      try CubeLUT(size: 2, values: Array(repeating: SIMD4(repeating: 0), count: 7)))
    for channel in 0..<4 {
      var values = Array(repeating: SIMD4<Float>(repeating: 0), count: 8)
      values[4][channel] = .nan
      XCTAssertThrowsError(try CubeLUT(size: 2, values: values))
    }
    let lut = try identityLUT()
    XCTAssertTrue(lut.sample(SIMD3(.nan, 0, 0)).x.isNaN)
    XCTAssertTrue(lut.sample(SIMD3(0, .infinity, 0)).y.isNaN)
    let extended = try CubeLUT(
      size: 2, values: Array(repeating: SIMD4(-0.1, 1.2, 0.5, 1), count: 8))
    assertRGB(extended.sample(SIMD3(repeating: 0.5)), SIMD3(-0.1, 1.2, 0.5))
  }

  func testRealKodakLUTMatchesRecordedGridAndDoubleInterpolationValues() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let lut = try CubeLUT(url: root.appendingPathComponent("LUT/DCI-P3 Kodak 2383 D65.cube"))
    XCTAssertEqual(lut.size, 33)
    XCTAssertEqual(lut.values.count, 35937)
    assertRGB(lut.sample(SIMD3(0, 0, 0)), SIMD3(0.041701, 0.043656, 0.054925), accuracy: 1e-7)
    assertRGB(lut.sample(SIMD3(1, 0, 0)), SIMD3(0.618016, 0.024784, 0.084027), accuracy: 1e-7)
    assertRGB(lut.sample(SIMD3(0, 1, 0)), SIMD3(0, 0.489238, 0.184797), accuracy: 1e-7)
    assertRGB(lut.sample(SIMD3(0, 0, 1)), SIMD3(0, 0, 0.585615), accuracy: 1e-7)
    assertRGB(lut.sample(SIMD3(1, 1, 1)), SIMD3(0.980440, 0.932183, 0.999996), accuracy: 1e-7)
    assertRGB(lut.sample(SIMD3(0.25, 0.5, 0.75)), SIMD3(0, 0.454593, 0.773807), accuracy: 1e-7)
    // Recorded independently with Python float64 corner weights and the immutable source file.
    assertRGB(
      lut.sample(SIMD3(0.123, 0.456, 0.789)), SIMD3(0, 0.3437228842260481, 0.73363044685056),
      accuracy: 2e-7)
  }

  func testRenderPreservesOrderDimensionsAndUnclippedDiagnosticValues() throws {
    let lut = try identityLUT()
    let input = PixelBuffer(
      width: 2, height: 2,
      pixels: [
        SIMD4(1, 0.1, 10, 7), SIMD4(0.1, 10, 1, 0),
        SIMD4(10, 1, 0.1, .nan), SIMD4(0, 0, 0, 1),
      ])
    let result = try Pipeline.render(
      input, calibration: .init(), adjustments: .init(), lut: lut, stage: .d0)
    XCTAssertEqual(result.width, 2)
    XCTAssertEqual(result.height, 2)
    let expected: [SIMD3<Float>] = [
      SIMD3(0, 0.48828125, -0.48828125), SIMD3(0.48828125, -0.48828125, 0),
      SIMD3(-0.48828125, 0, 0.48828125), SIMD3(repeating: 2.9296875),
    ]
    for (pixel, reference) in zip(result.pixels, expected) {
      assertRGB(SIMD3(pixel.x, pixel.y, pixel.z), reference)
      XCTAssertEqual(pixel.w, 1)
    }
    XCTAssertEqual(input.pixels[0].w, 7)
  }

  func testRenderRejectsMalformedDimensionsAndWholeTaskOnInvalidPixel() throws {
    let lut = try identityLUT()
    for input in [
      PixelBuffer(width: 0, height: 1, pixels: []),
      PixelBuffer(width: -1, height: -1, pixels: [SIMD4(repeating: 1)]),
      PixelBuffer(width: 2, height: 2, pixels: [SIMD4(repeating: 1)]),
      PixelBuffer(width: Int.max, height: 2, pixels: []),
      PixelBuffer(width: 2, height: 1, pixels: [SIMD4(repeating: 1), SIMD4(.nan, 0.5, 0.3, 1)]),
    ] {
      XCTAssertThrowsError(
        try Pipeline.render(input, calibration: .init(), adjustments: .init(), lut: lut))
    }
  }
}
