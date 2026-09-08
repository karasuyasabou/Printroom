// Real EditorView window, local TIFF copies, queued keyboard events and Canvas drags.
import AppKit
import PrintroomCore
import SwiftUI

@main struct CropWindowQA {
  @MainActor static func main() {
    setbuf(stdout, nil)
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    Task { @MainActor in
      do { try await run() }
      catch { print("CROP QA FAILED: \(error)"); exit(1) }
      app.terminate(nil)
    }
    app.run()
  }

  @MainActor static func run() async throws {
    let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("scratch/crop-qa")
    let model = EditorModel()
    let window = NSWindow(contentRect: NSRect(x: 50, y: 60, width: 1200, height: 820),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = "Printroom · Crop QA"
    let host = NSHostingView(rootView: EditorView(model: model))
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    defer { window.orderOut(nil) }
    model.open(output.appendingPathComponent("roll/01-original.tiff"))

    func settle() async throws { try await Task.sleep(for: .milliseconds(350)) }
    func ready() async throws {
      for _ in 0..<300 {
        if let error = model.errorMessage { throw PrintroomError.invalid(error) }
        if !model.isLoading && !model.isRendering && model.previewImage != nil { return }
        try await Task.sleep(for: .milliseconds(100))
      }
      throw PrintroomError.invalid("Crop QA preview timed out")
    }
    func findCanvas(_ view: NSView) -> CanvasView? {
      if let canvas = view as? CanvasView { return canvas }
      return view.subviews.lazy.compactMap { findCanvas($0) }.first
    }
    try await ready()
    try await settle()
    guard let canvas = findCanvas(host) else { throw PrintroomError.invalid("Crop QA canvas missing") }
    func press(_ key: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) async throws {
      for type in [NSEvent.EventType.keyDown, .keyUp] {
        let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
          context: nil, characters: key, charactersIgnoringModifiers: key,
          isARepeat: false, keyCode: code)!
        NSApp.postEvent(event, atStart: false)
      }
      try await settle()
    }
    func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
      NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }
    func drag(_ start: CGPoint, _ end: CGPoint) {
      canvas.mouseDown(with: mouse(.leftMouseDown, start))
      canvas.mouseDragged(with: mouse(.leftMouseDragged, end))
      canvas.mouseUp(with: mouse(.leftMouseUp, end))
    }
    func capture(_ name: String) async throws {
      host.layoutSubtreeIfNeeded()
      canvas.needsDisplay = true
      try await settle()
      print("\(name): size=\(host.bounds.size) canvas=\(canvas.bounds.size) crop=\(String(describing: model.cropDraftGeometry?.rect))")
      guard !CommandLine.arguments.contains("--no-screenshots") else { return }
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
      process.arguments = ["-x", "-o", "-l", String(window.windowNumber),
        output.appendingPathComponent(name + ".png").path]
      try process.run()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else { throw PrintroomError.invalid("Crop QA screenshot failed") }
    }

    try await capture("01-before")
    model.selectAll()
    window.makeFirstResponder(canvas)
    try await press("r", code: 15)
    precondition(model.isCropping && model.selection.selectedFrameIDs.count == 2)
    try await ready()
    try await capture("02-crop-default")
    model.updateCropDraft(FrameCrop(aspect: .sevenSix, width: 0.8, angleDegrees: 4.75))
    try await settle()
    let rect = canvas.cropRect!
    drag(CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.maxX - 38, y: rect.maxY - 25))
    let resized = model.cropDraftGeometry!
    precondition(resized.outputWidth * 6 == resized.outputHeight * 7)
    let moved = canvas.cropRect!
    drag(CGPoint(x: moved.midX, y: moved.midY), CGPoint(x: moved.midX + 14, y: moved.midY - 10))
    precondition(model.cropDraftGeometry!.outputWidth == resized.outputWidth)
    precondition(model.activeFrame?.crop == nil, "Draft must not mutate committed crop")
    try await capture("03-angle-drag-grid")
    window.setContentSize(NSSize(width: 1060, height: 720))
    try await settle()
    precondition(abs(host.bounds.width - 1060) < 1)
    precondition(abs(canvas.bounds.width - 753) < 1)
    try await capture("04-minimum-window")
    let savedDraft = model.cropDraft!
    // Actual sync control is next to Done on the second crop toolbar row.
    let syncPoint = CGPoint(x: canvas.bounds.maxX - 136, y: -21)
    NSApp.postEvent(mouse(.leftMouseDown, syncPoint), atStart: false)
    NSApp.postEvent(mouse(.leftMouseUp, syncPoint), atStart: false)
    try await settle()
    precondition(!model.isCropping, "Actual sync button must finish cropping")
    try await ready()
    precondition(model.project!.frames.allSatisfy { $0.crop == savedDraft })
    try await capture("05-synced-preview")
    model.undo()
    precondition(model.project!.frames.allSatisfy { $0.crop == nil })
    model.redo()
    precondition(model.project!.frames.allSatisfy { $0.crop == savedDraft })
    try await ready()

    window.makeFirstResponder(canvas)
    try await press("r", code: 15)
    try await ready()
    model.resetCropDraft()
    try await press("\u{1b}", code: 53)
    precondition(!model.isCropping && model.activeFrame?.crop == savedDraft)
    try await ready()
    try await press("r", code: 15)
    try await ready()
    model.resetCropDraft()
    try await capture("06-reset-full-draft")
    try await press("\r", code: 36)
    precondition(!model.isCropping && model.activeFrame?.crop == nil)
    precondition(model.project!.frames.filter { $0.crop != nil }.count == 1,
      "Enter applies only to active despite multi-selection")
    model.undo()
    try await ready()
    model.sampling = true
    try await ready()
    precondition(model.displayWidth == model.sourceWidth && model.displayHeight == model.sourceHeight)
    try await capture("07-sampling-full-source")
    model.sampling = false
    try await ready()

    let input = NSTextView(frame: CGRect(x: 0, y: 0, width: 100, height: 25))
    host.addSubview(input)
    window.makeFirstResponder(input)
    try await press("r", code: 15)
    precondition(!model.isCropping, "Text R must not begin crop")
    input.removeFromSuperview()
    window.makeFirstResponder(canvas)
    try await capture("08-final")
    model.flushSave()
    print("PASS: real R/Enter/Esc, 7:6 + 4.75°, corner resize, move, minimum window, actual sync button, group undo/redo, active-only commit, full-source sampling, text focus exclusion")
  }
}
