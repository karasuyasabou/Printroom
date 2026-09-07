import XCTest
@testable import PrintroomCore

final class MetalReuseTests: XCTestCase {
  private func input(count: Int = 513) -> PixelBuffer {
    var seed: UInt64 = 734912
    func random() -> Float {
      seed = seed &* 6_364_136_223_846_793_005 &+ 1
      return Float((seed >> 32) & 0xffff) / 65535
    }
    var pixels = (0..<count).map { _ in SIMD4<Float>(random(), random(), random(), 1) }
    pixels[0] = SIMD4(0, -0.1, 1.2, 1)
    return PixelBuffer(width: count, height: 1, pixels: pixels)
  }

  private func lut(inverted: Bool = false) throws -> CubeLUT {
    try CubeLUT(size: 2, values: (0..<8).map { i in
      let value = SIMD4<Float>(Float(i & 1), Float((i >> 1) & 1), Float((i >> 2) & 1), 1)
      return inverted ? SIMD4(1 - value.x, 1 - value.y, 1 - value.z, 1) : value
    })
  }

  private func assertAgreement(
    _ actual: PixelBuffer, input: PixelBuffer, calibration: FilmCalibration,
    adjustments: FrameAdjustments, lut: CubeLUT, stage: PipelineStage,
    file: StaticString = #filePath, line: UInt = #line
  ) throws {
    let expected = try Pipeline.render(
      input, calibration: calibration, adjustments: adjustments, lut: lut, stage: stage)
    var squareSum = 0.0
    for i in actual.pixels.indices {
      for channel in 0..<3 {
        let reference = expected.pixels[i][channel]
        let error = abs(actual.pixels[i][channel] - reference)
        let bound: Float = stage == .final ? 2e-4 : 2e-5 + 2e-5 * abs(reference)
        XCTAssertTrue(error.isFinite, file: file, line: line)
        XCTAssertLessThanOrEqual(error, bound, file: file, line: line)
        squareSum += Double(error) * Double(error)
      }
    }
    if stage == .final {
      XCTAssertLessThanOrEqual(sqrt(squareSum / Double(actual.pixels.count * 3)), 2e-5, file: file, line: line)
    }
  }

  func testWarmTimingContrastReusesBuffersAndD1WithoutChangingPixels() throws {
    let gpu = try MetalPipeline()
    let session = gpu.makeSession()
    let source = input(), identity = UUID(), table = try lut()
    var calibration = FilmCalibration()
    calibration.gainRGB = SIMD3(3.75, 1.875, 1.25)
    calibration.matrix = .ledLightSource
    _ = try session.render(source, calibration: calibration, adjustments: .init(), lut: table, inputIdentity: identity)
    let warm = session.statistics
    for adjustment in [
      FrameAdjustments(timing: .init(master: 31, red: -17, green: 23, blue: 8)),
      FrameAdjustments(timing: .init(master: -512, red: 512, green: -512, blue: 512),
        contrast: .init(master: 4, red: 4, green: 0.25, blue: 4)),
      FrameAdjustments(contrast: .init(master: 1.25, red: 0.75, green: 1.125, blue: 0.875)),
    ] {
      let output = try session.render(source, calibration: calibration, adjustments: adjustment, lut: table, inputIdentity: identity)
      let cold = try gpu.render(source, calibration: calibration, adjustments: adjustment, lut: table)
      XCTAssertEqual(output.pixels, cold.pixels, "Splitting at D1 preserves the original Metal Float32 result")
      try assertAgreement(output, input: source, calibration: calibration, adjustments: adjustment, lut: table, stage: .final)
    }
    let result = session.statistics
    XCTAssertEqual(result.bufferAllocations, warm.bufferAllocations)
    XCTAssertEqual(result.sourceUploads, 1)
    XCTAssertEqual(result.lutUploads, 1)
    XCTAssertEqual(result.densityPasses, 1)
    XCTAssertEqual(result.densityCacheHits, 3)
  }

