import AppKit
import PrintroomCore
import Testing
@testable import PrintroomApp

@Suite(.serialized) @MainActor
struct TimingKeyboardTests {
  private func model() -> EditorModel {
    let defaults = UserDefaults(suiteName: "Printroom.TimingKeyboardTests.\(UUID())")!
    defaults.set("rgb", forKey: TimingMode.preferenceKey)
    let model = EditorModel(timingDefaults: defaults)
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
    #expect(EditorModel.heldTimingCV(elapsed: 0.439) == 0)
    #expect(EditorModel.heldTimingCV(elapsed: 0.44) == 1)
    #expect(EditorModel.heldTimingCV(elapsed: 0.9) == 12)
    #expect(EditorModel.heldTimingCV(elapsed: 1.4) == 25)
    #expect(EditorModel.heldTimingCV(elapsed: 2.4) == 50)
    #expect(EditorModel.heldContrastSteps(elapsed: 0.399) == 0)
    #expect(EditorModel.heldContrastSteps(elapsed: 0.4) == 0)
    #expect(EditorModel.heldContrastSteps(elapsed: 0.499) == 0)
    #expect(EditorModel.heldContrastSteps(elapsed: 0.5) == 1)
    #expect(EditorModel.heldContrastSteps(elapsed: 0.9) == 5)
    #expect(EditorModel.heldContrastSteps(elapsed: 1.4) == 10)
  }

  @Test func tapShiftAndSystemRepeat() async throws {
    let m = model()
    m.startAdjustmentKey("w", contrast: false, shift: false, isRepeat: false) { true }
    m.startAdjustmentKey("w", contrast: false, shift: false, isRepeat: true) { true }
    #expect(m.adjustments.timing.master == 1)
    try await Task.sleep(for: .milliseconds(200))
    #expect(m.adjustments.timing.master == 1)
    m.stopTimingKey("w")
    m.startAdjustmentKey("E", contrast: false, shift: true, isRepeat: false) { true }
    m.stopTimingKey("e")
    #expect(m.adjustments.timing.red == 10)
    m.undo()
    #expect(m.adjustments.timing.red == 0)
    #expect(m.adjustments.timing.master == 1)
  }

  @Test func fixedRateReleaseAndSingleUndo() async throws {
    let m = model()
    m.startAdjustmentKey("w", contrast: false, shift: false, isRepeat: false) { true }
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
    m.startAdjustmentKey("w", contrast: false, shift: false, isRepeat: false) { true }
    m.startAdjustmentKey("s", contrast: false, shift: false, isRepeat: false) { false }
    m.stopTimingKey("w") // Releasing the previous key must not end the new gesture.
    try await Task.sleep(for: .milliseconds(550))
    #expect(m.adjustments.timing.master == 0)
    m.undo()
    #expect(m.adjustments.timing.master == 1)
    m.startAdjustmentKey("w", contrast: false, shift: false, isRepeat: false) { true }
    m.select(m.project!.frames[1].id)
    try await Task.sleep(for: .milliseconds(550))
    #expect(m.project?.frames[0].adjustments.timing.master == 2)
    #expect(m.adjustments.timing.master == 0)
  }

  @Test func contrastTapShiftRepeatAndChannelPairs() {
    let m = model()
    let increments: [(String, WritableKeyPath<ContrastParameters, Float>)] = [
      ("e", \.red), ("d", \.green), ("c", \.blue), ("w", \.master),
    ]
    for (key, path) in increments {
      m.startAdjustmentKey(key, contrast: true, shift: true, isRepeat: false) { true }
      m.startAdjustmentKey(key, contrast: true, shift: true, isRepeat: true) { true }
      m.stopTimingKey(key)
      #expect(m.adjustments.contrast[keyPath: path] == 1.01)
    }
    let decrements: [(String, WritableKeyPath<ContrastParameters, Float>)] = [
      ("q", \.red), ("a", \.green), ("z", \.blue), ("s", \.master),
    ]
    for (key, path) in decrements {
      m.startAdjustmentKey(key, contrast: true, shift: false, isRepeat: false) { true }
      m.stopTimingKey(key)
      #expect(m.adjustments.contrast[keyPath: path] == 1)
    }
    #expect(m.adjustments.timing == TimingParameters())
  }

  @Test func contrastHoldReleaseUndoAndBounds() async throws {
    let m = model()
    m.startAdjustmentKey("e", contrast: true, shift: true, isRepeat: false) { true }
    try await Task.sleep(for: .milliseconds(850))
    m.stopTimingKey("e")
    let value = m.adjustments.contrast.red
    #expect(value > 1.01)
    try await Task.sleep(for: .milliseconds(100))
    #expect(m.adjustments.contrast.red == value)
    m.undo()
    #expect(m.adjustments.contrast.red == 1)
    #expect(!m.canUndo)
    m.redo()
    #expect(m.adjustments.contrast.red == value)
    m.edit { $0.contrast.red = 2; $0.contrast.green = 0.25 }
    m.undoManager.removeAllActions()
    for key in ["e", "a"] {
      m.startAdjustmentKey(key, contrast: true, shift: false, isRepeat: false) { true }
      m.stopTimingKey()
    }
    #expect(m.adjustments.contrast.red == 2)
    #expect(m.adjustments.contrast.green == 0.25)
    #expect(!m.canUndo)
  }

  @Test func contrastStopsOnFrameChangeAndCrop() async throws {
    let m = model()
    m.startAdjustmentKey("e", contrast: true, shift: false, isRepeat: false) { true }
    m.select(m.project!.frames[1].id)
    try await Task.sleep(for: .milliseconds(500))
    #expect(m.project?.frames[0].adjustments.contrast.red == 1.01)
    #expect(m.adjustments.contrast == ContrastParameters())
    m.sourceWidth = 120; m.sourceHeight = 80
    m.previewImage = CGContext(data: nil, width: 120, height: 80,
      bitsPerComponent: 8, bytesPerRow: 120 * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
    m.startAdjustmentKey("w", contrast: true, shift: false, isRepeat: false) { true }
    m.beginCrop()
    #expect(m.isCropping)
    m.startAdjustmentKey("w", contrast: true, shift: false, isRepeat: false) { true }
    try await Task.sleep(for: .milliseconds(500))
    #expect(m.adjustments.contrast.master == 1.01)
  }
}
