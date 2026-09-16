import Foundation
import XCTest
@testable import PrintroomCore

final class DiskCachePolicyTests: XCTestCase {
  func testPreferencesAndInvalidValues() {
    let suite = "Printroom-cache-test-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    XCTAssertEqual(DiskCachePolicy.load(defaults: defaults), DiskCachePolicy())
    for days in [0, 3, 7, 30] {
      let policy = DiskCachePolicy(limitGB: 3.5, retentionDays: days)
      policy.save(defaults: defaults)
      XCTAssertEqual(DiskCachePolicy.load(defaults: defaults), policy)
      XCTAssertEqual(policy.limitBytes, 3_500_000_000)
    }
    XCTAssertEqual(DiskCachePolicy(limitGB: .nan, retentionDays: -1), DiskCachePolicy())
    XCTAssertEqual(DiskCachePolicy(limitGB: -2).limitGB, 8)
  }

  func testCombinedBudgetEvictsOldestAcrossRollsAndRAW() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date()
    let raw = try makeEntry(root, raw: true, key: "a", bytes: 60_000_000, date: now.addingTimeInterval(-200))
    let thumbnail = try makeEntry(root, raw: false, key: "b", bytes: 60_000_000, date: now.addingTimeInterval(-100))
    XCTAssertEqual(try ManagedDiskCache.size(root: root), 120_000_000)
    XCTAssertEqual(try ManagedDiskCache.maintain(root: root, policy: .init(limitGB: 0.1, retentionDays: 0)), 60_000_000)
    XCTAssertFalse(FileManager.default.fileExists(atPath: raw.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: thumbnail.path))
  }

  func testEveryRetentionOptionAndUnknownFileProtection() throws {
    for days in [0, 3, 7, 30] {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let now = Date()
      let old = try makeEntry(root, raw: true, key: "a", bytes: 10, date: now.addingTimeInterval(-31 * 86400))
      let fresh = try makeEntry(root, raw: false, key: "b", bytes: 20, date: now.addingTimeInterval(-2 * 86400))
      let middle = try makeEntry(root, raw: false, key: "d", bytes: 15, date: now.addingTimeInterval(-5 * 86400))
      let older = try makeEntry(root, raw: true, key: "e", bytes: 15, date: now.addingTimeInterval(-14 * 86400))
      let unknown = fresh.deletingLastPathComponent().appendingPathComponent("keep.json")
      try Data("project".utf8).write(to: unknown)
      let link = fresh.deletingLastPathComponent().appendingPathComponent(String(repeating: "c", count: 64) + ".png")
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: unknown)
      _ = try ManagedDiskCache.maintain(root: root, policy: .init(retentionDays: days), now: now)
      XCTAssertEqual(FileManager.default.fileExists(atPath: old.path), days == 0)
      XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
      XCTAssertEqual(FileManager.default.fileExists(atPath: middle.path), days == 0 || days > 5)
      XCTAssertEqual(FileManager.default.fileExists(atPath: older.path), days == 0 || days > 14)
      XCTAssertEqual(try Data(contentsOf: unknown), Data("project".utf8))
      XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), unknown.path)
    }
  }

  func testSymlinkNamespaceIsNotFollowed() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let fresh = try makeEntry(root, raw: false, key: "b", bytes: 20, date: .distantPast)
    let namespace = fresh.deletingLastPathComponent().deletingLastPathComponent()
    let moved = root.appendingPathComponent("originals")
    try FileManager.default.moveItem(at: namespace, to: moved)
    try FileManager.default.createSymbolicLink(at: namespace, withDestinationURL: moved)
    XCTAssertEqual(try ManagedDiskCache.size(root: root), 0)
    _ = try ManagedDiskCache.maintain(root: root, policy: .init())
    XCTAssertTrue(FileManager.default.fileExists(atPath: moved.appendingPathComponent(".printroom-cache").appendingPathComponent(fresh.lastPathComponent).path))
  }

  private func makeEntry(_ root: URL, raw: Bool, key: String, bytes: Int, date: Date) throws -> URL {
    let digest = String(repeating: key, count: 64)
    let directory = raw ? root.appendingPathComponent("raw-v1/\(digest)")
      : root.appendingPathComponent("thumbnails-v1/\(digest)/.printroom-cache")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent(raw ? "proxy.tiff" : "\(digest).png")
    FileManager.default.createFile(atPath: file.path, contents: nil)
    let handle = try FileHandle(forWritingTo: file)
    try handle.truncate(atOffset: UInt64(bytes))
    try handle.close()
    let target = raw ? directory : file
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: target.path)
    return target
  }
}