  func testStageCalibrationLUTAndSourceInvalidation() throws {
    let session = try MetalPipeline().makeSession()
    var source = input(), identity = UUID(), table = try lut()
    var calibration = FilmCalibration()
    let adjustments = FrameAdjustments(timing: .init(master: 19), contrast: .init(master: 1.2))
    func check(_ stage: PipelineStage = .final) throws {
      let output = try session.render(source, calibration: calibration, adjustments: adjustments, lut: table, stage: stage, inputIdentity: identity)
      try assertAgreement(output, input: source, calibration: calibration, adjustments: adjustments, lut: table, stage: stage)
    }
    try check()
    for stage in PipelineStage.allCases.reversed() { try check(stage) }
    XCTAssertEqual(session.statistics.densityPasses, 1)
    calibration.filmBaseOffsetCV = SIMD3(32.5, -41, 13)
    try check()
    XCTAssertEqual(session.statistics.densityPasses, 1, "Offset belongs to the uncached tail")
    calibration.gainRGB = SIMD3(3.75, 1.875, 1.25)
    try check()
    XCTAssertEqual(session.statistics.densityPasses, 2)
    calibration.matrix = .ledLightSource
    for stage in PipelineStage.allCases { try check(stage) }
    XCTAssertEqual(session.statistics.densityPasses, 3)
    table = try lut(inverted: true)
    try check()
    XCTAssertEqual(session.statistics.lutUploads, 2)
    XCTAssertEqual(session.statistics.densityPasses, 3)
    source.pixels[1] = SIMD4(0.25, 0.5, 0.75, 1)
    identity = UUID()
    try check()
    XCTAssertEqual(session.statistics.sourceUploads, 2)
    XCTAssertEqual(session.statistics.densityPasses, 4)
    source = input(count: 127) // Dimensions participate even with the same identity.
    try check()
    XCTAssertEqual(session.statistics.sourceUploads, 3)
    XCTAssertEqual(session.statistics.densityPasses, 5)
  }

  func testNilIdentityNeverReusesSamplesOrD1AndRejectsInvalidInput() throws {
    let session = try MetalPipeline().makeSession()
    var source = input()
    let table = try lut(), calibration = FilmCalibration()
    _ = try session.render(source, calibration: calibration, adjustments: .init(), lut: table, inputIdentity: UUID())
    let allocations = session.statistics.bufferAllocations
    for value: Float in [0.3, 0.6] {
      source.pixels[1] = SIMD4(value, value, value, 1)
      let output = try session.render(source, calibration: calibration, adjustments: .init(), lut: table)
      try assertAgreement(output, input: source, calibration: calibration, adjustments: .init(), lut: table, stage: .final)
    }
    XCTAssertEqual(session.statistics.sourceUploads, 3)
    XCTAssertEqual(session.statistics.densityPasses, 1)
    XCTAssertEqual(session.statistics.bufferAllocations, allocations)
    source.pixels[0].x = .nan
    XCTAssertThrowsError(try session.render(source, calibration: calibration, adjustments: .init(), lut: table))
    XCTAssertThrowsError(try session.render(PixelBuffer(width: -1, height: -513, pixels: input().pixels), calibration: calibration, adjustments: .init(), lut: table))
  }

