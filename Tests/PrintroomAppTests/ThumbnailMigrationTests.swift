import CoreGraphics
import Foundation
import Testing
import PrintroomCore
@testable import PrintroomApp

struct ThumbnailMigrationTests {
  private func fixture() throws -> (URL, URL, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("thumbnail-migration-\(UUID())")
    let roll = root.appendingPathComponent("roll")
    try FileManager.default.createDirectory(at: roll, withIntermediateDirectories: true)
    return (root, roll, root.appendingPathComponent("system/thumbnails-v1"))
  }
  private func makeImage() throws -> CGImage {
    try DisplayImage.make(PixelBuffer(width: 2, height: 1,
      pixels: [SIMD4(0.2, 0.5, 0.9, 1), SIMD4(1, 0, 0.5, 1)]), profile: nil)
  }

  @Test func migratesAndRemovesEmptyLegacyWithoutTouchingProject() async throws {
    let (root, roll, system) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = roll.appendingPathComponent(".printroom.json")
    let original = roll.appendingPathComponent("original.tiff")
    for file in [project, original] { try Data("preserve".utf8).write(to: file) }
    let legacyURL = roll.appendingPathComponent(".printroom-cache")
    let legacy = DiskThumbnailCache(directory: legacyURL)
    let key = String(repeating: "a", count: 64)
    let image = try makeImage()
    try await legacy.store(image, for: key)
    let cachedBefore = try #require(try await legacy.image(for: key))
    let destination = DiskThumbnailCache.forRoll(folder: roll, projectID: UUID(), cacheRoot: system)
    try await destination.migrateLegacy(from: roll)
    let cached = try #require(try await destination.image(for: key))
    #expect(cached.width == 2 && cached.bitsPerComponent == 16)
    #expect(cached.dataProvider?.data as Data? == cachedBefore.dataProvider?.data as Data?)
    #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
    for file in [project, original] { #expect(try Data(contentsOf: file) == Data("preserve".utf8)) }
    try await destination.migrateLegacy(from: roll)
    #expect(try await destination.clear().removedFiles == 1)
    #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
  }

  @Test func preservesUnknownFilesSymlinksAndRecentTemporaryFiles() async throws {
    let (root, roll, system) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let legacyURL = roll.appendingPathComponent(".printroom-cache")
    let legacy = DiskThumbnailCache(directory: legacyURL)
    try await legacy.store(makeImage(), for: String(repeating: "b", count: 64))
    let unknown = legacyURL.appendingPathComponent("notes.txt")
    try Data("keep".utf8).write(to: unknown)
    let link = legacyURL.appendingPathComponent(String(repeating: "c", count: 64) + ".png")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: unknown)
    let recent = legacyURL.appendingPathComponent(".printroom-thumbnail-\(UUID()).png.tmp")
    try Data("pending".utf8).write(to: recent)
    let stale = legacyURL.appendingPathComponent(".printroom-thumbnail-\(UUID()).png.tmp")
    try Data("stale".utf8).write(to: stale)
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-90000)], ofItemAtPath: stale.path)
    let destination = DiskThumbnailCache.forRoll(folder: roll, projectID: UUID(), cacheRoot: system)
    try await destination.migrateLegacy(from: roll)
    #expect(try Data(contentsOf: unknown) == Data("keep".utf8))
    #expect(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    #expect(FileManager.default.fileExists(atPath: recent.path))
    #expect(!FileManager.default.fileExists(atPath: stale.path))
  }

  @Test func failedDestinationLeavesLegacyReusable() async throws {
    let (root, roll, system) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let legacy = DiskThumbnailCache(directory: roll.appendingPathComponent(".printroom-cache"))
    let key = String(repeating: "d", count: 64)
    try await legacy.store(makeImage(), for: key)
    try Data("blocking file".utf8).write(to: system.deletingLastPathComponent())
    let destination = DiskThumbnailCache.forRoll(folder: roll, projectID: UUID(), cacheRoot: system)
    do { try await destination.migrateLegacy(from: roll); Issue.record("Expected invalid destination") } catch {}
    #expect(try await legacy.image(for: key) != nil)
  }

  @Test func rejectsLegacyDirectoryAndSystemAncestorSymlinks() async throws {
    let (root, roll, system) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let outside = root.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let marker = outside.appendingPathComponent("keep.txt")
    try Data("keep".utf8).write(to: marker)
    try FileManager.default.createSymbolicLink(at: roll.appendingPathComponent(".printroom-cache"), withDestinationURL: outside)
    let destination = DiskThumbnailCache.forRoll(folder: roll, projectID: UUID(), cacheRoot: system)
    do { try await destination.migrateLegacy(from: roll); Issue.record("Expected legacy symlink rejection") } catch {}
    try FileManager.default.createSymbolicLink(at: system.deletingLastPathComponent(), withDestinationURL: outside)
    do { try await destination.store(makeImage(), for: String(repeating: "e", count: 64)); Issue.record("Expected system symlink rejection") } catch {}
    #expect(try Data(contentsOf: marker) == Data("keep".utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path) == ["keep.txt"])
  }

  @Test @MainActor func editorUsesSystemCacheAndDoesNotRecreateLegacyDirectory() async throws {
    let (root, roll, _) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = EditorModel()
    let assets = try #require(model.assets)
    try TIFFCodec.write(url: roll.appendingPathComponent("A.tiff"), width: 12, height: 8, profile: assets.profile) {
      rows in [UInt16](repeating: 32768, count: rows.count * 12 * 3)
    }
    let legacyURL = roll.appendingPathComponent(".printroom-cache")
    let legacy = DiskThumbnailCache(directory: legacyURL)
    let key = String(repeating: "a", count: 64)
    try await legacy.store(makeImage(), for: key)
    model.open(roll)
    let projectID = try #require(model.project?.id)
    let destination = DiskThumbnailCache.forRoll(folder: roll, projectID: projectID)
    let deadline = Date().addingTimeInterval(8)
    while (model.thumbnails.isEmpty || FileManager.default.fileExists(atPath: legacyURL.path)), Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(!model.thumbnails.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
    #expect(try await destination.image(for: key) != nil)
    #expect(model.flushSave())
    _ = try await destination.clear()
    model.open(roll)
    let clearDeadline = Date().addingTimeInterval(8)
    while model.thumbnails.isEmpty, Date() < clearDeadline { try await Task.sleep(for: .milliseconds(20)) }
    #expect(!model.thumbnails.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
    #expect(try await destination.image(for: key) == nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: roll.path).sorted() == [".printroom.json", "A.tiff"])
  }

  @Test func namespacesSeparateRollsAndClearOnlyCurrentRoll() async throws {
    let (root, roll, system) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let first = DiskThumbnailCache.forRoll(folder: roll, projectID: id, cacheRoot: system)
    let same = DiskThumbnailCache.forRoll(folder: roll, projectID: id, cacheRoot: system)
    let copy = DiskThumbnailCache.forRoll(folder: root.appendingPathComponent("copy"), projectID: id, cacheRoot: system)
    let key = String(repeating: "f", count: 64)
    try await first.store(makeImage(), for: key)
    #expect(try await same.image(for: key) != nil)
    #expect(try await copy.image(for: key) == nil)
    try await copy.store(makeImage(), for: key)
    _ = try await first.clear()
    #expect(try await copy.image(for: key) != nil)
    #expect(!FileManager.default.fileExists(atPath: roll.appendingPathComponent(".printroom-cache").path))
  }
}
