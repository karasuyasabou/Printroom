import AppKit
import SwiftUI

// Window-scoped routing runs before native sliders consume arrow keys.
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
    guard window != nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
      let handled = MainActor.assumeIsolated { self?.handle(event) == true }
      return handled ? nil : event
    }
  }
  func stopMonitoring() {
    model?.stopTimingKey()
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
  }
  func handle(_ event: NSEvent) -> Bool {
    if event.type == .keyUp {
      model?.stopTimingKey(event.charactersIgnoringModifiers ?? "")
      return false
    }
    if event.type != .keyDown {
      model?.stopTimingKey()
      return false
    }
    let timingKey = event.charactersIgnoringModifiers?.lowercased() ?? ""
    if timingKey.count != 1 || !"qeadzcws".contains(timingKey)
      || !event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
      model?.stopTimingKey()
    }
    guard let window, event.window === window, window.isKeyWindow,
      window.attachedSheet == nil, NSApp.modalWindow == nil,
      !(window.firstResponder is NSTextView),
      let model, model.errorMessage == nil, !model.showExportSummary
    else { return false }
    let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
    let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
    if modifiers == [.command], key == "f" {
      model.changeOrientation(.flipHorizontal)
      return true
    }
    guard modifiers.isEmpty else { return false }
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
