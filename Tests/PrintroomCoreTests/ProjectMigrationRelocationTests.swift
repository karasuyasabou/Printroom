import Foundation
import XCTest

@testable import PrintroomCore

final class ProjectMigrationRelocationTests: XCTestCase {
  private func folder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("printroom-schema2-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }

  @discardableResult
  private func source(_ filename: String, in folder: URL) throws -> URL {
    let url = folder.appendingPathComponent(filename)
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let profile = try Data(contentsOf: repository.appendingPathComponent("ICC/DCIP3_D65.icc"))
    try TIFFCodec.write(url: url, width: 4, height: 4, profile: profile) { rows in
      [UInt16](repeating: 32000, count: rows.count * 4 * 3)
    }
    return url
  }

  private func legacyData(_ project: RollProject) throws -> Data {
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any])
    object["schemaVersion"] = 1
    var calibration = object["calibration"] as! [String: Any]
    for key in ["cmosMatrix", "sampledDensityMatrix", "sampledCMOSMatrix"] { calibration.removeValue(forKey: key) }
    object["calibration"] = calibration
    var frames = object["frames"] as! [[String: Any]]
    for index in frames.indices {
      frames[index].removeValue(forKey: "orientation")
      frames[index].removeValue(forKey: "crop")
    }
    object["frames"] = frames
    var settings = object["exportSettings"] as! [String: Any]
    settings.removeValue(forKey: "profile")
    settings.removeValue(forKey: "compression")
    object["exportSettings"] = settings
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }

  func testLegacyMigrationPreservesIdentityAppearanceCalibrationAndWritesOnlyOnSave() throws {
    let root = try folder()
    try source("old.tif", in: root)
    var project = try ProjectStore.open(folder: root)
    project.frames[0].adjustments = FrameAdjustments(timing: .init(master: 12, red: -11), contrast: .init(blue: 1.25))
    project.calibration.matrix = .ledLightSource
    project.calibration.sampledDensityMatrix = .ledLightSource
    let original = try legacyData(project)
    let url = root.appendingPathComponent(ProjectStore.filename)
    try original.write(to: url)
    let migrated = try ProjectStore.open(folder: root)
    XCTAssertEqual(migrated.schemaVersion, RollProject.currentSchemaVersion)
    XCTAssertEqual(migrated.algorithmVersion, project.algorithmVersion)
    XCTAssertEqual(migrated.id, project.id)
    XCTAssertEqual(migrated.frames, project.frames)
    XCTAssertEqual(migrated.calibration, project.calibration)
    XCTAssertEqual(migrated.exportSettings.profile, .p3)
    XCTAssertEqual(migrated.exportSettings.compression, .none)
    XCTAssertEqual(migrated.exportSettings.profileSHA256, ProjectAssetIdentity.expectedICCSHA256)
    XCTAssertEqual(try Data(contentsOf: url), original)
    try ProjectStore.save(migrated, folder: root, expectedModification: migrated.loadedModificationDate)
    let reopened = try ProjectStore.open(folder: root)
    XCTAssertEqual(reopened.frames, migrated.frames)
    XCTAssertEqual(reopened.schemaVersion, RollProject.currentSchemaVersion)
    let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    XCTAssertEqual(saved["schemaVersion"] as? Int, RollProject.currentSchemaVersion)
    XCTAssertNotNil((saved["frames"] as? [[String: Any]])?[0]["orientation"])
  }

  func testSchemaTwoPreservesEveryDirectionAndEveryOutputSettingAcrossReopen() throws {
    for profile in OutputColorProfile.allCases {
      for compression in TIFFCompression.allCases {
        let root = try folder()
        for value in FrameOrientation.allCases { try source("\(value.rawValue).tif", in: root) }
        var project = try ProjectStore.open(folder: root)
        for index in project.frames.indices { project.frames[index].orientation = FrameOrientation.allCases[index] }
        project.exportSettings = ProjectExportSettings(profile: profile, compression: compression)
        try ProjectStore.save(project, folder: root, expectedModification: nil)
        let loaded = try ProjectStore.open(folder: root)
        XCTAssertEqual(loaded.frames, project.frames)
        XCTAssertEqual(loaded.exportSettings, project.exportSettings)
        XCTAssertEqual(loaded.exportSettings.profileSHA256, profile.profileSHA256)
      }
    }
  }

  func testChangingProfileSynchronizesFingerprintAndInvalidHashIsRejected() throws {
    var project = RollProject()
    project.exportSettings.profile = .proPhoto
    XCTAssertEqual(project.exportSettings.profileSHA256, OutputColorProfile.proPhoto.profileSHA256)
    project.exportSettings.profileSHA256 = OutputColorProfile.sRGB.profileSHA256
    XCTAssertThrowsError(try ProjectStore.decodeSnapshot(JSONEncoder().encode(project)))
  }

  func testCurrentSchemaMissingOrUnknownDirectionAndOutputFieldsAreRejected() throws {
    var project = RollProject()
    project.frames = [FrameRecord(filename: "test.tif")]
    let original = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any])
    for field in ["orientation", "profile", "compression"] {
      var json = original
      if field == "orientation" {
        var frames = json["frames"] as! [[String: Any]]
        frames[0].removeValue(forKey: field)
        json["frames"] = frames
      } else {
        var settings = json["exportSettings"] as! [String: Any]
        settings.removeValue(forKey: field)
        json["exportSettings"] = settings
      }
      XCTAssertThrowsError(try ProjectStore.decodeSnapshot(JSONSerialization.data(withJSONObject: json)))
    }
    var frames = original["frames"] as! [[String: Any]]
    frames[0]["orientation"] = 9
    var invalid = original
    invalid["frames"] = frames
    XCTAssertThrowsError(try ProjectStore.decodeSnapshot(JSONSerialization.data(withJSONObject: invalid)))
    invalid = original
    invalid["schemaVersion"] = 1
    XCTAssertThrowsError(try ProjectStore.decodeSnapshot(JSONSerialization.data(withJSONObject: invalid)))
  }

  func testCopyApplyContinuesToLeaveAllDirectionsUntouched() throws {
    var project = RollProject()
    project.frames = FrameOrientation.allCases.map {
      FrameRecord(filename: "\($0.rawValue).tif", adjustments: .init(timing: .init(red: $0.rawValue)), orientation: $0)
    }
    let before = project.frames.map(\.orientation)
    let applied = try ParameterSnapshot(frame: project.frames[0]).applying(to: project, targets: Set(project.frames.map(\.id)))
    XCTAssertEqual(applied.frames.map(\.orientation), before)
    XCTAssertTrue(applied.frames.allSatisfy { $0.adjustments == project.frames[0].adjustments })
  }

  func testRelocationAbsorbsDefaultDiscoveredFrameAndPreservesEditedStableIdentity() throws {
    let root = try folder()
    let old = try source("old.tif", in: root)
    var project = try ProjectStore.open(folder: root)
    project.frames[0].adjustments.timing.red = 77
    project.frames[0].orientation = .rotate90CW
    project.frames[0].crop = FrameCrop(aspect: .square, width: 0.5)
    let preserved = project.frames[0]
    try ProjectStore.save(project, folder: root, expectedModification: nil)
    let renamed = root.appendingPathComponent("renamed.tif")
    try FileManager.default.moveItem(at: old, to: renamed)
    let discovered = try ProjectStore.open(folder: root)
    XCTAssertEqual(discovered.frames.count, 2)
    let relocated = try ProjectStore.relocate(discovered, frameID: preserved.id, to: renamed, folder: root)
    XCTAssertEqual(relocated.frames.count, 1)
    XCTAssertEqual(relocated.frames[0].id, preserved.id)
    XCTAssertEqual(relocated.frames[0].filename, "renamed.tif")
    XCTAssertEqual(relocated.frames[0].adjustments, preserved.adjustments)
    XCTAssertEqual(relocated.frames[0].orientation, preserved.orientation)
    XCTAssertEqual(relocated.frames[0].crop, preserved.crop)
    XCTAssertFalse(relocated.frames[0].isMissing)
    XCTAssertEqual(relocated.lastActiveFrameID, preserved.id)
    try ProjectStore.save(relocated, folder: root, expectedModification: discovered.loadedModificationDate)
    XCTAssertEqual(try ProjectStore.open(folder: root).frames, relocated.frames)
    XCTAssertEqual(discovered.frames.count, 2, "before value remains available for grouped undo")
  }

  func testRelocationRejectsEditedCollisionAvailableOriginalAndExternalFiles() throws {
    let root = try folder()
    let old = try source("old.tif", in: root)
    let new = try source("new.tif", in: root)
    var project = try ProjectStore.open(folder: root)
    let oldID = project.frames.first { $0.filename == "old.tif" }!.id
    XCTAssertThrowsError(try ProjectStore.relocate(project, frameID: oldID, to: new, folder: root))
    try FileManager.default.removeItem(at: old)
    let destinationIndex = project.frames.firstIndex { $0.filename == "new.tif" }!
    project.frames[destinationIndex].orientation = .flipHorizontal
    XCTAssertThrowsError(try ProjectStore.relocate(project, frameID: oldID, to: new, folder: root))
    project.frames[destinationIndex].orientation = .identity
    project.frames[destinationIndex].adjustments.contrast.master = 1.1
    XCTAssertThrowsError(try ProjectStore.relocate(project, frameID: oldID, to: new, folder: root))
    project.frames[destinationIndex].adjustments = .init()
    project.frames[destinationIndex].crop = FrameCrop(aspect: .square, width: 0.5)
    XCTAssertThrowsError(try ProjectStore.relocate(project, frameID: oldID, to: new, folder: root))
    let outside = try source("external.tif", in: folder())
    XCTAssertThrowsError(try ProjectStore.relocate(project, frameID: oldID, to: outside, folder: root))
    let symlink = root.appendingPathComponent("outside.tif")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
    XCTAssertThrowsError(try ProjectStore.relocate(project, frameID: oldID, to: symlink, folder: root))
    XCTAssertThrowsError(try ProjectStore.relocate(project, frameID: UUID(), to: new, folder: root))
  }

  func testRelocatingCalibrationSourcePreservesEvidenceAndRequiresReview() throws {
    let root = try folder()
    let original = try source("base.tif", in: root)
    var project = try ProjectStore.open(folder: root)
    let calibration = try Pipeline.calibrate(
      image: LinearImage(width: 4, height: 4, samples: [UInt16](repeating: 32000, count: 48)),
      rect: PixelRect(x: 0, y: 0, width: 4, height: 4), matrix: .identity,
      sourceFrameID: project.frames[0].id)
    project.calibration = calibration
    let renamed = root.appendingPathComponent("new-base.tif")
    try FileManager.default.moveItem(at: original, to: renamed)
    let relocated = try ProjectStore.relocate(project, frameID: project.frames[0].id, to: renamed, folder: root)
    XCTAssertEqual(relocated.calibration, calibration)
    XCTAssertTrue(relocated.calibrationNeedsReview)
    XCTAssertFalse(project.calibrationNeedsReview)
  }

  func testRelocationRejectsMalformedTIFFWithoutLosingSavedStableEdits() throws {
    let root = try folder()
    let original = try source("missing.tif", in: root)
    var project = try ProjectStore.open(folder: root)
    project.frames[0].adjustments.timing.red = 87
    project.frames[0].orientation = .rotate90CCW
    let stableID = project.frames[0].id
    try ProjectStore.save(project, folder: root, expectedModification: nil)
    let settingsURL = root.appendingPathComponent(ProjectStore.filename)
    let originalSettings = try Data(contentsOf: settingsURL)
    try FileManager.default.removeItem(at: original)
    let badSource = root.appendingPathComponent("broken.tiff")
    try Data("This is not TIFF image data".utf8).write(to: badSource)
    let discovered = try ProjectStore.open(folder: root)
    XCTAssertThrowsError(try ProjectStore.relocate(discovered, frameID: stableID, to: badSource, folder: root))
    XCTAssertEqual(try Data(contentsOf: settingsURL), originalSettings)
    let retained = try XCTUnwrap(discovered.frames.first { $0.id == stableID })
    XCTAssertTrue(retained.isMissing)
    XCTAssertEqual(retained.filename, "missing.tif")
    XCTAssertEqual(retained.adjustments.timing.red, 87)
    XCTAssertEqual(retained.orientation, .rotate90CCW)
    XCTAssertEqual(discovered.frames.count, 2)
  }
}
