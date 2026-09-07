import AppKit
import SwiftUI

enum ChannelColors {
  static let red = Color(red: 0.92, green: 0.49, blue: 0.43)
  static let green = Color(red: 0.48, green: 0.75, blue: 0.55)
  static let blue = Color(red: 0.47, green: 0.65, blue: 0.88)
}

struct AdjustmentRow: View {
  let title: String
  @Binding var value: Double
  let range: ClosedRange<Double>
  let step: Double
  let fractionDigits: Int
  let color: Color
  let onEditingChanged: (Bool) -> Void

  var body: some View {
    HStack(spacing: 10) {
      AdjustmentSlider(value: $value, range: range, step: step, color: color,
        title: title, onEditingChanged: onEditingChanged)
        .frame(height: 24)
      TextField("", value: Binding(
        get: { value },
        set: { proposed in
          guard proposed.isFinite else { return }
          value = min(range.upperBound, max(range.lowerBound, (proposed / step).rounded() * step))
        }), format: .number.precision(.fractionLength(fractionDigits)))
        .textFieldStyle(.roundedBorder)
        .multilineTextAlignment(.trailing)
        .font(.system(size: 11, design: .monospaced))
        .frame(width: 56)
        .accessibilityLabel("\(title) 数值")
    }.help(title)
  }
}

// Native tracking, focus and accessibility, with no dense tick-mark baseline.
struct AdjustmentSlider: NSViewRepresentable {
  @Binding var value: Double
  let range: ClosedRange<Double>
  let step: Double
  let color: Color
  let title: String
  let onEditingChanged: (Bool) -> Void
  @Environment(\.isEnabled) private var isEnabled

  func makeNSView(context: Context) -> ChannelSlider {
    let slider = ChannelSlider()
    slider.isContinuous = true
    slider.numberOfTickMarks = 0
    slider.target = context.coordinator
    slider.action = #selector(Coordinator.changed(_:))
    slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
    return slider
  }
  func updateNSView(_ slider: ChannelSlider, context: Context) {
    context.coordinator.parent = self
    slider.minValue = range.lowerBound
    slider.maxValue = range.upperBound
    slider.doubleValue = value
    slider.increment = step
    slider.trackFillColor = NSColor(color)
    slider.isEnabled = isEnabled
    slider.editingChanged = onEditingChanged
    slider.setAccessibilityLabel(title)
    slider.toolTip = title
  }
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  @MainActor final class Coordinator: NSObject {
    var parent: AdjustmentSlider
    init(_ parent: AdjustmentSlider) { self.parent = parent }
    @objc func changed(_ sender: NSSlider) {
      let value = (sender.doubleValue / parent.step).rounded() * parent.step
      sender.doubleValue = min(parent.range.upperBound, max(parent.range.lowerBound, value))
      parent.value = sender.doubleValue
    }
  }
}

@MainActor final class ChannelSlider: NSSlider {
  var increment = 1.0
  var editingChanged: ((Bool) -> Void)?
  override func mouseDown(with event: NSEvent) {
    guard isEnabled else { return }
    editingChanged?(true)
    defer { editingChanged?(false) }
    super.mouseDown(with: event)
  }
  private func adjust(_ delta: Double) -> Bool {
    guard isEnabled else { return false }
    doubleValue = min(maxValue, max(minValue, doubleValue + delta))
    sendAction(action, to: target)
    return true
  }
  override func keyDown(with event: NSEvent) {
    switch event.keyCode {
    case 123...126: break // Editor shortcuts own arrows; never adjust a channel.
    default: super.keyDown(with: event)
    }
  }
  override func accessibilityPerformIncrement() -> Bool { adjust(increment) }
  override func accessibilityPerformDecrement() -> Bool { adjust(-increment) }
}
