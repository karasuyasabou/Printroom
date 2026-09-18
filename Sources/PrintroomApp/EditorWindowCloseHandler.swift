import AppKit
import SwiftUI

/// Route the editor's close action through the same save/export checks as Quit.
struct EditorWindowCloseHandler: NSViewRepresentable {
  func makeNSView(context: Context) -> CloseHandlerView { CloseHandlerView() }
  func updateNSView(_ nsView: CloseHandlerView, context: Context) {}
}

@MainActor final class CloseHandlerView: NSView {
  private let closeDelegate = EditorCloseDelegate()

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard let window, window.delegate !== closeDelegate else { return }
    closeDelegate.original = window.delegate
    window.delegate = closeDelegate
  }
}

@MainActor final class EditorCloseDelegate: NSObject, NSWindowDelegate {
  // AppKit queries Objective-C forwarding synchronously on the UI thread.
  nonisolated(unsafe) weak var original: (any NSWindowDelegate)?
  var requestTermination: () -> Void = { NSApp.terminate(nil) }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    requestTermination()
    // Quit owns termination; if cancelled, keep the editor visible.
    return false
  }

  override func responds(to selector: Selector!) -> Bool {
    super.responds(to: selector) || (original?.responds(to: selector) == true)
  }

  override func forwardingTarget(for selector: Selector!) -> Any? {
    if original?.responds(to: selector) == true { return original }
    return super.forwardingTarget(for: selector)
  }
}
