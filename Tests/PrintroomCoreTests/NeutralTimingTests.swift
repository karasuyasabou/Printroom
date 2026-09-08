import Foundation
import simd
import XCTest
@testable import PrintroomCore

final class NeutralTimingTests: XCTestCase, @unchecked Sendable {
  private var root: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
  }
  private func profile() throws -> Data {
    try Data(contentsOf: root.appendingPathComponent("ICC/DCIP3_D65.icc"))
  }
  private func actualLUT() throws -> CubeLUT {
    try CubeLUT(url: root.appendingPathComponent("LUT/DCI-P3 Kodak 2383 D65.cube"))
  }
  private func patch(_ values: [SIMD3<Float>]) -> PixelBuffer {
    PixelBuffer(width: values.count, height: 1, pixels: values.map { SIMD4($0, 1) })
  }
  private func transmittance(_ cv: SIMD3<Double>) -> SIMD3<Float> {
    SIMD3(Float(pow(10, -cv.x / 500)), Float(pow(10, -cv.y / 500)),
      Float(pow(10, -cv.z / 500)))
  }
  private func identityLUT() throws -> CubeLUT {
    let values: [SIMD4<Float>] = (0..<8).map { i in
      let r = Float(i & 1), g = Float((i >> 1) & 1), b = Float((i >> 2) & 1)
      return SIMD4(r, g, b, 1)
    }
    return try CubeLUT(size: 2, values: values)
  }
  private func solve(_ input: PixelBuffer, calibration: FilmCalibration = .init(),
    adjustments: FrameAdjustments = .init(), lut: CubeLUT? = nil) throws -> FrameAdjustments {
    try NeutralTiming.solve(input, calibration: calibration, adjustments: adjustments,
      lut: try lut ?? actualLUT(), p3Profile: profile())
  }

  // Independent Float64 measurements. ICC constants extracted by Python's
  // struct decoder from immutable DCIP3_D65.icc, not production CMM helpers.
  private let colorants = simd_double3x3(columns: (
    SIMD3(0.5151214599609375, 0.2411956787109375, -0.0010528564453125),
    SIMD3(0.2919769287109375, 0.6922454833984375, 0.0418853759765625),
    SIMD3(0.1571044921875, 0.0665740966796875, 0.7840728759765625)))
  private let gamma = 2.600006103515625
  private func lab(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
    let xyz = colorants * SIMD3(pow(rgb.x, gamma), pow(rgb.y, gamma), pow(rgb.z, gamma))
    let white = colorants * SIMD3<Double>(repeating: 1)
    func f(_ t: Double) -> Double { t > 216.0 / 24389 ? pow(t, 1.0 / 3) : (24389.0 / 27 * t + 16) / 116 }
    let v = xyz / white
    return SIMD3(116 * f(v.y) - 16, 500 * (f(v.x) - f(v.y)), 200 * (f(v.y) - f(v.z)))
  }
  private func median(_ values: [Double]) -> Double {
    let sorted = values.sorted(), m = values.count / 2
    return values.count % 2 == 0 ? (sorted[m - 1] + sorted[m]) / 2 : sorted[m]
  }
  private func representative(_ output: PixelBuffer) -> SIMD3<Double> {
    SIMD3(median(output.pixels.map { Double($0.x) }), median(output.pixels.map { Double($0.y) }),
      median(output.pixels.map { Double($0.z) }))
  }
  @discardableResult private func assertFinalNeutral(_ input: PixelBuffer,
    calibration: FilmCalibration = .init(), adjustments: FrameAdjustments = .init(),
    lut: CubeLUT? = nil, file: StaticString = #filePath, line: UInt = #line
  ) throws -> FrameAdjustments {
    let lut = try lut ?? actualLUT()
    let original = try Pipeline.render(input, calibration: calibration, adjustments: adjustments, lut: lut)
    let originalLab = lab(representative(original))
    let result = try solve(input, calibration: calibration, adjustments: adjustments, lut: lut)
    let rendered = try Pipeline.render(input, calibration: calibration, adjustments: result, lut: lut)
    let measured = lab(representative(rendered))
    XCTAssertLessThanOrEqual(hypot(measured.y, measured.z), 1.00001, file: file, line: line)
    XCTAssertEqual(measured.x, originalLab.x, accuracy: 0.50001, file: file, line: line)
    XCTAssertEqual(result.timing.master, adjustments.timing.master, file: file, line: line)
    XCTAssertEqual(result.contrast, adjustments.contrast, file: file, line: line)
    XCTAssertEqual(try solve(input, calibration: calibration, adjustments: result, lut: lut), result,
      "A second pick must not drift an already acceptable result", file: file, line: line)
    return result
  }

  func testReal2383NeutralizesItsTintAcrossTonalRange() throws {
    let lut = try actualLUT()
    for cv: Double in [256, 320, 384, 470, 512, 600, 685, 768] {
      let input = patch([transmittance(SIMD3(repeating: cv))])
      let before = try Pipeline.render(input, calibration: .init(), adjustments: .init(), lut: lut)
      let tint = lab(representative(before))
      XCTAssertGreaterThan(hypot(tint.y, tint.z), 3)
      let result = try assertFinalNeutral(input, lut: lut)
      XCTAssertNotEqual(result.timing, TimingParameters(), "D3-neutral input needs LUT compensation at \(cv)")
      let rgb = representative(try Pipeline.render(input, calibration: .init(), adjustments: result, lut: lut))
      print("Final neutral CV \(cv): timing \(result.timing), RGB \(rgb), Lab \(lab(rgb))")
    }
  }

  func testCrossChannelLUTMatchesIndependentAnalyticInverseAndIntegerSearch() throws {
    let matrix = simd_double3x3(columns: (SIMD3(0.7, 0.04, 0), SIMD3(0.05, 0.72, 0.02), SIMD3(0, 0, 0.65)))
    let bias = SIMD3(0.05, 0.04, 0.09)
    let lut = try CubeLUT(size: 2, values: (0..<8).map { i in
      let v = matrix * SIMD3(Double(i & 1), Double((i >> 1) & 1), Double((i >> 2) & 1)) + bias
      return SIMD4(Float(v.x), Float(v.y), Float(v.z), 1)
    })
    let source = transmittance(SIMD3(360, 420, 520))
    let input = patch([source])
    let old = FrameAdjustments(timing: .init(master: 71, red: -25, green: 8, blue: 13),
      contrast: .init(master: 1.2, red: 0.85, green: 1.1, blue: 0.9))
    let result = try assertFinalNeutral(input, adjustments: old, lut: lut)
    let rawCV = SIMD3(-500 * log10(Double(source.x)), -500 * log10(Double(source.y)), -500 * log10(Double(source.z)))
    let effective = SIMD3(Double(old.contrast.master * old.contrast.red),
      Double(old.contrast.master * old.contrast.green), Double(old.contrast.master * old.contrast.blue))
    let oldRGB = SIMD3(Double(old.timing.red), Double(old.timing.green), Double(old.timing.blue))
    let initialD3 = SIMD3<Double>(repeating: 685) + effective *
      (rawCV + oldRGB + SIMD3(repeating: Double(old.timing.master) - 685))
    let originalRGB = matrix * (initialD3 / 1024) + bias
    let white = colorants * SIMD3<Double>(repeating: 1)
    let xyz = colorants * SIMD3(pow(originalRGB.x, gamma), pow(originalRGB.y, gamma), pow(originalRGB.z, gamma))
    let neutral = SIMD3<Double>(repeating: pow(xyz.y / white.y, 1 / gamma))
    let requiredD3 = matrix.inverse * (neutral - bias) * 1024
    let expectedTiming = oldRGB + (requiredD3 - initialD3) / effective
    let actual = SIMD3(Double(result.timing.red), Double(result.timing.green), Double(result.timing.blue))
    for c in 0..<3 { XCTAssertEqual(actual[c], expectedTiming[c], accuracy: 1.01) }
    let targetLab = lab(neutral)
    let bestLab = lab(matrix * ((initialD3 + (actual - oldRGB) * effective) / 1024) + bias)
    for r in -2...2 { for g in -2...2 { for b in -2...2 {
      let nearby = actual + SIMD3(Double(r), Double(g), Double(b))
      let candidate = lab(matrix * ((initialD3 + (nearby - oldRGB) * effective) / 1024) + bias)
      XCTAssertLessThanOrEqual(simd_length_squared(bestLab - targetLab),
        simd_length_squared(candidate - targetLab) + 1e-4)
    } } }
  }

  func testLEDCalibrationAndIndependentContrastsPreserveMasterAndLuminance() throws {
    var calibration = FilmCalibration()
    calibration.baseRGB = SIMD3(0.5, 0.375, 0.9375)
    calibration.gainRGB = SIMD3(1.5, 2, 0.8)
    calibration = try Pipeline.recalibrate(calibration, matrix: .ledLightSource)
    let old = FrameAdjustments(timing: .init(master: 141, red: 15, green: -20, blue: 8),
      contrast: .init(master: 0.8, red: 1.5, green: 0.7, blue: 1.2))
    let pixels = (-5...5).map { i in SIMD3<Float>(0.06 + Float(i) * 0.0002, 0.09 + Float(i) * 0.0003, 0.08 - Float(i) * 0.0001) }
    try assertFinalNeutral(patch(pixels), calibration: calibration, adjustments: old)
  }

  func testFinalMediansWithGrainDustAndEvenPopulation() throws {
    let center = SIMD3<Double>(350, 420, 530)
    var noisy = (-10...10).map { i in transmittance(center + SIMD3(Double(i), Double(i) * 2, Double(i) * 0.5)) }
    noisy += [SIMD3(repeating: 0.0001), SIMD3(repeating: 0.95)]
    try assertFinalNeutral(patch(noisy))
    try assertFinalNeutral(patch([transmittance(SIMD3(320, 430, 550)), transmittance(SIMD3(480, 470, 530))]))
  }

  func testAlreadyNeutralIdentityIsUnchanged() throws {
    let old = FrameAdjustments(timing: .init(master: 100, red: 7, green: 7, blue: 7))
    XCTAssertEqual(try solve(patch([SIMD3(repeating: 0.25)]), adjustments: old, lut: identityLUT()), old)
  }

  func testMinorityClippedPixelsExcludedAndMajorityFails() throws {
    let valid = transmittance(SIMD3(400, 470, 550))
    let clipped = [SIMD3<Float>(0, 0.3, 0.4), SIMD3<Float>(0.2, 1, 0.4)]
    let reference = try solve(patch([valid]))
    XCTAssertEqual(try solve(patch([valid, valid, valid] + clipped)), reference)
    for values in [clipped, [valid] + clipped, [valid, clipped[0]]] {
      XCTAssertThrowsError(try solve(patch(values))) { XCTAssertTrue($0.localizedDescription.contains("剪切")) }
    }
  }

  func testClippedPlateauCanRecoverWhenTargetIsReachable() throws {
    // Identity's red starts clipped; a nonzero seed must escape its zero derivative.
    let old = FrameAdjustments(timing: .init(red: -250))
    try assertFinalNeutral(patch([transmittance(SIMD3(200, 300, 350))]), adjustments: old, lut: identityLUT())
  }

  func testTintedConstantAndUnreachableTimingFailAtomically() throws {
    let constant = try CubeLUT(size: 2, values: Array(repeating: SIMD4<Float>(0.5, 0.3, 0.6, 1), count: 8))
    let old = FrameAdjustments(timing: .init(master: 47))
    XCTAssertThrowsError(try solve(patch([transmittance(SIMD3(400, 470, 550))]), adjustments: old, lut: constant))
    XCTAssertEqual(old.timing.master, 47)
    let bounds = FrameAdjustments(timing: .init(red: -512, green: 512, blue: 512))
    XCTAssertThrowsError(try solve(patch([transmittance(SIMD3(100, 868, 868))]), adjustments: bounds, lut: identityLUT()))
  }

  func testReal2383HighlightCannotReachNeutralAtOriginalBrightness() throws {
    let lut = try actualLUT()
    // Every trilinear output is a convex combination of table values: green can
    // never exceed this maximum, regardless of Timing or the chosen inverse seed.
    XCTAssertEqual(lut.values.map(\.y).max()!, 0.932183, accuracy: 1e-7)
    let input = patch([transmittance(SIMD3(repeating: 896))])
    let original = representative(try Pipeline.render(input, calibration: .init(), adjustments: .init(), lut: lut))
    let xyz = colorants * SIMD3(pow(original.x, gamma), pow(original.y, gamma), pow(original.z, gamma))
    let white = colorants * SIMD3<Double>(repeating: 1)
    XCTAssertGreaterThan(pow(xyz.y / white.y, 1 / gamma), Double(lut.values.map(\.y).max()!) + 0.005)
    XCTAssertThrowsError(try solve(input, lut: lut))
  }

  func testLegacyHighContrastRejectsInsufficientIntegerPrecision() throws {
    let input = patch([transmittance(SIMD3(670, 674, 680))])
    let old = FrameAdjustments(contrast: .init(master: 4, red: 4, green: 4, blue: 4))
    // Independent identity-LUT result: D3=(445,509,605) CV. Nearest exactly
    // neutral integer result is (509,509,509), but its L* change exceeds 0.5.
    let initial = lab(SIMD3(445, 509, 605) / 1024)
    let closestNeutral = lab(SIMD3(repeating: 509.0 / 1024))
    XCTAssertGreaterThan(abs(closestNeutral.x - initial.x), 0.7)
    XCTAssertThrowsError(try solve(input, adjustments: old, lut: identityLUT()))
  }

  func testMalformedInputCalibrationAndProfileAreRejected() throws {
    for input in [PixelBuffer(width: 0, height: 1, pixels: []),
      PixelBuffer(width: 2, height: 1, pixels: [SIMD4(repeating: 0.5)]),
      PixelBuffer(width: Int.max, height: 2, pixels: []),
      patch(Array(repeating: SIMD3(repeating: 0.5), count: 122)),
      patch([SIMD3(.nan, 0.3, 0.4)]), patch([SIMD3(0.2, .infinity, 0.4)]),
      patch([SIMD3(-0.1, 0.3, 0.4)]), patch([SIMD3(0.2, 0.3, 1.01)])] {
      XCTAssertThrowsError(try solve(input))
    }
    let valid = patch([SIMD3<Float>(0.2, 0.3, 0.4)])
    var calibration = FilmCalibration()
    calibration.gainRGB.y = 0
    XCTAssertThrowsError(try solve(valid, calibration: calibration))
    calibration.gainRGB.y = 1; calibration.filmBaseOffsetCV.x = .infinity
    XCTAssertThrowsError(try solve(valid, calibration: calibration))
    XCTAssertThrowsError(try solve(valid, adjustments: .init(contrast: .init(red: .nan))))
    XCTAssertThrowsError(try NeutralTiming.solve(valid, calibration: .init(), adjustments: .init(),
      lut: actualLUT(), p3Profile: Data()))
    let invalid = try CubeLUT(size: 2, values: Array(repeating: SIMD4<Float>(-0.1, 0.3, 0.6, 1), count: 8))
    XCTAssertThrowsError(try solve(valid, lut: invalid))
  }

  func testCancellationIsObserved() async throws {
    let input = patch([transmittance(SIMD3(400, 470, 550))]), lut = try actualLUT(), profile = try profile()
    let worker = Task.detached {
      withUnsafeCurrentTask { $0?.cancel() }
      return try NeutralTiming.solve(input, calibration: .init(), adjustments: .init(), lut: lut, p3Profile: profile)
    }
    do { _ = try await worker.value; XCTFail("Cancelled solve must throw") }
    catch { XCTAssertTrue(error is CancellationError) }
  }

  func testFinalParametersRenderConsistentlyOnMetalAndFourExportProfiles() throws {
    let lut = try actualLUT(), profile = try profile()
    let input = patch((0..<11).map { i in transmittance(SIMD3(420 + Double(i), 490 + Double(i), 560 + Double(i))) })
    let result = try assertFinalNeutral(input, lut: lut)
    let cpu = try Pipeline.render(input, calibration: .init(), adjustments: result, lut: lut)
    let gpu = try MetalPipeline().render(input, calibration: .init(), adjustments: result, lut: lut)
    for i in cpu.pixels.indices { for c in 0..<3 {
      XCTAssertEqual(cpu.pixels[i][c], gpu.pixels[i][c], accuracy: 2e-4)
    } }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FinalNeutral-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    for outputProfile in OutputColorProfile.allCases {
      let converter = try OutputColorConverter(p3Profile: profile, output: outputProfile)
      let samples = try converter.quantized(gpu)
      for compression in [TIFFCompression.none, .deflate] {
        let url = folder.appendingPathComponent("\(outputProfile.rawValue)-\(compression.rawValue).tif")
        try TIFFCodec.write(url: url, width: input.width, height: 1, profile: converter.outputProfile,
          compression: compression) { _ in samples }
        let readback = try TIFFCodec.read(url: url)
        XCTAssertEqual(readback.samples, samples)
        XCTAssertNotNil(try Data(contentsOf: url).range(of: converter.outputProfile))
      }
    }
  }

  func testRealTIFFOriginalNeighbourhoodFinalFit() throws {
    let source = root.appendingPathComponent("TEST/DSC07079.tiff")
    guard FileManager.default.fileExists(atPath: source.path) else { throw XCTSkip("Local reference TIFF unavailable") }
    let image = try TIFFCodec.readRegion(url: source, rect: PixelRect(x: 3500, y: 2300, width: 11, height: 11))
    let input = image.preview(maxDimension: 11)
    let lut = try actualLUT(), profile = try profile()
    let before = lab(representative(try Pipeline.render(input, calibration: .init(), adjustments: .init(), lut: lut)))
    let start = ContinuousClock.now
    let result = try NeutralTiming.solve(input, calibration: .init(), adjustments: .init(), lut: lut, p3Profile: profile)
    let duration = start.duration(to: .now)
    let after = lab(representative(try Pipeline.render(input, calibration: .init(), adjustments: result, lut: lut)))
    XCTAssertLessThanOrEqual(hypot(after.y, after.z), 1.00001)
    XCTAssertEqual(after.x, before.x, accuracy: 0.50001)
    print("Actual TIFF 11x11 solve only \(duration); Timing \(result.timing); Lab before \(before), after \(after)")
  }

  func testDensityStagesNeedNoLUTAndFinalRequiresOne() throws {
    let rgb = SIMD3<Float>(0.2, 0.3, 0.4)
    for stage in PipelineStage.allCases where stage != .final {
      XCTAssertNoThrow(try Pipeline.process(rgb, calibration: .init(), adjustments: .init(), stage: stage))
    }
    XCTAssertThrowsError(try Pipeline.process(rgb, calibration: .init(), adjustments: .init()))
  }
}
