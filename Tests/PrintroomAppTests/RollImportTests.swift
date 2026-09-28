import Foundation
import PrintroomCore
import Testing
@testable import PrintroomApp

@Suite(.serialized) @MainActor
struct RollImportTests {
  private final class Gate: @unchecked Sendable {
    let lock = NSLock()
    var started = 0
    var released = false
    var fail = false
    func load(_ url: URL) throws {
      lock.withLock { started += 1 }
      while !lock.withLock({ released }) {
        try Task.checkCancellation()
        Thread.sleep(forTimeInterval: 0.005)
      }
      if lock.withLock({ fail }) { throw CocoaError(.fileReadCorruptFile) }
    }
    var count: Int { lock.withLock { started } }
    func release(failing: Bool = false) { lock.withLock { fail = failing; released = true } }
  }
  private func fixture(saved: Bool = false) throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PrintroomImport-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for index in 0..<5 { try Data([1, 2, 3]).write(to: folder.appendingPathComponent("\(index).ARW")) }
    if saved {
      var roll = try ProjectStore.open(folder: folder)
      roll.frames[0].adjustments.timing.red = 27
      try ProjectStore.save(roll, folder: folder, expectedModification: nil)
    }
    return folder
  }
  private func until(_ ready: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(8))
    while !ready(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    try #require(ready())
  }

  @Test(arguments: [false, true])
  func newAndSavedRollsWaitForEveryProxy(saved: Bool) async throws {
    let folder = try fixture(saved: saved)
    defer { try? FileManager.default.removeItem(at: folder) }
    let gate = Gate(), model = EditorModel()
    defer { gate.release(); model.cancelImport() }
    model.rawProxyLoader = { try gate.load($0) }
    model.open(folder)
    #expect(model.isImporting && model.project == nil)
    try await until { gate.count == 4 }
    #expect(model.importCompleted == 0 && model.importTotal == 5)
    #expect(model.previewImage == nil && model.thumbnails.isEmpty && !model.isLoading)
    model.loadActive() // Menu/reload cannot bypass the barrier.
    #expect(model.project == nil && !model.isLoading)
    gate.release()
    try await until { !model.isImporting }
    #expect(gate.count == 5 && model.importCompleted == 5)
    #expect(model.project?.frames.count == 5)
    if saved { #expect(model.project?.frames[0].adjustments.timing.red == 27) }
    model.returnHome()
  }

  @Test func failureStaysOnImportPageAndRetryRechecksSavedRoll() async throws {
    let folder = try fixture(saved: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let original = try Data(contentsOf: folder.appendingPathComponent(".printroom.json"))
    let gate = Gate(), model = EditorModel()
    model.rawProxyLoader = { try gate.load($0) }
    model.open(folder)
    gate.release(failing: true)
    try await until { model.importFailure != nil }
    #expect(model.isImporting && model.project == nil && model.thumbnails.isEmpty)
    #expect(model.importCompleted == 5)
    #expect(try Data(contentsOf: folder.appendingPathComponent(".printroom.json")) == original)
    let retry = Gate()
    defer { retry.release(); model.cancelImport() }
    model.rawProxyLoader = { try retry.load($0) }
    model.retryImport()
    try await until { retry.count == 4 }
    #expect(model.importCompleted == 0 && model.importFailure == nil && model.project == nil)
    model.cancelImport()
    retry.release()
    try await Task.sleep(for: .milliseconds(80))
    #expect(!model.isImporting && model.project == nil && model.thumbnails.isEmpty)
  }

  @Test func switchingRollRejectsLateImportCompletion() async throws {
    let first = try fixture(), second = try fixture()
    defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
    let oldGate = Gate(), newGate = Gate(), model = EditorModel()
    defer { oldGate.release(); newGate.release(); model.cancelImport() }
    model.rawProxyLoader = { try oldGate.load($0) }
    model.open(first)
    try await until { oldGate.count == 4 }
    model.rawProxyLoader = { try newGate.load($0) }
    model.open(second)
    oldGate.release()
    try await until { newGate.count == 4 }
    #expect(model.isImporting && model.project == nil && model.importCompleted == 0)
    newGate.release()
    try await until { !model.isImporting }
    #expect(model.folder == second && model.project != nil)
    model.returnHome()
  }
}
