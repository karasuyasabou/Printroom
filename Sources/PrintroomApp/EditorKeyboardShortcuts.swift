import AppKit
import SwiftUI

// Window-scoped routing keeps adjustments available after selecting a thumbnail,
// while native text editing and dialogs retain their normal keyboard behavior.
struct EditorKeyboardShortcuts: NSViewRepresentable {
  let model: EditorModel
  func makeNSView(context: Context) -> ShortcutView { ShortcutView(model: model) }
  func updateNSView(_ view: ShortcutView, context: Context) { view.model = model }
  static func dismantleNSView(_ view: ShortcutView, coordinator: ()) { view.stopMonitoring() }
}

@MainActor final class ShortcutView: NSView {
  weak var model: EditorModel?
  private var monitor: Any?
  init(model: EditorModel) {
    self.model = model
    super.init(frame: .zero)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    stopMonitoring()
    guard let window else { return }
    NotificationCenter.default.addObserver(self, selector: #selector(cancelHeldAdjustment),
      name: NSWindow.didResignKeyNotification, object: window)
    NotificationCenter.default.addObserver(self, selector: #selector(cancelHeldAdjustment),
      name: NSApplication.didResignActiveNotification, object: NSApp)
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
      let handled = MainActor.assumeIsolated { self?.handle(event) == true }
      return handled ? nil : event
    }
  }
  func stopMonitoring() {
    model?.stopTimingKey()
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    NotificationCenter.default.removeObserver(self)
  }
  @objc private func cancelHeldAdjustment() { model?.stopTimingKey() }

  static func adjustmentKey(for keyCode: UInt16) -> String? {
    // Option-E and Option-A can produce accents or other special characters.
    // Physical key codes keep the documented pairs stable under Option.
    switch keyCode {
    case 12: return "q"
    case 14: return "e"
    case 0: return "a"
    case 2: return "d"
    case 6: return "z"
    case 8: return "c"
    case 13: return "w"
    case 1: return "s"
    default: return nil
    }
  }

  private var canRouteKeys: Bool {
    guard let window, window.isKeyWindow,
      window.attachedSheet == nil, NSApp.modalWindow == nil,
      !(window.firstResponder is NSTextView),
      let model, model.errorMessage == nil, !model.showExportSummary else { return false }
    return true
  }

  func handle(_ event: NSEvent) -> Bool {
    handle(event, from: event.window)
  }

  func handle(_ event: NSEvent, from eventWindow: NSWindow?) -> Bool {
    if event.type == .keyUp {
      if let key = Self.adjustmentKey(for: event.keyCode) { model?.stopTimingKey(key) }
      return false
    }
    if event.type != .keyDown {
      model?.stopTimingKey()
      return false
    }
    guard let window, eventWindow === window, canRouteKeys, let model else {
      model?.stopTimingKey()
      return false
    }
    let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
    let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
    if let adjustmentKey = Self.adjustmentKey(for: event.keyCode),
      modifiers.intersection([.command, .control]).isEmpty {
      guard !model.isCropping else { model.stopTimingKey(); return true }
      model.startAdjustmentKey(adjustmentKey, contrast: modifiers.contains(.option),
        shift: modifiers.contains(.shift), isRepeat: event.isARepeat) { [weak self] in
          self?.canRouteKeys == true && NSApp.isActive
        }
      return true
    }
    model.stopTimingKey()
    if modifiers == [.command], key == "a" {
      model.selectAll()
      return true
    }
    if modifiers == [.command], key == "f" {
      if !model.isCropping { model.changeOrientation(.flipHorizontal) }
      return true
    }
    guard modifiers.isEmpty else { return false }
    if event.keyCode == 53, model.neutralPicking || model.isNeutralSampling {
      model.cancelNeutralPicker()
      return true
    }
    if key == "i" {
      if !event.isARepeat { model.toggleNeutralPicker() }
      return true
    }
    if key == "r" {
      if !event.isARepeat && !model.isCropping { model.beginCrop() }
      return true
    }
    if model.isCropping {
      switch event.keyCode {
      case 36, 76:
        if !event.isARepeat { model.commitCrop() }
        return true
      case 53:
        model.cancelCrop()
        return true
      // Keep the crop draft and its source fixed until completion or cancellation.
      case 123...126: return true
      default: break
      }
      if ["[", "【", "]", "】"].contains(key) { return true }
    }
    switch event.keyCode {
    case 123: model.selectAdjacentFrame(-1); return true
    case 124: model.selectAdjacentFrame(1); return true
    case 125, 126: return true
    default: break
    }
    switch key {
    case "[", "【": model.changeOrientation(.rotateCounterclockwise); return true
    case "]", "】": model.changeOrientation(.rotateClockwise); return true
    default: return false
    }
  }
}
