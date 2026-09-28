import Foundation
import PrintroomCore
import Testing

@testable import PrintroomApp

/// Deliberately ignores cancellation so model generation checks are tested even
/// when an external worker completes after cancellation or after switching rolls.
private actor AutoCropTestGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var released = false
  private(set) var returned = false
  func wait() async {
    if !released {
      await withCheckedContinuation { continuation = $0 }
    }
    returned = true
  }
  func release() {
    released = true
    continuation?.resume()
    continuation = nil
  }
}

@Suite(.serialized) @MainActor
struct AutoCropEditingTests {
  private func fixture(_ model: EditorModel, count: Int = 3) throws -> URL {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PrintroomAutoCrop-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let profile = try #require(model.assets).profile
    for index in 0..<count {
      try TIFFCodec.write(url: folder.appendingPathComponent("\(index).tif"),
                          width: 120, height: 80, profile: profile) { rows in
        [UInt16](repeating: 32768, count: rows.count * 120 * 3)
      }
    }
    return folder
  }

  private func until(_ message: String, _ ready: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(8))
    while !ready(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(ready(), "\(message)")
    guard ready() else { throw PrintroomError.invalid(message) }
  }

  private func loaded(_ model: EditorModel) async throws {
    try await until("preview ready", { !model.isLoading && !model.isRendering && model.hasImage })
  }

  nonisolated private static func outputs(_ inputs: [AutoCropInput], _ targets: Set<UUID>) throws -> [AutoCropOutput] {
    try inputs.enumerated().compactMap { index, input in
      guard targets.contains(input.id) else { return nil }
      return AutoCropOutput(id: input.id,
        crop: FrameCrop(aspect: .free, width: 0.75, angleDegrees: 0,
                        freeRatio: 1.5),
        needsReview: index != 1, source: try SourceStamp(url: input.url))
    }
  }

  private func installRunner(_ model: EditorModel, gate: AutoCropTestGate? = nil) {
    model.autoCropRunner = { inputs, targets, _, progress in
      let result = try Self.outputs(inputs, targets)
      await progress("fixture ready")
      if let gate { await gate.wait() }
      return result
    }
  }

  @Test func specifiedRatioIsValidatedAndForwarded() async throws {
    let model = EditorModel()
    let folder = try fixture(model)
    defer { try? FileManager.default.removeItem(at: folder) }
    model.open(folder)
    try await loaded(model)
    model.autoCropRunner = { inputs, targets, ratio, _ in
      #expect(ratio == 2.39)
      return try Self.outputs(inputs, targets)
    }
    model.startAutoCrop(aspectRatio: .nan)
    #expect(!model.isAutoCropping)
    #expect(model.errorMessage != nil)
    model.errorMessage = nil
    model.startAutoCrop(aspectRatio: 2.39)
    try await until("ratio batch finished", { !model.isAutoCropping })
    #expect(model.autoCropCompletedRun == 1)
    #expect(model.errorMessage == nil)
  }

  @Test func batchIsOneUndoAndPersistsReviewAndOrigins() async throws {
    let model = EditorModel()
    let folder = try fixture(model)
    defer { try? FileManager.default.removeItem(at: folder) }
    model.open(folder)
    try await loaded(model)
    let before = try #require(model.project)
    installRunner(model)
    model.startAutoCrop(inwardPercent: 2.5)
    try await until("batch finished", { !model.isAutoCropping })
    let applied = try #require(model.project)
    #expect(applied.frames.allSatisfy { $0.crop?.aspect == .free && $0.cropOrigin == .automatic })
    #expect(applied.frames.allSatisfy { abs(($0.crop?.width ?? 0) - 0.7125) < 0.000_001 })
    #expect(applied.frames.map(\.cropNeedsReview) == [true, false, true])
    #expect(model.pendingAutoCropFrameIDs == Set([applied.frames[0].id, applied.frames[2].id]))
    #expect(model.autoCropCompletedRun == 1)
    #expect(model.flushSave())
    #expect(try ProjectStore.open(folder: folder).frames == applied.frames)
    model.undo()
    #expect(model.project?.frames == before.frames)
    #expect(!model.canUndo)
    model.redo()
    #expect(model.project?.frames == applied.frames)
    #expect(model.flushSave())
    #expect(try ProjectStore.open(folder: folder).frames == applied.frames)
    #expect(model.errorMessage == nil)
  }

