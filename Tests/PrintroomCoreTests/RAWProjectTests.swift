import Foundation
import XCTest
@testable import PrintroomCore

final class RAWProjectTests: XCTestCase {
  private func folder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("printroom-raw-project-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }

  private func identity() -> RAWProcessingIdentity {
    RAWProcessingIdentity(sourceRevision: String(repeating: "a", count: 64), adobeVersion: "18.1.1",
      libRawVersion: "0.22.1", strategyVersion: "adobe-linear-camera-rgb-v1",
      proxySamplingVersion: "nearest-original-v1")
  }

  func testDiscoveryUsesOriginalRAWAndNeverTraversesCacheOrPreparesSources() throws {
    let root = try folder()
    // Deliberately invalid image bytes: discovery must inspect file attributes only.
    for name in ["Scan10.ARW", "Scan2.tif", "Scan1.arw", "Scan3.DNG", ".prepared.dng", ".partial.tiff"] {
      try Data([1, 2, 3]).write(to: root.appendingPathComponent(name))
    }
    let cache = root.appendingPathComponent(".printroom-cache")
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    try Data([0]).write(to: cache.appendingPathComponent("proxy.tiff"))
    let project = try ProjectStore.open(folder: root, preferredFile: root.appendingPathComponent("Scan10.ARW"))
    XCTAssertEqual(project.frames.map(\.filename), ["Scan1.arw", "Scan2.tif", "Scan3.DNG", "Scan10.ARW"])
    XCTAssertTrue(project.frames.allSatisfy { !$0.isMissing && $0.rawProcessing == nil })
    XCTAssertEqual(project.lastActiveFrameID, project.frames[3].id)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(ProjectStore.filename).path))
  }

  func testMultiBrandSourcesSaveReopenAndRetainMissingFrameEdits() throws {
    let root = try folder()
    let names = ["01.CR3", "02.NEF", "03.RAF", "04.ORF", "05.RW2", "06.PEF",
      "07.RWL", "08.SRW", "09.3FR", "10.IIQ", "11.X3F", "12.DNG"]
    for name in names + ["ignore.jpg", "ignore.png", "ignore.mov", "ignore.txt"] {
      try Data([1, 2, 3]).write(to: root.appendingPathComponent(name))
    }
    var project = try ProjectStore.open(folder: root, preferredFile: root.appendingPathComponent("03.RAF"))
    XCTAssertEqual(project.frames.map(\.filename), names)
    XCTAssertEqual(project.lastActiveFrameID, project.frames[2].id)
    for index in project.frames.indices {
      project.frames[index].rawProcessing = identity()
      project.frames[index].adjustments.timing.red = index + 1
      project.frames[index].orientation = .rotate90CW
    }
    try ProjectStore.save(project, folder: root, expectedModification: nil)
    let reopened = try ProjectStore.open(folder: root)
    XCTAssertEqual(reopened.frames, project.frames)
    XCTAssertEqual(reopened.schemaVersion, project.schemaVersion)
    try FileManager.default.removeItem(at: root.appendingPathComponent("02.NEF"))
    let missing = try ProjectStore.open(folder: root)
    XCTAssertTrue(missing.frames[1].isMissing)
    XCTAssertEqual(missing.frames[1].id, project.frames[1].id)
    XCTAssertEqual(missing.frames[1].adjustments, project.frames[1].adjustments)
    XCTAssertEqual(missing.frames[1].rawProcessing, project.frames[1].rawProcessing)
    try Data([1, 2, 3, 4]).write(to: root.appendingPathComponent("02.NEF"))
    let replaced = try ProjectStore.open(folder: root)
    XCTAssertFalse(replaced.frames[1].isMissing)
    XCTAssertNil(replaced.frames[1].rawProcessing)
    XCTAssertEqual(replaced.frames[1].id, project.frames[1].id)
    XCTAssertEqual(replaced.frames[1].adjustments, project.frames[1].adjustments)
  }

  func testRAWIdentityAndEditsSurviveMoveMissingAndSourceReplacement() throws {
    let container = try folder()
    let root = container.appendingPathComponent("original")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("image.ARW")
    try Data([1, 2, 3]).write(to: source)
    var project = try ProjectStore.open(folder: root)
    project.frames[0].rawProcessing = identity()
    project.frames[0].adjustments.timing.red = 19
    project.frames[0].orientation = .rotate90CW
    let originalFrame = project.frames[0]
    try ProjectStore.save(project, folder: root, expectedModification: nil)
    let moved = container.appendingPathComponent("moved")
    try FileManager.default.moveItem(at: root, to: moved)
    let reopened = try ProjectStore.open(folder: moved)
    XCTAssertEqual(reopened.frames[0], originalFrame)
    let movedSource = moved.appendingPathComponent("image.ARW")
    let originalBytes = try Data(contentsOf: movedSource)
    try FileManager.default.removeItem(at: movedSource)
    let missing = try ProjectStore.open(folder: moved)
    XCTAssertTrue(missing.frames[0].isMissing)
    XCTAssertEqual(missing.frames[0].id, originalFrame.id)
    XCTAssertEqual(missing.frames[0].rawProcessing, originalFrame.rawProcessing)
    try (originalBytes + Data([4])).write(to: movedSource)
    let replaced = try ProjectStore.open(folder: moved)
    XCTAssertEqual(replaced.frames[0].id, originalFrame.id)
    XCTAssertEqual(replaced.frames[0].adjustments, originalFrame.adjustments)
    XCTAssertEqual(replaced.frames[0].orientation, originalFrame.orientation)
    XCTAssertNil(replaced.frames[0].rawProcessing)
  }

  func testSchemaFourTIFFMigrationBacksUpExactBytesAndDefaultsRAWIdentity() throws {
    let root = try folder()
    try Data([1]).write(to: root.appendingPathComponent("old.tif"))
    let project = try ProjectStore.open(folder: root)
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any])
    json["schemaVersion"] = 4
    let original = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    let url = root.appendingPathComponent(ProjectStore.filename)
    try original.write(to: url)
    let migrated = try ProjectStore.open(folder: root)
    XCTAssertEqual(migrated.schemaVersion, RollProject.currentSchemaVersion)
    XCTAssertEqual(migrated.frames, project.frames)
    XCTAssertNil(migrated.frames[0].rawProcessing)
    XCTAssertEqual(try Data(contentsOf: url), original)
    try ProjectStore.save(migrated, folder: root, expectedModification: migrated.loadedModificationDate)
    let backups = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
      .filter { $0.lastPathComponent.hasPrefix(".printroom-schema4-") }
    XCTAssertEqual(backups.count, 1)
    XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), original)
    let reopened = try ProjectStore.open(folder: root)
    try ProjectStore.save(reopened, folder: root, expectedModification: reopened.loadedModificationDate)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path)
      .filter { $0.hasPrefix(".printroom-schema4-") }.count, 1)
  }

  func testTIFFCannotCarryRAWProcessingIdentity() throws {
    let root = try folder()
    try Data([1]).write(to: root.appendingPathComponent("old.tif"))
    var project = try ProjectStore.open(folder: root)
    project.frames[0].rawProcessing = identity()
    XCTAssertThrowsError(try ProjectStore.save(project, folder: root, expectedModification: nil))
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(ProjectStore.filename).path))
  }
}
