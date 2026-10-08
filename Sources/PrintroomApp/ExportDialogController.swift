import AppKit

/// Keep the settings sheet attached while exporting and show its result in place.
@MainActor final class ExportDialogController: NSObject {
  let alert = NSAlert()
  let options: ExportOptionsView
  private let start: () -> Void
  private let cancel: () -> Void
  private let close: () -> Void
  private var running = false
  private var finished = false

  init(options: ExportOptionsView, start: @escaping () -> Void,
    cancel: @escaping () -> Void, close: @escaping () -> Void) {
    self.options = options
    self.start = start
    self.cancel = cancel
    self.close = close
    super.init()
    alert.messageText = "导出设置"
    alert.accessoryView = options
    alert.addButton(withTitle: "导出")
    alert.addButton(withTitle: "取消")
    options.validityChanged = { [weak self] valid in
      guard let self else { return }
      self.alert.buttons[0].isEnabled = valid && !self.running && !self.finished
    }
    options.refreshValidity()
  }

  func present(on window: NSWindow) {
    alert.beginSheetModal(for: window) { [weak self] _ in self?.close() }
    alert.buttons[0].target = self
    alert.buttons[0].action = #selector(accept)
    alert.buttons[1].target = self
    alert.buttons[1].action = #selector(cancelOrClose)
  }

  @objc private func accept() {
    guard !running, !finished, options.isValid else { return }
    options.window?.makeFirstResponder(nil)
    start()
  }

  @objc private func cancelOrClose() {
    if running {
      alert.buttons[1].isEnabled = false
      cancel()
    } else { dismiss() }
  }

  func showProgress(fraction: Double, detail: String) {
    let wasRunning = running
    running = true
    options.setExporting(true)
    options.showProgress(fraction: fraction, detail: detail)
    alert.buttons[0].isEnabled = false
    alert.buttons[0].isHidden = true
    alert.buttons[0].keyEquivalent = ""
    alert.buttons[1].title = "取消导出"
    if !wasRunning { alert.layout() }
  }

  func finish(message: String, detail: String? = nil) {
    running = false
    finished = true
    options.setExporting(true)
    options.showResult(message, detail: detail)
    alert.buttons[0].isEnabled = false
    alert.buttons[0].isHidden = true
    alert.buttons[0].keyEquivalent = ""
    alert.buttons[1].title = "关闭"
    alert.buttons[1].isEnabled = true
    alert.buttons[1].keyEquivalent = "\r"
    alert.layout()
  }

  func dismiss() {
    guard !running else { return }
    if let parent = alert.window.sheetParent { parent.endSheet(alert.window) }
    alert.window.orderOut(nil)
  }
}
