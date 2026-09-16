import Foundation
import PrintroomCore
import Testing
@testable import PrintroomApp

@Suite(.serialized) @MainActor
struct RAWEditorIntegrationTests {
  private func until(_ label: String, _ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(120))
    while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
    #expect(predicate(), "\(label)")
    guard predicate() else { throw PrintroomError.invalid(label) }
  }

  @Test func realARWOpenSwitchPersistAndReopen() async throws {
    guard ProcessInfo.processInfo.environment["PRINTROOM_TEST_REAL_RAW"] == "1" else { return }
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let folder = repository.appendingPathComponent("scratch/raw-editor-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    for name in ["DSC07119.ARW", "DSC07120.ARW"] {
      try FileManager.default.copyItem(at: repository.appendingPathComponent("TEST/RAW/\(name)"),
        to: folder.appendingPathComponent(name))
    }
    let model = EditorModel()
    _ = try #require(model.assets)
    model.open(folder)
    try await until("first RAW full-size metadata and editable preview") {
      model.previewImage != nil && !model.isLoading && !model.isRendering && !model.isPreviewPlaceholder
    }
    let frames = try #require(model.project?.frames)
    #expect(frames.count == 2)
    #expect(model.sourceWidth == 7008 && model.sourceHeight == 4672)
    let first = frames[0].id, second = frames[1].id
    #expect(model.activeFrame?.id == first)
    #expect(model.activeFrame?.rawProcessing != nil)
    model.select(second)
    model.select(first)
    model.select(second)
    try await until("latest selected RAW wins rapid switching") {
      model.activeFrame?.id == second && model.previewImage != nil && !model.isLoading
        && !model.isRendering && !model.isPreviewPlaceholder && model.activeFrame?.rawProcessing != nil
    }
    #expect(model.sourceWidth == 7008 && model.sourceHeight == 4672)
    model.edit { $0.timing.red = 23 }
    #expect(model.flushSave())
    let saved = try ProjectStore.open(folder: folder)
    #expect(saved.frames.map(\.id) == [first, second])
    #expect(saved.frames[1].rawProcessing != nil)
    #expect(saved.frames[1].adjustments.timing.red == 23)
    model.open(folder)
    try await until("reopened RAW restores final active frame and preview") {
      model.activeFrame?.id == second && model.previewImage != nil && !model.isLoading
        && !model.isRendering && !model.isPreviewPlaceholder
    }
    #expect(model.project?.frames.map(\.id) == [first, second])
    #expect(model.activeFrame?.adjustments.timing.red == 23)
    #expect(model.activeFrame?.rawProcessing == saved.frames[1].rawProcessing)
    #expect(model.sourceWidth == 7008 && model.sourceHeight == 4672)
    #expect(model.flushSave())
  }
}
