import AppKit
import SwiftUI
import Testing
@testable import PrintroomApp

@Suite(.serialized) @MainActor
struct AdjustmentSliderTests {
  @Test func doubleClickResetsValueAndInvalidatesKnob() throws {
    _ = NSApplication.shared
    for (range, initial, reset, step) in [(-512.0...512.0, 123.0, 0.0, 1.0),
                                         (0.25...2.0, 1.65, 1.0, 0.01)] {
      var value = initial
      var editing: [Bool] = []
      let wrapper = AdjustmentSlider(value: Binding(get: { value }, set: { value = $0 }),
        range: range, step: step, color: .gray, title: "Test",
        onEditingChanged: { editing.append($0) }, resetValue: reset)
      let coordinator = wrapper.makeCoordinator()
      let native = ChannelSlider(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
      let window = NSWindow(contentRect: native.frame, styleMask: [.borderless],
        backing: .buffered, defer: false)
      window.contentView = native
      native.minValue = range.lowerBound
      native.maxValue = range.upperBound
      native.doubleValue = initial
      native.resetValue = reset
      native.target = coordinator
      native.action = #selector(AdjustmentSlider.Coordinator.changed(_:))
      native.editingChanged = wrapper.onEditingChanged
      native.needsDisplay = false
      let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown,
        location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
        context: nil, eventNumber: 0, clickCount: 2, pressure: 1))
      native.mouseDown(with: event)
      #expect(value == reset)
      #expect(native.doubleValue == reset)
      #expect(native.needsDisplay)
      #expect(editing == [true, false])

      native.isEnabled = false
      value = initial
      native.doubleValue = initial
      editing.removeAll()
      native.mouseDown(with: event)
      #expect(value == initial)
      #expect(native.doubleValue == initial)
      #expect(editing.isEmpty)
    }
  }
}
