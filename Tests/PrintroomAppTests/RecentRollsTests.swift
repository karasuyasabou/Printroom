import Foundation
import PrintroomCore
import Testing
@testable import PrintroomApp

@Suite(.serialized) @MainActor struct RecentRollsTests {
  @Test func historyPersistenceDeduplicationAndLimit() throws {
    let suite = "Printroom.RecentTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let history = RecentRolls(defaults: defaults)
    for index in 0..<25 {
      history.record(folder: URL(fileURLWithPath: "/tmp/roll-\(index)"), projectID: UUID(), date: Date(timeIntervalSince1970: Double(index)))
    }
    #expect(history.entries.count == 20)
    let entry = history.entries[10]
    history.record(folder: entry.url, projectID: entry.projectID)
    #expect(history.entries.first?.id == entry.id)
    #expect(history.entries.filter { $0.id == entry.id }.count == 1)
    history.updateName(folder: entry.url, name: "京都 · 250D")
    #expect(history.entries.first?.displayName == "京都 · 250D")
    #expect(RecentRolls(defaults: defaults).entries == history.entries)
    let before = history.entries
    history.remove(history.entries[3])
    #expect(history.entries.count == 19)
    #expect(RecentRolls(defaults: defaults).entries.count == 19)
    history.undoRemoval()
    #expect(history.entries == before)
  }

  @Test func oldRecentHistoryWithoutNamesStillLoads() throws {
    let suite = "Printroom.RecentTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let entry: [String: Any] = [
      "path": "/tmp/old-roll", "projectID": UUID().uuidString,
      "openedAt": Date().timeIntervalSinceReferenceDate,
    ]
    defaults.set(try JSONSerialization.data(withJSONObject: [entry]), forKey: "recentRolls.v1")
    #expect(RecentRolls(defaults: defaults).entries.first?.displayName == "old-roll")
  }

  @Test func openingRestoresFrameAndRemovalPreservesProject() async throws {
    let suite = "Printroom.RecentTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: folder)
    }
    for name in ["a.tiff", "b.tiff"] {
      try TIFFCodec.write(url: folder.appendingPathComponent(name), width: 2, height: 2, profile: nil) { rows in
        Array(repeating: UInt16(16000), count: rows.count * 2 * 3)
      }
    }
    let history = RecentRolls(defaults: defaults)
    let model = EditorModel(recentRolls: history)
    model.open(folder.appendingPathComponent("b.tiff"))
    try await waitForProxyImport(model)
    #expect(history.entries.count == 1)
    #expect(model.activeFrame?.filename == "b.tiff")
    let entry = try #require(history.entries.first)
    model.openRecent(entry)
    try await waitForProxyImport(model)
    #expect(model.activeFrame?.filename == "b.tiff")
    #expect(history.entries.count == 1)
    let projectURL = folder.appendingPathComponent(".printroom.json")
    let saved = try Data(contentsOf: projectURL)
    history.remove(entry)
    #expect(try Data(contentsOf: projectURL) == saved)
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("b.tiff").path))
    model.open(folder)
    try await waitForProxyImport(model)
    #expect(history.entries.count == 1)
    model.open(folder.appendingPathComponent("missing.tiff"))
    try await waitForProxyImport(model)
    #expect(history.entries.count == 1)
  }

  @Test func returningHomeSavesAndReopensWithoutStalePreview() async throws {
    let suite = "Printroom.HomeTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: folder)
    }
    try TIFFCodec.write(url: folder.appendingPathComponent("a.tiff"), width: 2, height: 2, profile: nil) { rows in
      Array(repeating: UInt16(16000), count: rows.count * 2 * 3)
    }
    let history = RecentRolls(defaults: defaults)
    let model = EditorModel(recentRolls: history)
    model.open(folder)
    try await waitForProxyImport(model)
    model.edit { $0.timing.master = 12 }
    model.returnHome()
    #expect(model.project == nil)
    #expect(model.folder == nil)
    #expect(!model.canUndo)
    #expect(history.entries.count == 1)
    #expect(try ProjectStore.open(folder: folder).frames.first?.adjustments.timing.master == 12)
    try await Task.sleep(for: .milliseconds(150))
    #expect(model.previewImage == nil && model.histogram == nil && model.thumbnails.isEmpty)
    #expect(!model.isLoading && !model.isRendering)
    model.openRecent(try #require(history.entries.first))
    try await waitForProxyImport(model)
    #expect(model.adjustments.timing.master == 12)
    model.isExporting = true
    model.returnHome()
    #expect(model.project != nil)
    model.isExporting = false
    model.edit { $0.timing.master = 24 }
    // External changes must prevent leaving the unsaved session.
    try Data("external change".utf8).write(to: folder.appendingPathComponent(ProjectStore.filename))
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)],
      ofItemAtPath: folder.appendingPathComponent(ProjectStore.filename).path)
    model.returnHome()
    #expect(model.project != nil && model.saveFailure)
    #expect(model.adjustments.timing.master == 24)
  }

  @Test func relocationReplacesOnlyOldLocation() throws {
    let suite = "Printroom.RecentTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let history = RecentRolls(defaults: defaults)
    let id = UUID()
    history.record(folder: URL(fileURLWithPath: "/tmp/old-roll"), projectID: id)
    let old = try #require(history.entries.first)
    history.record(folder: URL(fileURLWithPath: "/tmp/new-roll"), projectID: id, replacing: old.path)
    #expect(history.entries.count == 1)
    #expect(history.entries.first?.url.lastPathComponent == "new-roll")
    #expect(history.entries.first?.projectID == id)
  }
}
