import AppKit
import SwiftUI

/// System alert chrome and buttons, with an accessory for settings or live progress.
/// The owner controls dismissal so starting an async operation can keep its sheet open.
struct NativeDialog: NSViewRepresentable {
  var isPresented: Bool
  var title: String
  var message = ""
  var primaryTitle: String?
  var primaryEnabled = true
  var cancelTitle = "取消"
  var primary: () -> Void
  var cancel: () -> Void
  var accessory: AnyView

  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> NSView { NSView() }
  func updateNSView(_ view: NSView, context: Context) {
    context.coordinator.parent = self
    // Wait until SwiftUI has attached the anchor, and avoid publishing inside update.
    DispatchQueue.main.async { [weak view, weak coordinator = context.coordinator] in
      guard let view, let coordinator else { return }
      coordinator.update(window: view.window)
    }
  }
  static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.close() }

  @MainActor final class Coordinator: NSObject {
    var parent: NativeDialog
    private(set) var alert: NSAlert?
    private var host: NSHostingView<AnyView>?
    init(_ parent: NativeDialog) { self.parent = parent }

    func update(window: NSWindow?) {
      guard parent.isPresented else { close(); return }
      guard let window else { return }
      if alert == nil {
        // A preceding confirmation may still be completing its dismissal.
        guard window.attachedSheet == nil else { return }
        let dialog = NSAlert()
        dialog.addButton(withTitle: parent.primaryTitle ?? "确定")
        dialog.addButton(withTitle: parent.cancelTitle)
        let hosting = NSHostingView(rootView: parent.accessory)
        dialog.accessoryView = hosting
        alert = dialog; host = hosting
        configure()
        dialog.beginSheetModal(for: window) { [weak self, weak dialog] _ in
          guard let self, self.alert === dialog else { return }
          self.alert = nil; self.host = nil
        }
        // Override the default close action: the owner decides when to dismiss.
        dialog.buttons[0].target = self; dialog.buttons[0].action = #selector(accept)
        dialog.buttons[1].target = self; dialog.buttons[1].action = #selector(cancel)
      } else { configure() }
    }
    private func configure() {
      guard let alert, let host else { return }
      alert.messageText = parent.title
      alert.informativeText = parent.message
      alert.buttons[0].title = parent.primaryTitle ?? "确定"
      alert.buttons[0].isHidden = parent.primaryTitle == nil
      alert.buttons[0].isEnabled = parent.primaryEnabled && parent.primaryTitle != nil
      alert.buttons[0].keyEquivalent = parent.primaryTitle == nil ? "" : "\r"
      alert.buttons[1].title = parent.cancelTitle
      alert.buttons[1].keyEquivalent = "\u{1b}"
      host.rootView = parent.accessory
      host.setFrameSize(host.fittingSize)
      alert.layout()
    }
    @objc private func accept() { if parent.primaryEnabled { parent.primary() } }
    @objc private func cancel() { parent.cancel() }
    func close() {
      guard let alert else { return }
      self.alert = nil; host = nil
      if let window = alert.window.sheetParent { window.endSheet(alert.window) }
      alert.window.orderOut(nil)
    }
  }
}

extension View {
  func nativeDialog<Accessory: View>(isPresented: Bool, title: String, message: String = "",
    primaryTitle: String? = nil, primaryEnabled: Bool = true, cancelTitle: String = "取消",
    primary: @escaping () -> Void = {}, cancel: @escaping () -> Void,
    @ViewBuilder accessory: () -> Accessory) -> some View {
    background(NativeDialog(isPresented: isPresented, title: title, message: message,
      primaryTitle: primaryTitle, primaryEnabled: primaryEnabled, cancelTitle: cancelTitle,
      primary: primary, cancel: cancel, accessory: AnyView(accessory().frame(width: 300, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true))))
  }
}
