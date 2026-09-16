import Foundation
import XCTest
@testable import PrintroomCore

final class RetiredPaperLUTTests: XCTestCase {
  func testRetiredSelectionsBecomeKodakAndOriginalSettingsAreBackedUpOnce() throws {
    XCTAssertEqual(Set(CineonLogLUT.allCases), [.kodak2383, .fujifilm3513DI])
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let retired = ["divereEktacolorEdge", "divereEnduraPremier", "diverePortraEndura",
      "divereSupraEndura", "divereUltraEndura"]
    var project = RollProject()
    project.frames = retired.enumerated().map { index, _ in
      FrameRecord(filename: "missing-\(index).tiff", adjustments: .init(timing: .init(red: 17),
        contrast: .init(blue: 1.2)), isMissing: true)
    }
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any])
    var frames = try XCTUnwrap(object["frames"] as? [[String: Any]])
    for index in frames.indices {
      var adjustments = try XCTUnwrap(frames[index]["adjustments"] as? [String: Any])
      adjustments["cineonLogLUT"] = retired[index]
      frames[index]["adjustments"] = adjustments
    }
    object["frames"] = frames
    let original = try JSONSerialization.data(withJSONObject: object)
    let url = folder.appendingPathComponent(".printroom.json")
    try original.write(to: url)
    let loaded = try ProjectStore.open(folder: folder)
    XCTAssertEqual(loaded.frames, project.frames)
    XCTAssertEqual(try Data(contentsOf: url), original)
    let date = try ProjectStore.save(loaded, folder: folder, expectedModification: loaded.loadedModificationDate)
    try ProjectStore.save(loaded, folder: folder, expectedModification: date)
    let backups = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
      .filter { $0.lastPathComponent.hasPrefix(".printroom-retired-paper-luts-") }
    XCTAssertEqual(backups.count, 1)
    XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), original)
    XCTAssertEqual(try ProjectStore.open(folder: folder).frames, loaded.frames)
  }
}