  func testActualLUTWarmPathAcrossEveryStageAndAdjustmentExtremes() throws {
    let gpu = try MetalPipeline(), session = gpu.makeSession()
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let table = try CubeLUT(url: root.appendingPathComponent("LUT/DCI-P3 Kodak 2383 D65.cube"))
    let source = input(count: 4099), identity = UUID()
    for matrix in PrintDensityMatrix.allCases {
      var calibration = FilmCalibration()
      calibration.matrix = matrix
      calibration.gainRGB = SIMD3(3.75, 1.875, 1.25)
      calibration.filmBaseOffsetCV = SIMD3(32.53063, 31.406183, 38.483963)
      for adjustments in [
        FrameAdjustments(),
        FrameAdjustments(timing: .init(master: 37, red: -12, green: 23, blue: 8),
          contrast: .init(master: 1.13, red: 0.8, green: 1.2, blue: 1.5)),
        FrameAdjustments(timing: .init(master: -512, red: 512, green: -512, blue: 512),
          contrast: .init(master: 4, red: 4, green: 0.25, blue: 4)),
      ] {
        for stage in PipelineStage.allCases {
          let output = try session.render(source, calibration: calibration, adjustments: adjustments,
            lut: table, stage: stage, inputIdentity: identity)
          let cold = try gpu.render(source, calibration: calibration, adjustments: adjustments, lut: table, stage: stage)
          XCTAssertEqual(output.pixels, cold.pixels, "Cached Float32 split changed \(stage) / \(matrix)")
          try assertAgreement(output, input: source, calibration: calibration,
            adjustments: adjustments, lut: table, stage: stage)
        }
      }
    }
    XCTAssertEqual(session.statistics.sourceUploads, 1)
    XCTAssertEqual(session.statistics.densityPasses, 2)
    XCTAssertEqual(session.statistics.bufferAllocations, 4)
  }

  func testLargeRegionBuffersAreReleasedAfterRendering() throws {
    let session = try MetalPipeline().makeSession(), table = try lut()
    _ = try session.render(input(), calibration: .init(), adjustments: .init(), lut: table, inputIdentity: UUID())
    XCTAssertGreaterThan(session.statistics.retainedPixelBytes, 0)
    let count = 1600 * 1600 + 1
    let source = PixelBuffer(width: count, height: 1,
      pixels: Array(repeating: SIMD4<Float>(0.25, 0.5, 0.75, 1), count: count))
    let output = try session.render(source, calibration: .init(), adjustments: .init(), lut: table, stage: .l0)
    XCTAssertEqual(output.pixels.first, source.pixels.first)
    XCTAssertEqual(output.pixels.last, source.pixels.last)
    XCTAssertEqual(session.statistics.retainedPixelBytes, 0)
    // Returning to a preview rebuilds its source/D1 instead of reusing evicted buffers.
    _ = try session.render(input(), calibration: .init(), adjustments: .init(), lut: table, inputIdentity: UUID())
    XCTAssertEqual(session.statistics.densityPasses, 2)
    XCTAssertEqual(session.statistics.retainedPixelBytes, 513 * 16 * 3)
  }

  func testConcurrentSessionsAndSharedSessionDoNotCrossContaminate() async throws {
    let gpu = try MetalPipeline()
    let sessions = [gpu.makeSession(), gpu.makeSession()]
    let source = input(), table = try lut()
    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<12 {
        let session = sessions[index % sessions.count]
        group.addTask {
          var calibration = FilmCalibration()
          calibration.matrix = index.isMultiple(of: 3) ? .identity : .ledLightSource
          calibration.gainRGB = SIMD3(repeating: 1 + Float(index) / 8)
          let adjustments = FrameAdjustments(timing: .init(master: index * 7 - 30))
          let identity = UUID()
          for _ in 0..<3 {
            let output = try session.render(source, calibration: calibration, adjustments: adjustments, lut: table, inputIdentity: identity)
            let reference = try Pipeline.render(source, calibration: calibration, adjustments: adjustments, lut: table)
            for i in output.pixels.indices {
              for c in 0..<3 {
                let error = abs(output.pixels[i][c] - reference.pixels[i][c])
                XCTAssertTrue(error.isFinite)
                XCTAssertLessThanOrEqual(error, 2e-4)
              }
            }
          }
        }
      }
      try await group.waitForAll()
    }
    for session in sessions {
      XCTAssertEqual(session.statistics.lutUploads, 1)
      XCTAssertEqual(session.statistics.bufferAllocations, 4)
    }
  }
}
