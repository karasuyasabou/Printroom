import Foundation
import XCTest

@testable import PrintroomCore

final class RollProjectTests: XCTestCase {
  func testRollNameAndExportPreferencesSurviveSchemaSevenMigration() throws {
    var project = RollProject()
    project.name = "京都 · 250D"
    project.exportSettings.destinationPath = "/tmp/exports"
    project.exportSettings.filenamePrefix = "自定"
    let current = try ProjectStore.decodeSnapshot(JSONEncoder().encode(project))
    XCTAssertEqual(current.name, "京都 · 250D")
    XCTAssertEqual(current.exportSettings.destinationPath, "/tmp/exports")
    XCTAssertEqual(current.exportSettings.filenamePrefix, "自定")

    var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any])
    legacy["schemaVersion"] = 7
    legacy.removeValue(forKey: "name")
    var options = try XCTUnwrap(legacy["exportSettings"] as? [String: Any])
    options.removeValue(forKey: "destinationPath")
    options.removeValue(forKey: "filenamePrefix")
    legacy["exportSettings"] = options
    let migrated = try ProjectStore.decodeSnapshot(JSONSerialization.data(withJSONObject: legacy))
    XCTAssertEqual(migrated.schemaVersion, RollProject.currentSchemaVersion)
    XCTAssertNil(migrated.name)
    XCTAssertNil(migrated.exportSettings.destinationPath)
    XCTAssertNil(migrated.exportSettings.filenamePrefix)
  }

  func testSchemaSevenNameMigrationKeepsOriginalBackup() throws {
    let directory = try folder()
    var project = RollProject()
    project.frames = [FrameRecord(filename: "A.tiff", isMissing: true)]
    var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any])
    old["schemaVersion"] = 7
    old.removeValue(forKey: "name")
    let original = try JSONSerialization.data(withJSONObject: old)
    try original.write(to: jsonURL(directory))
    var migrated = try ProjectStore.open(folder: directory)
    migrated.name = "京都"
    _ = try ProjectStore.save(migrated, folder: directory, expectedModification: migrated.loadedModificationDate)
    XCTAssertEqual(try ProjectStore.open(folder: directory).name, "京都")
    let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .filter { $0.lastPathComponent.hasPrefix(".printroom-schema7-") }
    XCTAssertEqual(backups.count, 1)
    XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), original)
  }
  private func folder() throws -> URL {
    let url = URL(fileURLWithPath: "/tmp", isDirectory: true)
      .appendingPathComponent("printroom-store-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }

  @discardableResult
  private func source(_ name: String, in folder: URL, bytes: [UInt8] = [0x49, 0x49, 0x2a, 0]) throws
    -> URL
  {
    let url = folder.appendingPathComponent(name)
    // Discovery reads file metadata only; these are explicitly dummy files, not TIFF decoder fixtures.
    try Data(bytes).write(to: url)
    return url
  }

  private func jsonURL(_ folder: URL) -> URL {
    folder.appendingPathComponent(ProjectStore.filename)
  }

  private func rewriteJSON(in folder: URL, _ change: (inout [String: Any]) -> Void) throws -> Data {
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL(folder))) as? [String: Any])
    change(&object)
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    try data.write(to: jsonURL(folder))
    return data
  }

  private func calibrated(_ project: RollProject, matrix: PrintDensityMatrix = .identity)
    -> RollProject
  {
    var result = project
    var calibration = FilmCalibration()
    calibration.matrix = matrix
    calibration.sampledDensityMatrix = matrix
    calibration.sourceFrameID = project.frames[0].id
    calibration.sourceWidth = 100
    calibration.sourceHeight = 80
    calibration.selection = PixelRect(x: 1, y: 2, width: 4, height: 4)
    calibration.baseRGB = SIMD3(0.2, 0.4, 0.6)
    calibration.gainRGB = SIMD3(3.75, 1.875, 1.25)
    // Independent analytic references recorded in docs/validation.md.
    calibration.filmBaseOffsetCV =
      matrix == .identity
      ? SIMD3(repeating: 32.530631695850026)
      : SIMD3(30.013116153192783, 31.406183066375327, 38.483962495235524)
    result.calibration = calibration
    return result
  }

  func testNewRollMatrixDefaultsAndSavedIdentityPreserved() throws {
    let root = try folder()
    try source("frame.tiff", in: root)
    var project = try ProjectStore.open(folder: root)
    XCTAssertEqual(project.calibration.cmosMatrix, .sonyA7CII)
    XCTAssertEqual(project.calibration.matrix, .ledLightSource)
    XCTAssertFalse(project.calibration.isCalibrated)
    try ProjectStore.save(project, folder: root, expectedModification: project.loadedModificationDate)
    let reopened = try ProjectStore.open(folder: root)
    XCTAssertEqual(reopened.calibration, project.calibration)
    project = reopened
    project.calibration = FilmCalibration()
    try ProjectStore.save(project, folder: root, expectedModification: project.loadedModificationDate)
    let identity = try ProjectStore.open(folder: root)
    XCTAssertEqual(identity.calibration.cmosMatrix, .identity)
    XCTAssertEqual(identity.calibration.matrix, .identity)
  }

  func testDiscoveryNaturalOrderCaseInsensitiveExtensionsAndNoWrites() throws {
    let root = try folder()
    for name in ["Scan10.tiff", "scan2.TIF", "Scan1.TiFf", "notes.txt"] {
      try source(name, in: root)
    }
    let nested = root.appendingPathComponent("nested", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try source("Scan0.tiff", in: nested)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("directory.tiff"), withIntermediateDirectories: true)
    let project = try ProjectStore.open(
      folder: root, preferredFile: root.appendingPathComponent("scan2.TIF"))
    XCTAssertEqual(project.frames.map(\.filename), ["Scan1.TiFf", "scan2.TIF", "Scan10.tiff"])
    XCTAssertEqual(project.lastActiveFrameID, project.frames[1].id)
    XCTAssertTrue(
      project.frames.allSatisfy { !$0.isMissing && $0.sourceSize == 4 && $0.sourceModified > 0 })
    XCTAssertEqual(Set(project.frames.map(\.id)).count, 3)
    XCTAssertFalse(FileManager.default.fileExists(atPath: jsonURL(root).path))
  }

  func testEmptyRollAndNaturalSortTieAreDeterministic() throws {
    let root = try folder()
    XCTAssertNil(try ProjectStore.open(folder: root).lastActiveFrameID)
    for name in ["Scan01.tif", "Scan1.tif", "Scan001.tif"] { try source(name, in: root) }
    XCTAssertEqual(
      try ProjectStore.open(folder: root).frames.map(\.filename),
      ["Scan001.tif", "Scan01.tif", "Scan1.tif"])
  }

  func testRoundTripPreservesStableIDsCalibrationAndFrameParameters() throws {
    for matrix in PrintDensityMatrix.allCases {
      let root = try folder()
      try source("1.tiff", in: root)
      try source("2.tiff", in: root)
      var project = calibrated(try ProjectStore.open(folder: root), matrix: matrix)
      project.frames[0].adjustments.timing = .init(master: 512, red: -512, green: 257, blue: -257)
      project.frames[1].adjustments.contrast = .init(master: 0.25, red: 4, green: 1.15, blue: 2.75)
      project.lastActiveFrameID = project.frames[1].id
      let date = try ProjectStore.save(project, folder: root, expectedModification: nil)
      XCTAssertEqual(ProjectStore.modificationDate(folder: root), date)
      let loaded = try ProjectStore.open(folder: root)
      XCTAssertEqual(loaded.id, project.id)
      XCTAssertEqual(loaded.frames, project.frames)
      XCTAssertEqual(loaded.calibration, project.calibration)
      XCTAssertEqual(loaded.assets, project.assets)
      XCTAssertEqual(loaded.exportSettings, project.exportSettings)
      XCTAssertEqual(loaded.lastActiveFrameID, project.lastActiveFrameID)
      XCTAssertFalse(loaded.calibrationNeedsReview)
      let json = try String(contentsOf: jsonURL(root), encoding: .utf8)
      XCTAssertFalse(json.contains(root.path))
      XCTAssertFalse(json.contains("selectedFrameIDs"))
      XCTAssertFalse(json.contains("ParameterSnapshot"))
      XCTAssertEqual(
        try ProjectStore.open(folder: root, preferredFile: root.appendingPathComponent("1.tiff"))
          .lastActiveFrameID, project.frames[0].id)
      try ProjectStore.save(loaded, folder: root, expectedModification: date)
    }
  }

  func testRediscoveryRetainsMissingParametersInsertsNewFramesAndRestoresIdentity() throws {
    let root = try folder()
    let one = try source("1.tif", in: root)
    try source("10.tif", in: root)
    var project = try ProjectStore.open(folder: root)
    project.frames[0].adjustments.timing.red = 91
    let missingID = project.frames[0].id
    let date = try ProjectStore.save(project, folder: root, expectedModification: nil)
    try FileManager.default.removeItem(at: one)
    try source("2.tiff", in: root)
    let merged = try ProjectStore.open(folder: root)
    XCTAssertEqual(merged.frames.map(\.filename), ["1.tif", "2.tiff", "10.tif"])
    XCTAssertTrue(merged.frames[0].isMissing)
    XCTAssertEqual(merged.frames[0].id, missingID)
    XCTAssertEqual(merged.frames[0].adjustments.timing.red, 91)
    XCTAssertEqual(merged.lastActiveFrameID, merged.frames[1].id)
    try ProjectStore.save(merged, folder: root, expectedModification: date)
    try source("1.tif", in: root)
    let restored = try ProjectStore.open(folder: root)
    XCTAssertEqual(restored.frames[0].id, missingID)
    XCTAssertFalse(restored.frames[0].isMissing)
    XCTAssertEqual(restored.frames[0].adjustments.timing.red, 91)
  }

  func testMovingWholeRollPreservesIdentityAndExplicitPreferredFile() throws {
    let parent = try folder()
    let root = parent.appendingPathComponent("old", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try source("image.tif", in: root)
    let project = try ProjectStore.open(folder: root)
    try ProjectStore.save(project, folder: root, expectedModification: nil)
    let moved = parent.appendingPathComponent("moved", isDirectory: true)
    try FileManager.default.moveItem(at: root, to: moved)
    let loaded = try ProjectStore.open(
      folder: moved, preferredFile: moved.appendingPathComponent("image.tif"))
    XCTAssertEqual(loaded.id, project.id)
    XCTAssertEqual(loaded.frames, project.frames)
    XCTAssertEqual(loaded.lastActiveFrameID, project.lastActiveFrameID)
  }

  func testRenameDoesNotGuessIdentity() throws {
    let root = try folder()
    let old = try source("old.tif", in: root)
    let project = try ProjectStore.open(folder: root)
    try ProjectStore.save(project, folder: root, expectedModification: nil)
    try FileManager.default.moveItem(at: old, to: root.appendingPathComponent("new.tif"))
    let loaded = try ProjectStore.open(folder: root)
    XCTAssertEqual(loaded.frames.count, 2)
    XCTAssertEqual(loaded.frames.first(where: { $0.isMissing })?.id, project.frames[0].id)
    XCTAssertNotEqual(loaded.frames.first(where: { !$0.isMissing })?.id, project.frames[0].id)
  }

  func testReplacedAndMissingCalibrationSourceRequiresReviewWithoutDiscardingValues() throws {
    let root = try folder()
    let file = try source("base.tiff", in: root)
    let project = calibrated(try ProjectStore.open(folder: root))
    try ProjectStore.save(project, folder: root, expectedModification: nil)
    try Data([1, 2, 3, 4, 5]).write(to: file)
    let replaced = try ProjectStore.open(folder: root)
    XCTAssertEqual(replaced.frames[0].id, project.frames[0].id)
    XCTAssertEqual(replaced.frames[0].sourceSize, 5)
    XCTAssertEqual(replaced.calibration, project.calibration)
    XCTAssertTrue(replaced.calibrationNeedsReview)
    try FileManager.default.removeItem(at: file)
    let missing = try ProjectStore.open(folder: root)
    XCTAssertTrue(missing.frames[0].isMissing)
    XCTAssertTrue(missing.calibrationNeedsReview)
    XCTAssertEqual(missing.calibration, project.calibration)
  }

  func testExternalTIFFSymlinkIsUnavailableAndExternalPreferredFileRejected() throws {
    let root = try folder()
    let outside = try folder()
    let external = try source("outside.tiff", in: outside)
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("link.tiff"), withDestinationURL: external)
    let local = try source("local.tif", in: root)
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("inside.tif"), withDestinationURL: local)
    let project = try ProjectStore.open(folder: root)
    XCTAssertTrue(
      try XCTUnwrap(project.frames.first(where: { $0.filename == "link.tiff" })).isMissing)
    XCTAssertFalse(
      try XCTUnwrap(project.frames.first(where: { $0.filename == "inside.tif" })).isMissing)
    XCTAssertThrowsError(try ProjectStore.open(folder: root, preferredFile: external))
    XCTAssertThrowsError(
      try ProjectStore.open(folder: root, preferredFile: root.appendingPathComponent("link.tiff")))
  }

  func testSaveRejectsStaleNilAndDeletedModificationWithoutOverwriting() throws {
    let root = try folder()
    var project = RollProject()
    let firstDate = try ProjectStore.save(project, folder: root, expectedModification: nil)
    let original = try Data(contentsOf: jsonURL(root))
    XCTAssertThrowsError(try ProjectStore.save(project, folder: root, expectedModification: nil)) {
      XCTAssertEqual($0 as? ProjectStoreError, .externalConflict)
    }
    XCTAssertEqual(try Data(contentsOf: jsonURL(root)), original)
    try FileManager.default.setAttributes(
      [.modificationDate: firstDate.addingTimeInterval(100)], ofItemAtPath: jsonURL(root).path)
    project.calibration.matrix = .ledLightSource
    XCTAssertThrowsError(
      try ProjectStore.save(project, folder: root, expectedModification: firstDate)
    ) {
      XCTAssertEqual($0 as? ProjectStoreError, .externalConflict)
    }
    XCTAssertEqual(try Data(contentsOf: jsonURL(root)), original)
    try FileManager.default.removeItem(at: jsonURL(root))
    XCTAssertThrowsError(
      try ProjectStore.save(project, folder: root, expectedModification: firstDate))
    XCTAssertFalse(FileManager.default.fileExists(atPath: jsonURL(root).path))
  }

  func testDifferentRollIdentityCannotOverwriteExistingProject() throws {
    let root = try folder()
    let date = try ProjectStore.save(RollProject(), folder: root, expectedModification: nil)
    let original = try Data(contentsOf: jsonURL(root))
    XCTAssertThrowsError(
      try ProjectStore.save(RollProject(), folder: root, expectedModification: date))
    XCTAssertEqual(try Data(contentsOf: jsonURL(root)), original)
  }

  func testReadOnlySaveFailurePreservesOriginalAndInMemoryEdits() throws {
    let root = try folder()
    var project = RollProject()
    let date = try ProjectStore.save(project, folder: root, expectedModification: nil)
    let original = try Data(contentsOf: jsonURL(root))
    project.calibration.matrix = .ledLightSource
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }
    XCTAssertThrowsError(try ProjectStore.save(project, folder: root, expectedModification: date))
    XCTAssertEqual(try Data(contentsOf: jsonURL(root)), original)
    XCTAssertEqual(project.calibration.matrix, .ledLightSource)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: root.path), [ProjectStore.filename])
  }

  func testConcurrentInitialSavesPublishExactlyOneWholeProject() throws {
    let root = try folder()
    let projects = (0..<8).map { _ in RollProject() }
    let results = ConcurrentSaveResults()
    DispatchQueue.concurrentPerform(iterations: projects.count) { index in
      do {
        try ProjectStore.save(projects[index], folder: root, expectedModification: nil)
        results.record(success: projects[index].id)
      } catch {
        results.record(error: error)
      }
    }
    XCTAssertEqual(results.successes.count, 1)
    XCTAssertEqual(results.errors.count, projects.count - 1)
    XCTAssertTrue(results.errors.allSatisfy { ($0 as? ProjectStoreError) == .externalConflict })
    XCTAssertEqual(try ProjectStore.open(folder: root).id, results.successes.first)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: root.path), [ProjectStore.filename])
  }

  func testDamagedAndFutureProjectFilesArePreservedOnOpenAndSave() throws {
    let cases = [
      Data("{broken".utf8),
      Data("{\"schemaVersion\":999,\"algorithmVersion\":\"printroom-density-v1\"}".utf8),
    ]
    for original in cases {
      let root = try folder()
      try original.write(to: jsonURL(root))
      XCTAssertThrowsError(try ProjectStore.open(folder: root))
      XCTAssertThrowsError(
        try ProjectStore.save(
          RollProject(), folder: root,
          expectedModification: ProjectStore.modificationDate(folder: root)))
      XCTAssertEqual(try Data(contentsOf: jsonURL(root)), original)
    }
  }

  func testProjectSymlinkAndDirectoryAreNeverReplaced() throws {
    let root = try folder()
    let outside = try folder()
    let target = outside.appendingPathComponent("protected.json")
    let bytes = Data("protected".utf8)
    try bytes.write(to: target)
    try FileManager.default.createSymbolicLink(at: jsonURL(root), withDestinationURL: target)
    XCTAssertThrowsError(try ProjectStore.open(folder: root))
    XCTAssertThrowsError(
      try ProjectStore.save(RollProject(), folder: root, expectedModification: nil))
    XCTAssertEqual(try Data(contentsOf: target), bytes)
    try FileManager.default.removeItem(at: jsonURL(root))
    try FileManager.default.createDirectory(at: jsonURL(root), withIntermediateDirectories: true)
    XCTAssertThrowsError(
      try ProjectStore.save(RollProject(), folder: root, expectedModification: nil))
    XCTAssertTrue(try jsonURL(root).resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
  }

  func testJSONValidationRejectsFractionalTimingBadAssetsAndBrokenIdentity() throws {
    let mutations: [(inout [String: Any]) -> Void] = [
      { $0["algorithmVersion"] = "future-algorithm" },
      { $0["schemaVersion"] = 0 },
      {
        var assets = $0["assets"] as! [String: Any]
        assets["lutSHA256"] = String(repeating: "0", count: 64)
        $0["assets"] = assets
      },
      {
        var assets = $0["assets"] as! [String: Any]
        assets["workingICCPath"] = "../ICC/elsewhere.icc"
        $0["assets"] = assets
      },
      {
        var frames = $0["frames"] as! [[String: Any]]
        frames[0]["filename"] = "../escape.tif"
        $0["frames"] = frames
      },
      {
        var frames = $0["frames"] as! [[String: Any]]
        var a = frames[0]["adjustments"] as! [String: Any]
        var t = a["timing"] as! [String: Any]
        t["red"] = 0.5
        a["timing"] = t
        frames[0]["adjustments"] = a
        $0["frames"] = frames
      },
      {
        let frames = $0["frames"] as! [[String: Any]]
        $0["frames"] = frames + frames
      },
      { $0["lastActiveFrameID"] = UUID().uuidString },
      { $0.removeValue(forKey: "assets") },
    ]
    for mutation in mutations {
      let root = try folder()
      try source("1.tiff", in: root)
      let project = try ProjectStore.open(folder: root)
      try ProjectStore.save(project, folder: root, expectedModification: nil)
      let damaged = try rewriteJSON(in: root, mutation)
      XCTAssertThrowsError(try ProjectStore.open(folder: root))
      XCTAssertThrowsError(
        try ProjectStore.save(
          project, folder: root, expectedModification: ProjectStore.modificationDate(folder: root)))
      XCTAssertEqual(try Data(contentsOf: jsonURL(root)), damaged)
    }
  }

  func testInvalidInMemoryValuesDoNotTouchExistingFile() throws {
    let root = try folder()
    try source("1.tiff", in: root)
    let project = try ProjectStore.open(folder: root)
    let date = try ProjectStore.save(project, folder: root, expectedModification: nil)
    let bytes = try Data(contentsOf: jsonURL(root))
    let mutations: [(inout RollProject) -> Void] = [
      { $0.frames[0].adjustments.timing.master = 513 },
      { $0.frames[0].adjustments.timing.blue = Int.min },
      { $0.frames[0].adjustments.contrast.master = .nan },
      { $0.frames[0].adjustments.contrast.red = .infinity },
      { $0.frames[0].adjustments.contrast.green = 0.249 },
      { $0.frames[0].adjustments.contrast.blue = 4.01 },
      { $0.frames[0].sourceModified = .nan },
      { $0.frames[0].sourceSize = -1 },
      { $0.frames[0].filename = "/absolute.tiff" },
      { $0.frames[0].filename = "folder\\escape.tiff" },
      { $0.frames[0].filename = "name\0.tiff" },
      { $0.frames[0].filename = "name.jpg" },
      { $0.assets.workingICCSHA256 = "invalid" },
      { $0.inputInterpretation.policy = "convert" },
      { $0.exportSettings.embedsICC = false },
      { $0.calibration.gainRGB.x = 2 },
      { $0.updatedAt = Date(timeIntervalSince1970: .infinity) },
    ]
    for mutation in mutations {
      var invalid = project
      mutation(&invalid)
      XCTAssertThrowsError(try ProjectStore.save(invalid, folder: root, expectedModification: date))
      XCTAssertEqual(try Data(contentsOf: jsonURL(root)), bytes)
    }
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(),
      [".printroom.json", "1.tiff"])
  }

  func testCalibrationDerivedValuesAndSamplingEvidenceMustAgree() throws {
    let root = try folder()
    try source("base.tif", in: root)
    let project = calibrated(try ProjectStore.open(folder: root))
    let mutations: [(inout RollProject) -> Void] = [
      { $0.calibration.gainRGB.x += 0.01 },
      { $0.calibration.filmBaseOffsetCV.z += 0.1 },
      { $0.calibration.sampledDensityMatrix = .ledLightSource },
      { $0.calibration.baseRGB?.x = 0 },
      { $0.calibration.baseRGB?.x = 1.01 },
      { $0.calibration.baseRGB?.x = .nan },
      { $0.calibration.sourceFrameID = nil },
      { $0.calibration.sourceFrameID = UUID() },
      { $0.calibration.sourceWidth = nil },
      { $0.calibration.sourceWidth = Int.max },
      { $0.calibration.selection?.x = Int.max },
      { $0.calibration.selection?.width = Int.max },
      { $0.calibration.selection?.height = 1 },
      { $0.calibration.selection?.y = -1 },
    ]
    for mutation in mutations {
      var invalid = project
      mutation(&invalid)
      XCTAssertThrowsError(try ProjectStore.save(invalid, folder: root, expectedModification: nil))
      XCTAssertFalse(FileManager.default.fileExists(atPath: jsonURL(root).path))
    }
  }

  func testSelectionClickCommandShiftAndSelectAllRules() {
    let ids = (0..<6).map { _ in UUID() }
    var state = SelectionState()
    state.click(ids[1], ordered: ids)
    XCTAssertEqual(state.selectedFrameIDs, [ids[1]])
    XCTAssertEqual(state.activeFrameID, ids[1])
    XCTAssertEqual(state.anchorID, ids[1])
    state.click(ids[4], ordered: ids, shift: true)
    XCTAssertEqual(state.selectedFrameIDs, Set(ids[1...4]))
    XCTAssertEqual(state.activeFrameID, ids[1])
    XCTAssertEqual(state.anchorID, ids[1])
    state.click(ids[0], ordered: ids, command: true, shift: true)
    XCTAssertEqual(state.selectedFrameIDs, Set(ids[0...4]))
    XCTAssertEqual(state.anchorID, ids[1])
    state.click(ids[5], ordered: ids, command: true)
    XCTAssertEqual(state.selectedFrameIDs, Set(ids))
    XCTAssertEqual(state.activeFrameID, ids[1])
    XCTAssertEqual(state.anchorID, ids[1])
    state.click(ids[2], ordered: ids)
    state.selectAll(ids)
    XCTAssertEqual(state.selectedFrameIDs, Set(ids))
    XCTAssertEqual(state.activeFrameID, ids[2])
    XCTAssertEqual(state.anchorID, ids[2])
  }

  func testCommandTogglesTargetsAndKeepsActiveSelected() {
    let ids = (0..<5).map { _ in UUID() }
    var state = SelectionState()
    state.click(ids[1], ordered: ids)
    state.click(ids[3], ordered: ids, command: true)
    state.click(ids[2], ordered: ids, command: true)
    state.click(ids[2], ordered: ids, command: true)
    XCTAssertEqual(state.activeFrameID, ids[1])
    XCTAssertEqual(state.anchorID, ids[1])
    XCTAssertEqual(state.selectedFrameIDs, [ids[1], ids[3]])
    state.click(ids[1], ordered: ids, command: true)
    XCTAssertEqual(state.activeFrameID, ids[1])
    XCTAssertEqual(state.selectedFrameIDs, [ids[1], ids[3]])
    state.click(ids[3], ordered: ids, command: true)
    XCTAssertEqual(state.selectedFrameIDs, [ids[1]])
    XCTAssertEqual(state.activeFrameID, ids[1])
    XCTAssertEqual(state.anchorID, ids[1])
    state = SelectionState()
    state.click(ids[4], ordered: ids, command: true, shift: true)
    XCTAssertEqual(state.selectedFrameIDs, [ids[4]])
    XCTAssertEqual(state.activeFrameID, ids[4])
    XCTAssertEqual(state.anchorID, ids[4])
  }

  func testRangeAnchorStaysOnActiveAndReorderingUsesStableIDs() {
    let ids = (0..<5).map { _ in UUID() }
    var state = SelectionState()
    state.click(ids[1], ordered: ids)
    state.click(ids[3], ordered: ids, shift: true)
    state.click(ids[1], ordered: ids, command: true)
    XCTAssertEqual(state.activeFrameID, ids[1])
    XCTAssertEqual(state.anchorID, ids[1])
    let reordered = [ids[0], ids[3], ids[4], ids[1], ids[2]]
    state.click(ids[2], ordered: reordered, shift: true)
    XCTAssertEqual(state.selectedFrameIDs, Set(reordered[3...4]))
    XCTAssertEqual(state.activeFrameID, ids[1])
    XCTAssertEqual(state.anchorID, ids[1])
  }

  func testSelectionReconcilesUnavailableFramesAndEmptyOrder() {
    let ids = (0..<3).map { _ in UUID() }
    var state = SelectionState()
    state.selectAll(ids)
    XCTAssertEqual(state.activeFrameID, ids[0])
    state.click(UUID(), ordered: [ids[1], ids[2]])
    XCTAssertEqual(state.selectedFrameIDs, [ids[1], ids[2]])
    XCTAssertEqual(state.activeFrameID, ids[1])
    XCTAssertEqual(state.anchorID, ids[1])
    state.selectAll([])
    XCTAssertTrue(state.selectedFrameIDs.isEmpty)
    XCTAssertNil(state.activeFrameID)
    XCTAssertNil(state.anchorID)
  }

  func testSnapshotCopiesImmutableValuesAndOverwritesAllTargetsWithoutTouchingCalibration() throws {
    let root = try folder()
    for name in ["A.tif", "B.tif", "C.tif"] { try source(name, in: root) }
    var project = calibrated(try ProjectStore.open(folder: root))
    project.frames[0].adjustments = .init(
      timing: .init(master: 12, red: -13, green: 14, blue: 15),
      contrast: .init(master: 1.1, red: 1.2, green: 1.3, blue: 1.4))
    project.frames[1].adjustments.timing.master = -100
    project.frames[2].adjustments.contrast.master = 2.5
    let snapshot = ParameterSnapshot(frame: project.frames[0])
    project.frames[0].adjustments.timing.master = 200
    let before = project
    let targets = Set(project.frames.dropFirst().map(\.id))
    let applied = try snapshot.applying(to: project, targets: targets)
    XCTAssertEqual(snapshot.sourceID, project.frames[0].id)
    XCTAssertEqual(snapshot.sourceName, "A.tif")
    XCTAssertEqual(applied.frames[0], before.frames[0])
    XCTAssertEqual(applied.frames[1].adjustments, snapshot.adjustments)
    XCTAssertEqual(applied.frames[2].adjustments, snapshot.adjustments)
    XCTAssertEqual(applied.calibration, before.calibration)
    XCTAssertEqual(applied.lastActiveFrameID, before.lastActiveFrameID)
    XCTAssertEqual(project.frames, before.frames)
    let repeated = try snapshot.applying(to: applied, targets: targets)
    XCTAssertEqual(repeated.frames, applied.frames)
    // The complete before/after values retain heterogeneous settings for one UI undo/redo entry.
    XCTAssertEqual(before.frames[1].adjustments.timing.master, -100)
    XCTAssertEqual(before.frames[2].adjustments.contrast.master, 2.5)
  }

  func testSnapshotAllowsLostSourceButRejectsAnyLostTargetAtomically() throws {
    let root = try folder()
    for name in ["A.tif", "B.tif", "C.tif"] { try source(name, in: root) }
    var project = try ProjectStore.open(folder: root)
    project.frames[0].adjustments.timing.red = 71
    let snapshot = ParameterSnapshot(frame: project.frames[0])
    try FileManager.default.removeItem(at: root.appendingPathComponent("A.tif"))
    let targets = Set(project.frames.dropFirst().map(\.id))
    let applied = try snapshot.applying(to: project, targets: targets)
    XCTAssertEqual(applied.frames[1].adjustments.timing.red, 71)
    try FileManager.default.removeItem(at: root.appendingPathComponent("C.tif"))
    let before = project.frames
    XCTAssertThrowsError(try snapshot.applying(to: project, targets: targets))
    XCTAssertEqual(project.frames, before)
    project.frames[2].isMissing = true
    XCTAssertThrowsError(try snapshot.applying(to: project, targets: targets))
  }

  func testSnapshotsRejectIncompatibleVersionsInvalidParametersAndInvalidTargets() throws {
    var project = RollProject()
    project.frames = [FrameRecord(filename: "A.tif"), FrameRecord(filename: "B.tif")]
    let source = project.frames[0]
    let valid = ParameterSnapshot(frame: source)
    let snapshots = [
      ParameterSnapshot(
        sourceID: source.id, sourceName: source.filename, adjustments: .init(), formatVersion: 2),
      ParameterSnapshot(
        sourceID: source.id, sourceName: source.filename, adjustments: .init(),
        algorithmVersion: "future"),
      ParameterSnapshot(
        sourceID: source.id, sourceName: source.filename, adjustments: .init(), pivotCV: 470),
      ParameterSnapshot(
        sourceID: source.id, sourceName: source.filename,
        adjustments: .init(timing: .init(master: 513))),
      ParameterSnapshot(
        sourceID: source.id, sourceName: source.filename,
        adjustments: .init(contrast: .init(blue: .nan))),
    ]
    for snapshot in snapshots {
      XCTAssertThrowsError(try snapshot.applying(to: project, targets: [project.frames[1].id]))
    }
    XCTAssertThrowsError(try valid.applying(to: project, targets: []))
    XCTAssertThrowsError(try valid.applying(to: project, targets: [source.id, UUID()]))
    project.algorithmVersion = "future"
    XCTAssertThrowsError(try valid.applying(to: project, targets: [source.id]))
  }

  func testSourceCanBeAnApplicationTarget() throws {
    var project = RollProject()
    project.frames = [FrameRecord(filename: "A.tiff", adjustments: .init(timing: .init(red: 13)))]
    let snapshot = ParameterSnapshot(frame: project.frames[0])
    project.frames[0].adjustments.timing.red = 97
    let result = try snapshot.applying(to: project, targets: [project.frames[0].id])
    XCTAssertEqual(result.frames[0].adjustments.timing.red, 13)
  }

  func testAssetIdentityConstantsMatchImmutableManifest() throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let manifest = try XCTUnwrap(
      JSONSerialization.jsonObject(
        with: Data(contentsOf: repository.appendingPathComponent("assets/manifest.json")))
        as? [String: Any])
    let assets = try XCTUnwrap(manifest["assets"] as? [[String: Any]])
    XCTAssertEqual(
      assets.first(where: { $0["path"] as? String == ProjectAssetIdentity.expectedLUTPath })?[
        "sha256"] as? String, ProjectAssetIdentity.expectedLUTSHA256)
    XCTAssertEqual(
      assets.first(where: { $0["path"] as? String == ProjectAssetIdentity.expectedICCPath })?[
        "sha256"] as? String, ProjectAssetIdentity.expectedICCSHA256)
  }
}

private final class ConcurrentSaveResults: @unchecked Sendable {
  private let lock = NSLock()
  private(set) var successes: [UUID] = []
  private(set) var errors: [Error] = []

  func record(success: UUID) {
    lock.lock()
    defer { lock.unlock() }
    successes.append(success)
  }

  func record(error: Error) {
    lock.lock()
    defer { lock.unlock() }
    errors.append(error)
  }
}
