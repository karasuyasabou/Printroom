// Real EditorView window, local TIFF copies, queued keyboard events and Canvas drags.
import AppKit
import PrintroomCore
import SwiftUI

@main struct CropWindowQA {
  @MainActor static func main() {
    setbuf(stdout, nil)
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    app.finishLaunching()
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
    if !CommandLine.arguments.contains("--layout-only") { NSApp.activate() }
    defer { window.orderOut(nil) }
    model.open(output.appendingPathComponent("roll/01-original.tiff"))

    func settle() async throws { try await Task.sleep(for: .milliseconds(350)) }
    func state(_ label: String) {
      print("STATE \(label): activeApp=\(NSApp.isActive) key=\(window.isKeyWindow) visible=\(window.isVisible) policy=\(NSApp.activationPolicy().rawValue) frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil") firstResponder=\(String(describing: window.firstResponder)) crop=\(model.isCropping) selected=\(model.selection.selectedFrameIDs.count) activeFrame=\(model.activeFrame?.filename ?? "nil") anchor=\(String(describing: model.selection.anchorID)) source=\(model.sourceWidth)x\(model.sourceHeight) error=\(model.errorMessage ?? "nil")")
    }
    func activateWindow() async throws {
      if NSApp.isActive && window.isKeyWindow && window.isVisible { return }
      if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.loginwindow" {
        state("desktop session unavailable")
        throw PrintroomError.invalid("图形会话当前停留在登录或锁屏界面；请解锁后重新运行真实键鼠 QA。")
      }
      for _ in 0..<30 {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        try await Task.sleep(for: .milliseconds(100))
        if NSApp.isActive && window.isKeyWindow && window.isVisible { return }
      }
      state("activation failed")
      throw PrintroomError.invalid("Crop QA could not activate the visible key window")
    }
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
      try await activateWindow()
      state("before key \(code)")
      for type in [NSEvent.EventType.keyDown, .keyUp] {
        let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
          context: nil, characters: key, charactersIgnoringModifiers: key,
          isARepeat: false, keyCode: code)!
        NSApp.postEvent(event, atStart: false)
      }
      try await settle()
      state("after key \(code)")
    }
    func mouse(
      _ type: NSEvent.EventType, _ point: CGPoint, modifiers: NSEvent.ModifierFlags = []
    ) -> NSEvent {
      NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: modifiers,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }

    func clickFilmstrip(_ index: Int, modifiers: NSEvent.ModifierFlags) async throws {
      try await activateWindow()
      state("before Filmstrip \(index) modifiers \(modifiers.rawValue)")
      precondition(NSApp.isActive && window.isKeyWindow && window.isVisible,
        "Queued Filmstrip events require an active visible key window")
      let point = CGPoint(x: 80 + CGFloat(index) * 140, y: canvas.bounds.maxY + 100)
      NSApp.postEvent(mouse(.leftMouseDown, point, modifiers: modifiers), atStart: false)
      NSApp.postEvent(mouse(.leftMouseUp, point, modifiers: modifiers), atStart: false)
      try await settle()
      state("after Filmstrip \(index) modifiers \(modifiers.rawValue)")
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

    if CommandLine.arguments.contains("--transition-only") {
      window.setContentSize(NSSize(width: 1060, height: 720))
      try await settle()
      let viewport = canvas.convert(canvas.bounds, to: host)
      func stableCanvas() {
        host.layoutSubtreeIfNeeded()
        precondition(findCanvas(host) === canvas)
        precondition(canvas.convert(canvas.bounds, to: host) == viewport)
        precondition(model.previewImage != nil)
      }
      try await capture("transition-01-before")
      window.makeFirstResponder(canvas)
      try await press("r", code: 15)
      try await ready()
      stableCanvas()
      precondition(model.isCropping)
      model.updateDisplayedCropDraft(FrameCrop(aspect: .sevenSix, width: 0.7,
        angleDegrees: 4.75, geometryVersion: 1))
      try await settle()
      let rect = canvas.cropRect!
      drag(CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.maxX - 30, y: rect.maxY - 20))
      try await capture("transition-02-cropping")
      let draft = model.cropDraft
      try await press("\r", code: 36)
      try await ready()
      stableCanvas()
      precondition(!model.isCropping && model.activeFrame?.crop == draft)
      try await capture("transition-03-committed")
      try await press("r", code: 15)
      try await ready()
      stableCanvas()
      model.resetCropDraft()
      try await press("\u{1b}", code: 53)
      try await ready()
      stableCanvas()
      precondition(!model.isCropping && model.activeFrame?.crop == draft)
      try await capture("transition-04-cancelled")
      model.flushSave()
      print("PASS: R/Enter/Esc, corner drag, crop reopen/cancel, same CanvasView and viewport at 1060x720")
      return
    }

    if CommandLine.arguments.contains("--layout-only") {
      print("LAYOUT ONLY: direct model setup for visual layout; real keyboard and mouse QA is NOT RUN")
      model.beginCrop()
      try await ready()
      model.updateDisplayedCropDraft(FrameCrop(aspect: .sevenSix, width: 0.8,
        angleDegrees: 4.75, geometryVersion: 1))
      model.selectAll()
      window.setContentSize(NSSize(width: 1060, height: 720))
      try await settle()
      state("layout-only minimum window")
      precondition(abs(host.bounds.width - 1060) < 1)
      precondition(abs(canvas.bounds.width - 753) < 1)
      let viewport = canvas.convert(canvas.bounds, to: host)
      let top = host.isFlipped ? viewport.minY : host.bounds.height - viewport.maxY
      precondition(abs(top - 104) <= 2, "Crop controls must replace the existing 38 px toolbar")
      try await capture("layout-only-minimum-window")
      print("LAYOUT CHECK COMPLETE: 1060x720 window, 753 px preview column, one 38 px crop row. Real keyboard/mouse/sync-click checks remain NOT RUN.")
      return
    }

    try await capture("01-before")
    try await activateWindow()
    window.makeFirstResponder(canvas)
    try await press("r", code: 15)
    precondition(model.isCropping && model.selection.selectedFrameIDs.count == 1)
    try await ready()
    try await capture("02-crop-default")
    model.updateDisplayedCropDraft(FrameCrop(aspect: .sevenSix, width: 0.8,
      angleDegrees: 4.75, geometryVersion: 1))
    try await settle()
    let frameIDs = model.project!.frames.map(\.id)
    precondition(frameIDs.count == 2 && model.selection.activeFrameID == frameIDs[0])
    let activeBeforeSelection = model.selection.activeFrameID
    let anchorBeforeSelection = model.selection.anchorID
    let draftBeforeSelection = model.cropDraft
    let previewBeforeSelection = model.previewImage
    let zoomBeforeSelection = canvas.zoom
    let panBeforeSelection = canvas.pan
    func unchangedSource(_ selected: Set<UUID>) {
      print("CHECK modified selection: expected=\(selected), actual=\(model.selection.selectedFrameIDs), activeSame=\(model.selection.activeFrameID == activeBeforeSelection), anchorSame=\(model.selection.anchorID == anchorBeforeSelection), draftSame=\(model.cropDraft == draftBeforeSelection), previewSame=\(model.previewImage === previewBeforeSelection)")
      precondition(model.selection.selectedFrameIDs == selected, "Modified click must update batch targets")
      precondition(model.selection.activeFrameID == activeBeforeSelection,
        "Modified click must preserve the current preview frame")
      precondition(model.selection.anchorID == anchorBeforeSelection,
        "Modified click must preserve the ordinary-click range anchor")
      precondition(model.isCropping && model.cropDraft == draftBeforeSelection,
        "Modified click must preserve the unfinished crop draft")
      precondition(model.previewImage === previewBeforeSelection,
        "Modified click must preserve the displayed preview")
      precondition(canvas.zoom == zoomBeforeSelection && canvas.pan == panBeforeSelection,
        "Modified click must preserve the crop viewport")
    }
    try await clickFilmstrip(1, modifiers: .command)
    unchangedSource(Set(frameIDs))
    try await clickFilmstrip(1, modifiers: .command)
    unchangedSource([frameIDs[0]])
    try await clickFilmstrip(0, modifiers: .command)
    unchangedSource([frameIDs[0]]) // Command-clicking the editing source is a no-op.
    try await clickFilmstrip(1, modifiers: .shift)
    unchangedSource(Set(frameIDs))
    try await clickFilmstrip(0, modifiers: .shift)
    unchangedSource([frameIDs[0]])
    try await clickFilmstrip(1, modifiers: [.command, .shift])
    unchangedSource(Set(frameIDs))
    try await capture("02b-modified-selection")
    print("PASS: actual Command/Shift/Command-Shift Filmstrip clicks preserve active, anchor, crop draft and preview; Command removes only other frames")
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
    // Actual sync control sits next to Done in the single 38 px crop toolbar row.
    let syncPoint = CGPoint(x: canvas.bounds.maxX - 100, y: -20)
    try await activateWindow()
    state("before sync click")
    NSApp.postEvent(mouse(.leftMouseDown, syncPoint), atStart: false)
    NSApp.postEvent(mouse(.leftMouseUp, syncPoint), atStart: false)
    try await settle()
    state("after sync click")
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
    print("PASS: real R/Enter/Esc, Command/Shift/Command-Shift selection, 7:6 + 4.75°, corner resize, move, single-row minimum window, actual sync button, group undo/redo, active-only commit, full-source sampling, text focus exclusion")
  }
}
