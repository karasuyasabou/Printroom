import AppKit
import PrintroomCore
import Testing
import SwiftUI
@testable import PrintroomApp

@Suite(.serialized) @MainActor
struct SimpleTimingEditingTests {
  private func model(_ defaults: UserDefaults) -> EditorModel {
    let m = EditorModel(timingDefaults: defaults)
    var p = RollProject()
    p.frames = [FrameRecord(filename: "one.tif"), FrameRecord(filename: "two.tif")]
    m.project = p
    m.selection.click(p.frames[0].id, ordered: p.frames.map(\.id))
    m.errorMessage = nil
    return m
  }
  @Test func nativeSliderPreservesInheritedHalfStep() {
    var timing = TimingParameters(red: 1)
    let slider = AdjustmentSlider(
      value: Binding(get: { SimpleTimingAxis.temperature.value(in: timing) },
        set: { timing = SimpleTimingAxis.temperature.setting($0, in: timing) }),
      range: -512...512, step: 1, color: .orange, title: "色温",
      onEditingChanged: { _ in }, quantizesValue: false)
    let coordinator = slider.makeCoordinator()
    let native = ChannelSlider()
    native.minValue = -512; native.maxValue = 512
    native.doubleValue = 1.5
    coordinator.changed(native)
    #expect(timing == TimingParameters(red: 2, blue: -1))
    native.doubleValue = 0.5
    coordinator.changed(native)
    #expect(timing == TimingParameters(red: 1))
    timing = TimingParameters(red: 512, green: -512, blue: 512)
    native.doubleValue = 1
    coordinator.changed(native)
    #expect(native.doubleValue == 0)
    #expect(timing == TimingParameters(red: 512, green: -512, blue: 512))
  }
  @Test func modePersistsWithoutEditingAndCancelsHold() async throws {
    let suite = "Printroom.SimpleTiming.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let m = model(defaults)
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
    #expect(model(defaults).timingMode == .rgb)
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
    let m = model(defaults)
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
