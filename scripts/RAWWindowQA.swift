import AppKit
import PrintroomCore
import SwiftUI

@main struct RAWWindowQA {
  @MainActor static func main() {
    setbuf(stdout, nil)
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    app.finishLaunching()
    Task { @MainActor in
      do { try await run(); print("RAW WINDOW QA PASSED"); exit(0) }
      catch { print("RAW WINDOW QA FAILED: \(error)"); exit(1) }
    }
    app.run()
  }
  @MainActor static func run() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let folder = root.appendingPathComponent("scratch/raw-window-qa/roll")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let source = folder.appendingPathComponent("DSC07119.ARW")
    if !FileManager.default.fileExists(atPath: source.path) {
      try FileManager.default.copyItem(at: root.appendingPathComponent("TEST/RAW/DSC07119.ARW"), to: source)
    }
    let model = EditorModel()
    let window = NSWindow(contentRect: CGRect(x: 80, y: 70, width: 1060, height: 720),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = "Printroom · RAW 验收"
    window.contentView = NSHostingView(rootView: EditorView(model: model))
    window.orderFront(nil)
    defer { window.orderOut(nil) }
    model.open(folder)
    let deadline = Date().addingTimeInterval(120)
    while model.previewImage == nil || model.isLoading || model.isRendering {
      if let error = model.errorMessage { throw PrintroomError.invalid(error) }
      guard Date() < deadline else { throw PrintroomError.invalid("RAW preview timeout") }
      try await Task.sleep(for: .milliseconds(50))
    }
    guard model.sourceWidth == 7008, model.sourceHeight == 4672,
      model.activeFrame?.rawProcessing != nil else { throw PrintroomError.invalid("RAW dimensions/identity") }
    try await Task.sleep(for: .milliseconds(500))
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", "-o", "-l", String(window.windowNumber),
      root.appendingPathComponent("scratch/raw-window-qa/editor.png").path]
    try process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw PrintroomError.invalid("Screenshot failed") }
    guard model.flushSave() else { throw PrintroomError.invalid("Project save failed") }
  }
}
