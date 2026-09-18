import Foundation
import XCTest

@testable import PrintroomCore

final class PivotMigrationTests: XCTestCase {
  private func folder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("printroom-pivot-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }

  private func legacyData(_ project: RollProject, schema: Int) throws -> Data {
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any])
    json["algorithmVersion"] = "printroom-density-v1"
    json["schemaVersion"] = schema
    var legacyCalibration = json["calibration"] as! [String: Any]
    for key in ["cmosMatrix", "sampledCMOSMatrix", "sampledDensityMatrix"] { legacyCalibration.removeValue(forKey: key) }
    json["calibration"] = legacyCalibration
    var legacyFrames = json["frames"] as! [[String: Any]]
    for index in legacyFrames.indices { legacyFrames[index].removeValue(forKey: "crop") }
    json["frames"] = legacyFrames
    if schema == 1 {
      var frames = json["frames"] as! [[String: Any]]
      for index in frames.indices { frames[index].removeValue(forKey: "orientation") }
      json["frames"] = frames
      var settings = json["exportSettings"] as! [String: Any]
      settings["profileSHA256"] = ProjectAssetIdentity.expectedICCSHA256
      settings.removeValue(forKey: "profile")
      settings.removeValue(forKey: "compression")
      json["exportSettings"] = settings
    }
    return try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
  }

  private func backups(in root: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
      .filter { $0.lastPathComponent.hasPrefix(".printroom-density-v1-") }
  }

  func testBothLegacySchemasMigrateAndBackUpExactOriginalOnlyOnFirstSave() throws {
    for schema in [1, 2] {
      let root = try folder()
      var project = RollProject()
      project.exportSettings = .init(profile: .displayP3, compression: .none) // Legacy output.
      project.frames = [FrameRecord(filename: "missing.tif", adjustments: .init(
        timing: .init(master: 135, red: -32), contrast: .init(master: 1.6, blue: 0.7)), isMissing: true)]
      project.calibration.matrix = .ledLightSource
      project.calibration.sampledDensityMatrix = .ledLightSource
      let original = try legacyData(project, schema: schema)
      let url = root.appendingPathComponent(ProjectStore.filename)
      try original.write(to: url)
      let migrated = try ProjectStore.open(folder: root)
      XCTAssertEqual(migrated.algorithmVersion, "printroom-density-v6")
      XCTAssertEqual(migrated.schemaVersion, RollProject.currentSchemaVersion)
      XCTAssertEqual(migrated.id, project.id)
      XCTAssertEqual(migrated.frames, project.frames)
      var expectedCalibration = project.calibration
      expectedCalibration.cmosMatrix = .ledLightSource
      expectedCalibration.sampledCMOSMatrix = .ledLightSource
      XCTAssertEqual(migrated.calibration, expectedCalibration)
      XCTAssertEqual(migrated.exportSettings, project.exportSettings)
      XCTAssertEqual(try Data(contentsOf: url), original)
      XCTAssertTrue(try backups(in: root).isEmpty)
      let savedDate = try ProjectStore.save(migrated, folder: root, expectedModification: migrated.loadedModificationDate)
      let backup = try XCTUnwrap(backups(in: root).first)
      XCTAssertEqual(try Data(contentsOf: backup), original)
      let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
      XCTAssertEqual(saved["algorithmVersion"] as? String, "printroom-density-v6")
      XCTAssertEqual(saved["schemaVersion"] as? Int, RollProject.currentSchemaVersion)
      try ProjectStore.save(migrated, folder: root, expectedModification: savedDate)
      XCTAssertEqual(try backups(in: root), [backup])
      XCTAssertEqual(try Data(contentsOf: backup), original)
    }
  }

  func testConflictDoesNotBackUpOrOverwriteLegacySettings() throws {
    let root = try folder()
    let original = try legacyData(RollProject(), schema: 2)
    let url = root.appendingPathComponent(ProjectStore.filename)
    try original.write(to: url)
    let migrated = try ProjectStore.open(folder: root)
    XCTAssertThrowsError(try ProjectStore.save(migrated, folder: root, expectedModification: nil))
    var other = migrated
    other.id = UUID()
    XCTAssertThrowsError(try ProjectStore.save(other, folder: root, expectedModification: migrated.loadedModificationDate))
    XCTAssertTrue(try backups(in: root).isEmpty)
    XCTAssertEqual(try Data(contentsOf: url), original)
  }

  func testUnknownAlgorithmAndOldParameterSnapshotAreRejected() throws {
    var project = RollProject()
    project.frames = [FrameRecord(filename: "test.tif")]
    let frame = project.frames[0]
    let snapshot = ParameterSnapshot(frame: frame)
    XCTAssertEqual(snapshot.pivotCV, 685)
    XCTAssertEqual(snapshot.algorithmVersion, "printroom-density-v6")
    XCTAssertNoThrow(try snapshot.applying(to: project, targets: [frame.id]))
    for (version, pivot) in [("printroom-density-v1", 470), ("printroom-density-v6", 470)] {
      let old = ParameterSnapshot(sourceID: frame.id, sourceName: frame.filename,
        adjustments: frame.adjustments, algorithmVersion: version, pivotCV: pivot)
      XCTAssertThrowsError(try old.applying(to: project, targets: [frame.id]))
    }
    project.algorithmVersion = "printroom-density-v999"
    XCTAssertThrowsError(try ProjectStore.decodeSnapshot(JSONEncoder().encode(project))) { error in
      XCTAssertEqual(error as? ProjectStoreError, .incompatibleAlgorithm("printroom-density-v999"))
    }
  }
}