  @Test func defaultPreservesLegacyCropAndManualFullResetButOverwriteReplacesBoth() async throws {
    let model = EditorModel()
    let folder = try fixture(model, count: 4)
    defer { try? FileManager.default.removeItem(at: folder) }
    model.open(folder)
    try await loaded(model)
    var before = try #require(model.project)
    before.frames[0].crop = FrameCrop(aspect: .square, width: 0.5)
    before.frames[0].cropOrigin = nil // Crop made by a previous application version.
    before.frames[1].crop = nil
    before.frames[1].cropOrigin = .manual // An intentional full-frame reset must stay full-frame.
    before.frames[2].crop = FrameCrop(aspect: .free, width: 0.7, freeRatio: 1.5)
    before.frames[2].cropOrigin = .automatic
    model.project = before
    installRunner(model)
    model.startAutoCrop()
    try await until("default finished", { !model.isAutoCropping })
    #expect(model.project?.frames[0] == before.frames[0])
    #expect(model.project?.frames[1] == before.frames[1])
    #expect(model.project?.frames[2] == before.frames[2])
    #expect(model.project?.frames[3].cropOrigin == .automatic)
    let preserved = try #require(model.project)
    model.startAutoCrop(preserveExisting: false)
    try await until("overwrite finished", { !model.isAutoCropping })
    #expect(model.project?.frames.allSatisfy { $0.cropOrigin == .automatic && $0.crop != nil } == true)
    model.undo()
    #expect(model.project?.frames == preserved.frames)
    #expect(model.errorMessage == nil)
  }

  @Test func explicitFullFrameResetIsRememberedAndProtected() async throws {
    let model = EditorModel()
    let folder = try fixture(model, count: 2)
    defer { try? FileManager.default.removeItem(at: folder) }
    model.open(folder)
    try await loaded(model)
    model.beginCrop()
    try await loaded(model)
    model.resetCropDraft()
    model.commitCrop()
    try await loaded(model)
    #expect(model.activeFrame?.crop == nil)
    #expect(model.activeFrame?.cropOrigin == .manual)
    installRunner(model)
    model.startAutoCrop()
    try await until("reset-protected batch finished", { !model.isAutoCropping })
    #expect(model.project?.frames[0].crop == nil)
    #expect(model.project?.frames[0].cropOrigin == .manual)
    #expect(model.project?.frames[1].cropOrigin == .automatic)
    #expect(model.flushSave())
    #expect(try ProjectStore.open(folder: folder).frames[0].cropOrigin == .manual)
    #expect(model.errorMessage == nil)
  }

  @Test func pendingReviewSkipsPassedFramesAndConfirmationFinishesLastFrame() async throws {
    let model = EditorModel()
    let folder = try fixture(model)
    defer { try? FileManager.default.removeItem(at: folder) }
    model.open(folder)
    try await loaded(model)
    installRunner(model)
    model.startAutoCrop()
    try await until("batch finished", { !model.isAutoCropping })
    let frames = try #require(model.project?.frames)
    model.reviewAutoCrops()
    try await loaded(model)
    #expect(model.isCropping && model.reviewOnlyPendingCrops)
    #expect(model.activeFrame?.id == frames[0].id)
    model.selectAdjacentFrame(1)
    try await loaded(model)
    #expect(model.activeFrame?.id == frames[2].id)
    #expect(model.pendingAutoCropFrameIDs.count == 2) // Browsing alone is not confirmation.
    model.selectAdjacentFrame(-1)
    try await loaded(model)
    model.performCropPrimaryAction()
    try await loaded(model)
    #expect(model.activeFrame?.id == frames[2].id)
    #expect(model.pendingAutoCropFrameIDs == Set([frames[2].id]))
    #expect(model.project?.frames[0].cropOrigin == .manual)
    model.performCropPrimaryAction()
    try await loaded(model)
    #expect(model.pendingAutoCropFrameIDs.isEmpty)
    #expect(!model.reviewOnlyPendingCrops && !model.isCropping)
    #expect(model.flushSave())
    #expect(try ProjectStore.open(folder: folder).frames.allSatisfy { !$0.cropNeedsReview })
    #expect(model.errorMessage == nil)
  }

