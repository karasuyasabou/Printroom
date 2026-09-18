import AppKit
import SwiftUI

/// Place inside scroll content so only its enclosing scroll view is configured.
/// Overlay scrollers fade when idle and do not consume the content's width/height.
struct OverlayScrollbars: NSViewRepresentable {
  func makeNSView(context: Context) -> ScrollbarConfigurationView {
    ScrollbarConfigurationView()
  }

  func updateNSView(_ view: ScrollbarConfigurationView, context: Context) {
    view.configureScrollView()
  }
}

final class ScrollbarConfigurationView: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    configureScrollView()
    // SwiftUI can finish attaching the surrounding scroll view after this callback.
    DispatchQueue.main.async { [weak self] in self?.configureScrollView() }
  }

  override func layout() {
    super.layout()
    configureScrollView()
  }

  func configureScrollView() {
    guard let scrollView = enclosingScrollView else { return }
    if scrollView.scrollerStyle != .overlay { scrollView.scrollerStyle = .overlay }
    if !scrollView.autohidesScrollers { scrollView.autohidesScrollers = true }
  }
}
