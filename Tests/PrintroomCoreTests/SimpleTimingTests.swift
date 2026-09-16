import XCTest
@testable import PrintroomCore

final class SimpleTimingTests: XCTestCase {
  private func effective(_ t: TimingParameters) -> [Int] {
    [t.red + t.master, t.green + t.master, t.blue + t.master]
  }
  func testActualLUTDirectionsAtMidtones() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let lut = try CubeLUT(url: root.appendingPathComponent("LUT/DCI-P3 Kodak 2383 D65.cube"))
    let input = SIMD3<Float>(repeating: pow(10, -512.0 / 500))
    func output(_ axis: SimpleTimingAxis?, _ steps: Int = 0) throws -> SIMD3<Float> {
      let t = axis?.moving(steps, in: TimingParameters()) ?? TimingParameters()
      return try Pipeline.process(input, calibration: .init(), adjustments: .init(timing: t), lut: lut)
    }
    let base = try output(nil), exposure = try output(.exposure, 10)
    let warm = try output(.temperature, 10), magenta = try output(.tint, 10)
    XCTAssertTrue(exposure.x > base.x && exposure.y > base.y && exposure.z > base.z)
    XCTAssertGreaterThan(warm.x - warm.z, base.x - base.z)
    XCTAssertGreaterThan((magenta.x + magenta.z) / 2 - magenta.y, (base.x + base.z) / 2 - base.y)
  }
  func testBasisAndInverse() {
    let t = TimingParameters(master: 30, red: 15, green: -6, blue: -9)
    XCTAssertEqual(SimpleTimingAxis.exposure.value(in: t), 30)
    XCTAssertEqual(SimpleTimingAxis.temperature.value(in: t), 12)
    XCTAssertEqual(SimpleTimingAxis.tint.value(in: t), 3)
    XCTAssertEqual(effective(SimpleTimingAxis.exposure.moving(10, in: t)), [55,34,31])
    XCTAssertEqual(effective(SimpleTimingAxis.temperature.moving(10, in: t)), [55,24,11])
    XCTAssertEqual(effective(SimpleTimingAxis.tint.moving(10, in: t)), [55,4,31])
  }
  func testFractionalCoordinatesAndNoDrift() {
    let t = TimingParameters(master: 12, red: 1, green: 0, blue: 0)
    for axis in SimpleTimingAxis.allCases {
      XCTAssertEqual(axis.setting(axis.value(in: t), in: t), t)
      let next = axis.moving(10, in: t)
      for other in SimpleTimingAxis.allCases where other != axis {
        XCTAssertEqual(other.value(in: next), other.value(in: t), accuracy: 1e-12)
      }
      XCTAssertEqual(axis.moving(-10, in: next), t)
      XCTAssertEqual(axis.setting(.nan, in: t), t)
    }
  }
  func testBoundsPreserveAxisAndLegalLegacyStorage() throws {
    for m in [-512, 0, 512] {
      for r in [-512, -1, 512] {
        for g in [-512, 0, 512] {
          for b in [-512, 1, 512] {
            let t = TimingParameters(master: m, red: r, green: g, blue: b)
            for axis in SimpleTimingAxis.allCases {
              for step in [-4096, -10, 10, 4096] {
                let next = axis.moving(step, in: t)
                try Pipeline.validate(FrameAdjustments(timing: next))
                for other in SimpleTimingAxis.allCases where other != axis {
                  XCTAssertEqual(other.value(in: next), other.value(in: t), accuracy: 1e-10)
                }
                let movement = axis.value(in: next) - axis.value(in: t)
                XCTAssertGreaterThanOrEqual(movement * Double(step), 0)
                XCTAssertLessThanOrEqual(abs(movement), Double(abs(step)) + 1e-10)
                if abs(movement) < Double(abs(step)) {
                  XCTAssertEqual(axis.moving(step > 0 ? 1 : -1, in: next), next)
                }
              }
            }
          }
        }
      }
    }
  }
}