  @Test func cancellationAndLateOldRollResultNeverCommit() async throws {
    let model = EditorModel()
    let folder = try fixture(model), other = try fixture(model, count: 1)
    defer {
      try? FileManager.default.removeItem(at: folder)
      try? FileManager.default.removeItem(at: other)
    }
    model.open(folder)
    try await loaded(model)
    let before = try #require(model.project)
    let cancelled = AutoCropTestGate()
    installRunner(model, gate: cancelled)
    model.startAutoCrop()
    try await until("cancel runner entered", { model.autoCropProgressText == "fixture ready" })
    model.cancelAutoCrop()
    await cancelled.release()
    try await Task.sleep(for: .milliseconds(80))
    #expect(await cancelled.returned)
    #expect(model.project?.frames == before.frames && !model.canUndo)
    #expect(!model.isAutoCropping && model.autoCropCompletedRun == 0)

    let oldRoll = AutoCropTestGate()
    installRunner(model, gate: oldRoll)
    model.startAutoCrop()
    try await until("old-roll runner entered", { model.autoCropProgressText == "fixture ready" })
    model.open(other)
    try await loaded(model)
    let newProject = try #require(model.project)
    #expect(newProject.id != before.id)
    await oldRoll.release()
    try await Task.sleep(for: .milliseconds(80))
    #expect(await oldRoll.returned)
    #expect(model.project?.frames == newProject.frames)
    #expect(!model.canUndo && !model.isAutoCropping)
    #expect(model.errorMessage == nil)
  }

  @Test func concurrentCropEditRejectsWholeBatchWhileTimingEditSurvivesSuccess() async throws {
    let model = EditorModel()
    let folder = try fixture(model)
    defer { try? FileManager.default.removeItem(at: folder) }
    model.open(folder)
    try await loaded(model)
    let gate = AutoCropTestGate()
    installRunner(model, gate: gate)
    model.startAutoCrop()
    try await until("runner entered", { model.autoCropProgressText == "fixture ready" })
    model.project?.frames[2].crop = FrameCrop(aspect: .square, width: 0.5)
    model.project?.frames[2].cropOrigin = .manual
    let changed = try #require(model.project)
    await gate.release()
    try await until("conflicting batch rejected", { !model.isAutoCropping })
    #expect(model.errorMessage != nil)
    #expect(model.project?.frames == changed.frames)
    #expect(!model.canUndo)
    model.errorMessage = nil

    let timingGate = AutoCropTestGate()
    installRunner(model, gate: timingGate)
    model.startAutoCrop(preserveExisting: false)
    try await until("timing runner entered", { model.autoCropProgressText == "fixture ready" })
    model.edit { $0.timing.red = 23 }
    model.endAdjustment()
    let timed = try #require(model.project)
    await timingGate.release()
    try await until("timing-safe batch finished", { !model.isAutoCropping })
    #expect(model.activeFrame?.adjustments.timing.red == 23)
    #expect(model.project?.frames.allSatisfy { $0.cropOrigin == .automatic } == true)
    model.undo()
    #expect(model.project?.frames == timed.frames)
    #expect(model.errorMessage == nil)
  }

  @Test func incompleteResultRejectsWholeBatch() async throws {
    let model = EditorModel()
    let folder = try fixture(model)
    defer { try? FileManager.default.removeItem(at: folder) }
    model.open(folder)
    try await loaded(model)
    let before = try #require(model.project)
    model.autoCropRunner = { inputs, targets, _, _ in
      Array(try Self.outputs(inputs, targets).dropLast())
    }
    model.startAutoCrop()
    try await until("incomplete batch rejected", { !model.isAutoCropping })
    #expect(model.errorMessage != nil)
    #expect(model.project?.frames == before.frames)
    #expect(!model.canUndo)
  }
}
