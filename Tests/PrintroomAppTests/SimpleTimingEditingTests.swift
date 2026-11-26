import AppKit
import PrintroomCore
import Testing
import SwiftUI
@testable import PrintroomApp

@Suite(.serialized) @MainActor
struct SimpleTimingEditingTests {
  private func model(_ defaults: UserDefaults) throws -> EditorModel {
    let m = EditorModel(timingDefaults: defaults)
    var p = RollProject()
    p.frames = [FrameRecord(filename: "one.tif"), FrameRecord(filename: "two.tif")]
    p.calibration = try Pipeline.calibrate(
      image: LinearImage(width: 4, height: 4, samples: [UInt16](repeating: 32768, count: 48)),
      rect: .init(x: 0, y: 0, width: 4, height: 4), matrix: p.calibration.matrix,
      sourceFrameID: p.frames[0].id, cmosMatrix: p.calibration.cmosMatrix)
    m.project = p
    m.selection.click(p.frames[0].id, ordered: p.frames.map(\.id))
    m.errorMessage = nil
    return m
  }
  @Test func nativeSliderPreservesInheritedHalfStep() throws {
    _ = NSApplication.shared
    var timing = TimingParameters(red: 1)
    let slider = AdjustmentSlider(
      value: Binding(get: { SimpleTimingAxis.temperature.displayedValue(in: timing) },
        set: { timing = SimpleTimingAxis.temperature.setting($0, in: timing) }),
      range: -512...512, step: 1, color: .orange, title: "色温",
      onEditingChanged: { _ in }, quantizesValue: false)
    let coordinator = slider.makeCoordinator()
    let native = ChannelSlider()
    native.minValue = -512; native.maxValue = 512
    native.resetValue = 0
    native.target = coordinator
    native.action = #selector(AdjustmentSlider.Coordinator.changed(_:))
    native.doubleValue = 2
    coordinator.changed(native)
    #expect(timing == TimingParameters(red: 2, blue: -1))
    #expect(native.doubleValue == 2)
    native.doubleValue = 1
    coordinator.changed(native)
    #expect(timing == TimingParameters(red: 1))
    #expect(native.doubleValue == 1)

    let doubleClick = try #require(NSEvent.mouseEvent(with: .leftMouseDown,
      location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
      context: nil, eventNumber: 0, clickCount: 2, pressure: 1))
    native.mouseDown(with: doubleClick)
    #expect(SimpleTimingAxis.temperature.value(in: timing) == -0.5)
    #expect(native.doubleValue == 0)
    let reset = timing
    native.doubleValue = 100
    native.mouseDown(with: doubleClick)
    #expect(timing == reset)
    #expect(native.doubleValue == 0)

    timing = TimingParameters(red: 512, green: -512, blue: 512)
    native.doubleValue = 1
    coordinator.changed(native)
    #expect(native.doubleValue == 0)
    #expect(timing == TimingParameters(red: 512, green: -512, blue: 512))
  }
  @Test func fractionalTimingKeysMoveVisibleValueOneStepAcrossZero() throws {
    let suite = "Printroom.SimpleTiming.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let m = try model(defaults)
    let source = TimingParameters(red: 1, green: -1, blue: 1)
    for (axis, decrease, increase, timing) in [
      (SimpleTimingAxis.exposure, "s", "w", source),
      (.temperature, "q", "e", TimingParameters(red: 1)),
      (.tint, "a", "d", TimingParameters(red: 1, green: -1))
    ] {
      m.edit { $0.timing = timing }
      let initial = axis.displayedValue(in: timing)
      for step in 1...3 {
        m.startAdjustmentKey(decrease, contrast: false, shift: false, isRepeat: false) { true }
        m.stopTimingKey(decrease)
        #expect(axis.displayedValue(in: m.adjustments.timing) == initial - Double(step))
      }
      m.startAdjustmentKey(increase, contrast: false, shift: true, isRepeat: false) { true }
      m.stopTimingKey(increase)
      #expect(axis.displayedValue(in: m.adjustments.timing) == initial + 7)
      m.setSimpleTiming(axis, value: 0)
      let reset = m.adjustments.timing
      let displayed = axis.displayedValue(in: reset)
      #expect(displayed == 0)
      #expect(displayed.sign == .plus)
      #expect(abs(axis.value(in: reset)) <= 0.5)
      m.setSimpleTiming(axis, value: 0)
      #expect(m.adjustments.timing == reset)
      for other in SimpleTimingAxis.allCases where other != axis {
        #expect(abs(other.value(in: reset) - other.value(in: timing)) < 1e-12)
      }
    }
  }
  @Test func modePersistsWithoutEditingAndCancelsHold() async throws {
    let suite = "Printroom.SimpleTiming.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let m = try model(defaults)
    #expect(m.timingMode == .simple)
    m.edit { $0.timing = .init(master: 40, red: 3, green: -7, blue: 8) }
    m.undoManager.removeAllActions()
    let before = m.project!.frames
    for _ in 0..<20 { m.timingMode = .rgb; m.timingMode = .simple }
    #expect(m.project!.frames == before)
    #expect(!m.canUndo)
    m.timingMode = .rgb
    m.select(m.project!.frames[1].id)
    #expect(m.timingMode == .rgb)
    #expect(try model(defaults).timingMode == .rgb)
    m.startAdjustmentKey("e", contrast: false, shift: false, isRepeat: false) { true }
    m.timingMode = .simple
    let after = m.adjustments
    try await Task.sleep(for: .milliseconds(600))
    #expect(m.adjustments == after)
    m.undo()
    #expect(m.adjustments.timing == TimingParameters())
    #expect(m.timingMode == .simple)
  }
  @Test func simplePairsDisabledKeysContrastAndGesture() async throws {
    let suite = "Printroom.SimpleTiming.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let m = try model(defaults)
    for key in ["z", "c"] {
      m.startAdjustmentKey(key, contrast: false, shift: true, isRepeat: false) { true }; m.stopTimingKey()
    }
    #expect(!m.canUndo)
    for (key, expected) in [("e", TimingParameters(red: 10, blue: -10)),
                            ("d", TimingParameters(red: 10, green: -20, blue: 10)),
                            ("w", TimingParameters(master: 10))] {
      m.startAdjustmentKey(key, contrast: false, shift: true, isRepeat: false) { true }; m.stopTimingKey()
      #expect(m.adjustments.timing == expected)
      m.undo()
      #expect(m.adjustments.timing == TimingParameters())
    }
    for (positive, negative) in [("e", "q"), ("d", "a"), ("w", "s")] {
      m.handleTimingKey(positive); m.handleTimingKey(negative)
      #expect(m.adjustments.timing == TimingParameters())
    }
    for mode in TimingMode.allCases {
      m.timingMode = mode
      for key in ["e", "d", "c", "w"] {
        m.startAdjustmentKey(key, contrast: true, shift: true, isRepeat: false) { true }
        m.stopTimingKey()
      }
      #expect(m.adjustments.contrast == ContrastParameters(master: 1.01, red: 1.01, green: 1.01, blue: 1.01))
      for key in ["q", "a", "z", "s"] {
        m.startAdjustmentKey(key, contrast: true, shift: false, isRepeat: false) { true }
        m.stopTimingKey()
      }
      #expect(m.adjustments.contrast == ContrastParameters())
    }
    m.timingMode = .simple
    m.undoManager.removeAllActions()
    m.beginAdjustment()
    for value in [10.0, 20, 30] { m.setSimpleTiming(.tint, value: value) }
    m.endAdjustment()
    #expect(m.adjustments.timing == TimingParameters(red: 30, green: -60, blue: 30))
    let encoded = try JSONEncoder().encode(m.project!)
    #expect(try JSONDecoder().decode(RollProject.self, from: encoded).frames == m.project!.frames)
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SimpleTiming-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    for name in ["one.tif", "two.tif"] {
      try TIFFCodec.write(url: folder.appendingPathComponent(name), width: 2, height: 2, profile: try #require(m.assets).profile) {
        rows in [UInt16](repeating: 20000, count: rows.count * 6)
      }
    }
    m.folder = folder
    m.copyParameters()
    m.select(m.project!.frames[1].id)
    m.applyParameters()
    #expect(m.adjustments.timing == TimingParameters(red: 30, green: -60, blue: 30))
    m.undo()
    #expect(m.adjustments.timing == TimingParameters())
    m.select(m.project!.frames[0].id)
    m.undo()
    #expect(m.adjustments.timing == TimingParameters())
    #expect(!m.canUndo)
    try await Task.sleep(for: .milliseconds(400))
  }
}
