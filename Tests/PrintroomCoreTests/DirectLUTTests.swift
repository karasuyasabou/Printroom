import Foundation
import XCTest
@testable import PrintroomCore

final class DirectLUTTests: XCTestCase {
  private var root: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
  }
  func testCPUAndMetalUseUnmodifiedLUTAfterD3() throws {
    let gpu = try MetalPipeline()
    let input = PixelBuffer(width: 4, height: 1, pixels: [
      SIMD4(0.01, 0.2, 0.08, 1), SIMD4(0.25, 0.09, 0.02, 1),
      SIMD4(repeating: Float(pow(10.0, -685.0 / 500))), SIMD4(1, 0, 0.5, 1)])
    for selection in CineonLogLUT.allCases {
      let lut = try CubeLUT(url: root.appendingPathComponent(selection.path))
      for contrast: Float in [0.25, 1, 2, 4] {
        let adjustments = FrameAdjustments(timing: .init(red: 27, green: -43, blue: 81),
          contrast: .init(master: contrast, red: 0.8, green: 1.1, blue: 1.4))
        let d3 = try Pipeline.render(input, calibration: .init(), adjustments: adjustments, stage: .d3)
        let cpu = try Pipeline.render(input, calibration: .init(), adjustments: adjustments, lut: lut)
        let metal = try gpu.render(input, calibration: .init(), adjustments: adjustments, lut: lut)
        for i in input.pixels.indices {
          let p = d3.pixels[i], expected = lut.sample(SIMD3(p.x, p.y, p.z))
          for c in 0..<3 {
            XCTAssertEqual(cpu.pixels[i][c], expected[c])
            XCTAssertEqual(metal.pixels[i][c], expected[c], accuracy: 2e-4)
          }
        }
      }
    }
  }

  func testRemovedNeutralPreservesOriginalBeforeSave() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    var project = RollProject()
    project.frames = [FrameRecord(filename: "missing.tif", adjustments: .init(timing: .init(red: 27)), isMissing: true)]
    let encoded = try JSONEncoder().encode(project)
    let original = Data(String(decoding: encoded, as: UTF8.self).replacingOccurrences(of: "kodak2383", with: "neutral").utf8)
    try original.write(to: folder.appendingPathComponent(".printroom.json"))
    let loaded = try ProjectStore.open(folder: folder)
    XCTAssertEqual(loaded.frames[0].adjustments.cineonLogLUT, .kodak2383)
    XCTAssertEqual(loaded.frames[0].adjustments.timing.red, 27)
    let date = try ProjectStore.save(loaded, folder: folder, expectedModification: loaded.loadedModificationDate)
    try ProjectStore.save(loaded, folder: folder, expectedModification: date)
    let backups = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
      .filter { $0.lastPathComponent.hasPrefix(".printroom-neutral-") }
    XCTAssertEqual(backups.count, 1)
    XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), original)
  }

  func testV5MigrationPreservesControlsAndBacksUpExactOriginal() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    var project = RollProject()
    project.algorithmVersion = "printroom-density-v5"
    project.frames = [FrameRecord(filename: "missing.tif", adjustments: .init(timing: .init(red: 25),
      contrast: .init(blue: 1.4), cineonLogLUT: .fujifilm3513DI), isMissing: true)]
    let original = try JSONEncoder().encode(project)
    try original.write(to: folder.appendingPathComponent(".printroom.json"))
    let migrated = try ProjectStore.open(folder: folder)
    XCTAssertEqual(migrated.algorithmVersion, algorithmVersion)
    XCTAssertEqual(migrated.frames, project.frames) // No automatic compensation of other rolls.
    XCTAssertEqual(migrated.calibration, project.calibration)
    let date = try ProjectStore.save(migrated, folder: folder, expectedModification: migrated.loadedModificationDate)
    try ProjectStore.save(migrated, folder: folder, expectedModification: date)
    let backups = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
      .filter { $0.lastPathComponent.hasPrefix(".printroom-density-v5-") }
    XCTAssertEqual(backups.count, 1)
    XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), original)
  }
}
