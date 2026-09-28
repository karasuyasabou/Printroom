import Foundation
import XCTest
@testable import PrintroomCore

final class AutoCropProjectTests: XCTestCase {
  func testSchemaSixMigrationBacksUpAndPreservesFixedCropThenStoresReviewState() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("auto-crop-schema-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    var project = RollProject()
    let oldCrop = FrameCrop(aspect: .sevenSix, width: 0.7, angleDegrees: 1.2)
    project.frames = [FrameRecord(filename: "A.tiff", isMissing: true, crop: oldCrop)]
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any])
    object["schemaVersion"] = 6
    var frames = try XCTUnwrap(object["frames"] as? [[String: Any]])
    frames[0].removeValue(forKey: "cropOrigin")
    frames[0].removeValue(forKey: "cropNeedsReview")
    object["frames"] = frames
    let bytes = try JSONSerialization.data(withJSONObject: object)
    let url = folder.appendingPathComponent(".printroom.json")
    try bytes.write(to: url)
    var loaded = try ProjectStore.open(folder: folder)
    XCTAssertEqual(loaded.schemaVersion, RollProject.currentSchemaVersion)
    XCTAssertEqual(loaded.frames[0].crop, oldCrop)
    XCTAssertNil(loaded.frames[0].cropOrigin)
    XCTAssertFalse(loaded.frames[0].cropNeedsReview)
    XCTAssertEqual(try Data(contentsOf: url), bytes)
    let free = FrameCrop(aspect: .free, width: 0.8, angleDegrees: -0.25, freeRatio: 1.491)
    loaded.frames[0].crop = free
    loaded.frames[0].cropOrigin = .automatic
    loaded.frames[0].cropNeedsReview = true
    try ProjectStore.save(loaded, folder: folder, expectedModification: loaded.loadedModificationDate)
    let backups = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
      .filter { $0.lastPathComponent.hasPrefix(".printroom-schema6-") }
    XCTAssertEqual(backups.count, 1)
    XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), bytes)
    let reopened = try ProjectStore.open(folder: folder)
    XCTAssertEqual(reopened.frames[0].crop, free)
    XCTAssertEqual(reopened.frames[0].cropOrigin, .automatic)
    XCTAssertTrue(reopened.frames[0].cropNeedsReview)
  }
}
