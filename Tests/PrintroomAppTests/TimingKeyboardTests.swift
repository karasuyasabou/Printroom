import AppKit
import PrintroomCore
import Testing
@testable import PrintroomApp

@Suite(.serialized) @MainActor
struct TimingKeyboardTests {
  private func model() -> EditorModel {
    let model = EditorModel()
    var roll = RollProject()
    roll.frames = [FrameRecord(filename: "one.tiff"), FrameRecord(filename: "two.tiff")]
    model.project = roll
    model.selection.click(roll.frames[0].id, ordered: roll.frames.map(\.id))
    model.errorMessage = nil // These model-only checks do not require a Metal device.
    return model
  }

  @Test func fixedRateContract() {
    #expect(EditorModel.heldTimingCV(elapsed: 0.399) == 0)
    #expect(EditorModel.heldTimingCV(elapsed: 0.4) == 0)
    #expect(EditorModel.heldTimingCV(elapsed: 0.45) == 2)
    #expect(EditorModel.heldTimingCV(elapsed: 0.9) == 25)
    #expect(EditorModel.heldTimingCV(elapsed: 1.4) == 50)
    #expect(EditorModel.heldTimingCV(elapsed: 2.4) == 100)
  }

  @Test func tapShiftAndSystemRepeat() async throws {
    let m = model()
    m.startTimingKey("w", shift: false, isRepeat: false) { true }
    m.startTimingKey("w", shift: false, isRepeat: true) { true }
    #expect(m.adjustments.timing.master == 1)
    try await Task.sleep(for: .milliseconds(200))
    #expect(m.adjustments.timing.master == 1)
    m.stopTimingKey("w")
    m.startTimingKey("E", shift: true, isRepeat: false) { true }
    m.stopTimingKey("e")
    #expect(m.adjustments.timing.red == 10)
    m.undo()
    #expect(m.adjustments.timing.red == 0)
    #expect(m.adjustments.timing.master == 1)
  }

  @Test func fixedRateReleaseAndSingleUndo() async throws {
    let m = model()
    m.startTimingKey("w", shift: false, isRepeat: false) { true }
    try await Task.sleep(for: .milliseconds(1400))
    m.stopTimingKey("w")
    let value = m.adjustments.timing.master
    #expect(value > 1) // Wall-clock sleeps may resume late while other integration suites run.
    try await Task.sleep(for: .milliseconds(120))
    #expect(m.adjustments.timing.master == value)
    m.undo()
    #expect(m.adjustments.timing.master == 0)
    m.redo()
    #expect(m.adjustments.timing.master == value)
  }

  @Test func reversalFocusLossAndFrameSwitchStopHold() async throws {
    let m = model()
    m.startTimingKey("w", shift: false, isRepeat: false) { true }
    m.startTimingKey("s", shift: false, isRepeat: false) { false }
    m.stopTimingKey("w") // Releasing the previous key must not end the new gesture.
    try await Task.sleep(for: .milliseconds(550))
    #expect(m.adjustments.timing.master == 0)
    m.undo()
    #expect(m.adjustments.timing.master == 1)
    m.startTimingKey("w", shift: false, isRepeat: false) { true }
    m.select(m.project!.frames[1].id)
    try await Task.sleep(for: .milliseconds(550))
    #expect(m.project?.frames[0].adjustments.timing.master == 2)
    #expect(m.adjustments.timing.master == 0)
  }
}
