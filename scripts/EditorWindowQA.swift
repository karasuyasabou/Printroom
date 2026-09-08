import AppKit
import PrintroomCore
import SwiftUI

// Default: layout captures with an in-memory project, without activation.
// --keyboard: a disposable synthetic TIFF roll and queued events in our window.
@main struct EditorWindowQA {
  struct KeyboardBlocked: LocalizedError {
    let detail: String
    var errorDescription: String? { detail }
  }
  @MainActor static func main() {
    setbuf(stdout, nil)
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    app.finishLaunching()
    Task { @MainActor in
      do { try await run() }
      catch let error as KeyboardBlocked {
        print("EDITOR KEYBOARD QA BLOCKED: \(error.localizedDescription)")
        exit(3)
      }
      catch { print("EDITOR UI QA FAILED: \(error)"); exit(1) }
      app.terminate(nil)
    }
    app.run()
  }
  @MainActor static func run() async throws {
    if CommandLine.arguments.contains("--keyboard") {
      try await keyboard()
      return
    }
    let model = EditorModel()
    model.errorMessage = nil
    let frames = (1...4).map { FrameRecord(filename: "frame-\($0).tiff") }
    var project = RollProject()
    project.frames = frames
    model.project = project
    model.selection.click(frames[0].id, ordered: frames.map(\.id))
    model.sourceWidth = 1200
    model.sourceHeight = 800
    var pixels: [SIMD4<Float>] = []
    for y in 0..<400 {
      for x in 0..<600 {
        let value = Float(x + y) / 1000
        pixels.append(SIMD4<Float>(value * 0.75 + 0.1, value * 0.8 + 0.15, value * 0.65 + 0.2, 1))
      }
    }
    let buffer = PixelBuffer(width: 600, height: 400, pixels: pixels)
    let preview = try DisplayImage.make(buffer, profile: nil, diagnostic: true)
    model.previewImage = preview
    model.histogram = try HistogramStatistics.compute(buffer, stage: .final)
    for frame in frames { model.thumbnails[frame.id] = preview }
    let window = NSWindow(contentRect: CGRect(x: 80, y: 70, width: 1060, height: 720),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = "Printroom · UI QA"
    let host = NSHostingView(rootView: EditorView(model: model))
    window.contentView = host
    window.orderFront(nil)
    defer { window.orderOut(nil) }
    func capture(_ name: String) async throws {
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(350))
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
      process.arguments = ["-x", "-o", "-l", String(window.windowNumber),
        "scratch/editor-ui-qa/\(name).png"]
      try process.run()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else { throw PrintroomError.invalid("Screenshot failed") }
      print("Saved \(name): \(host.bounds.size)")
    }
    try await capture("01-final-minimum-window")
    model.stage = .d3
    model.previewImage = preview
    model.histogram = try HistogramStatistics.compute(buffer, stage: .d3)
    model.toggleNeutralPicker()
    try await capture("02-density-neutral-minimum-window")
    model.saveFailure = true
    model.isExporting = true
    model.exportProgress = 0.42
    model.exportDetail = "正在导出 frame-2.tiff · 2 / 4"
    try await capture("03-export-save-status-minimum-window")
    model.isExporting = false
  }

  @MainActor static func keyboard() async throws {
    let session = CGSessionCopyCurrentDictionary() as? [String: Any]
    let frontmost = NSWorkspace.shared.frontmostApplication
    let locked = session?["CGSSessionScreenIsLocked"] as? Bool == true
    let atLogin = frontmost?.bundleIdentifier == "com.apple.loginwindow"
    print("SESSION: frontmost=\(frontmost?.localizedName ?? "nil") locked=\(locked) onConsole=\(String(describing: session?["kCGSessionOnConsoleKey"]))")
    guard !locked, !atLogin else {
      throw KeyboardBlocked(detail: "会话处于登录或锁屏界面；未尝试激活窗口、未发送键鼠事件。解锁后运行 scripts/editor-window-qa.sh --release --skip-build --keyboard。")
    }
    let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("scratch/editor-ui-qa")
    let folder = output.appendingPathComponent("keyboard-roll-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let model = EditorModel()
    guard let assets = model.assets else {
      throw PrintroomError.invalid(model.errorMessage ?? "QA assets unavailable")
    }
    for frame in 1...3 {
      try TIFFCodec.write(url: folder.appendingPathComponent("frame-\(frame).tiff"),
        width: 120, height: 80, profile: assets.profile) { rows in
          var samples: [UInt16] = []
          for y in rows {
            for x in 0..<120 {
              let base = UInt16(15_000 + x * 120 + y * 100 + frame * 300)
              samples += [base, base + 1_200, base + 2_000]
            }
          }
          return samples
        }
    }
    let window = NSWindow(contentRect: CGRect(x: 80, y: 70, width: 1060, height: 720),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = "Printroom · Keyboard QA"
    let host = NSHostingView(rootView: EditorView(model: model))
    window.contentView = host
    defer { model.stopTimingKey(); _ = model.flushSave(); window.orderOut(nil) }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    try await Task.sleep(for: .milliseconds(1500))
    guard NSApp.isActive, window.isKeyWindow, window.isVisible, window.windowNumber > 0 else {
      throw KeyboardBlocked(detail: "一次激活后 QA 窗口未获得焦点；active=\(NSApp.isActive), key=\(window.isKeyWindow), visible=\(window.isVisible), windowNumber=\(window.windowNumber), frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil")。未发送键鼠事件，不继续尝试激活。")
    }
    model.open(folder)
    func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
      guard condition() else { throw PrintroomError.invalid(message) }
    }
    func ready() async throws {
      for _ in 0..<100 {
        if let error = model.errorMessage { throw PrintroomError.invalid(error) }
        if model.hasImage && !model.isRendering && model.histogram != nil {
          host.layoutSubtreeIfNeeded()
          try await Task.sleep(for: .milliseconds(200))
          return
        }
        try await Task.sleep(for: .milliseconds(50))
      }
      throw PrintroomError.invalid("Keyboard QA preview timed out")
    }
    func requireFocus() throws {
      guard NSApp.isActive, window.isKeyWindow, window.isVisible else {
        throw KeyboardBlocked(detail: "QA 过程中窗口失去焦点；立即停止发送事件，不重新激活。")
      }
    }
    func press(_ characters: String, code: UInt16,
               modifiers: NSEvent.ModifierFlags = [], repeatKey: Bool = false) async throws {
      try requireFocus()
      for type in [NSEvent.EventType.keyDown, .keyUp] {
        guard let event = NSEvent.keyEvent(with: type, location: .zero,
          modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: window.windowNumber, context: nil, characters: characters,
          charactersIgnoringModifiers: characters, isARepeat: repeatKey, keyCode: code)
        else { throw PrintroomError.invalid("QA key event creation failed") }
        try require(event.window === window, "QA key event did not resolve to its own window")
        NSApp.postEvent(event, atStart: false)
      }
      try await Task.sleep(for: .milliseconds(180))
    }
    func click(windowPoint: CGPoint) async throws {
      try requireFocus()
      for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        guard let event = NSEvent.mouseEvent(with: type, location: windowPoint,
          modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: window.windowNumber, context: nil, eventNumber: 1,
          clickCount: 1, pressure: 1)
        else { throw PrintroomError.invalid("QA mouse event creation failed") }
        NSApp.postEvent(event, atStart: false)
      }
      try await Task.sleep(for: .milliseconds(250))
    }
    func descendants(_ view: NSView) -> [NSView] {
      [view] + view.subviews.flatMap(descendants)
    }
    try await ready()
    // SwiftUI does not always materialize an accessibility tree until a client
    // requests it. Use the actual layout and verify each click's model effect.
    let filmstripPoint = CGPoint(x: 220, y: host.isFlipped ? host.bounds.height - 75 : 75)
    try await click(windowPoint: host.convert(filmstripPoint, to: nil))
    try require(model.activeFrame?.filename == "frame-2.tiff", "Filmstrip click did not change the active frame")
    try await ready()
    try require(!(window.firstResponder is NSTextView), "Filmstrip click left a text editor focused")
    try await press("w", code: 13)
    try require(model.adjustments.timing.master == 1, "W after Filmstrip click must set Timing Master to 1")
    print("PASS: Filmstrip click → W sets Timing Master +1 CV")
    try await press("´", code: 14, modifiers: [.option])
    try require(abs(model.adjustments.contrast.red - 1.01) < 0.00001,
      "Option-E must set Contrast R to 1.01")
    try require(model.adjustments.timing.red == 0, "Option-E must preserve Timing R")
    print("PASS: Option-E dead-key event sets Contrast R +0.01")
    try await press("´", code: 14, modifiers: [.option, .shift])
    try require(abs(model.adjustments.contrast.red - 1.02) < 0.00001,
      "Option-Shift-E must increment Contrast R by only 0.01")
    print("PASS: Option-Shift-E also increments only 0.01")
    try await ready()
    guard let masterSlider = descendants(host).compactMap({ $0 as? ChannelSlider })
      .first(where: { $0.toolTip == "Color Timing Master" }) else {
      throw PrintroomError.invalid("QA Color Timing Master native slider missing")
    }
    let masterFrame = masterSlider.convert(masterSlider.bounds, to: nil)
    // The value field sits 16 px from the inspector edge, with a 56 px width.
    try await click(windowPoint: CGPoint(x: host.bounds.width - 44, y: masterFrame.midY))
    guard let editor = window.firstResponder as? NSTextView else {
      throw PrintroomError.invalid("Clicking the numeric field did not focus a native text editor")
    }
    let beforeText = model.adjustments
    let beforeSelection = model.selection.selectedFrameIDs
    try await press("a", code: 0, modifiers: [.command])
    try require(model.selection.selectedFrameIDs == beforeSelection,
      "Command-A in the text field must preserve photo selection")
    try await press("w", code: 13)
    try require(model.adjustments == beforeText, "Typing W in the numeric field altered grading")
    try require(editor.string.lowercased().contains("w"), "Numeric field did not receive the typed W")
    try await press("i", code: 34)
    try require(!model.neutralPicking && editor.string.lowercased().contains("i"),
      "Typing I must reach the numeric field without enabling the eyedropper")
    try await press("a", code: 0, modifiers: [.command])
    try await press("1", code: 18)
    try await press("\t", code: 48)
    window.makeFirstResponder(nil)
    try require(model.adjustments == beforeText, "Leaving the numeric field changed the restored value")
    print("PASS: Numeric text field receives W, I and Command-A without tool, grading or photo selection changes")
    try await ready()
    // The 24×20 eyedropper is in the heading, 10 px above the 24 px timing row.
    try await click(windowPoint: CGPoint(x: host.bounds.width - 28, y: masterFrame.midY + 32))
    try require(model.neutralPicking, "Eyedropper button did not enter neutral picking")
    try await press("\u{1b}", code: 53)
    try require(!model.neutralPicking && !model.isNeutralSampling,
      "Escape did not cancel the eyedropper")
    print("PASS: Eyedropper button → Escape cancels picking")
    guard let canvas = descendants(host).compactMap({ $0 as? CanvasView }).first else {
      throw PrintroomError.invalid("QA preview canvas missing")
    }
    let previousPointer = NSEvent.mouseLocation
    let screenHeight = NSScreen.screens[0].frame.maxY
    defer {
      CGWarpMouseCursorPosition(CGPoint(x: previousPointer.x, y: screenHeight - previousPointer.y))
    }
    func movePointer(to point: CGPoint) async throws {
      try requireFocus()
      let screen = window.convertPoint(toScreen: point)
      try require(CGWarpMouseCursorPosition(CGPoint(x: screen.x, y: screenHeight - screen.y)) == .success,
        "QA could not position the cursor in its own window")
      guard let event = NSEvent.mouseEvent(with: .mouseMoved, location: point,
        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, eventNumber: 1,
        clickCount: 0, pressure: 0) else { throw PrintroomError.invalid("QA move event creation failed") }
      NSApp.postEvent(event, atStart: false)
      try await Task.sleep(for: .milliseconds(250))
    }
    let canvasCenter = canvas.convert(CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY), to: nil)
    try await movePointer(to: canvasCenter)
    try require(NSCursor.current === NSCursor.openHand, "Idle preview must show the hand cursor")
    try await press("i", code: 34)
    try require(model.neutralPicking && NSCursor.current === CanvasView.neutralCursor,
      "I must enter the eyedropper and update a stationary pointer")
    try await press("i", code: 34, repeatKey: true)
    try require(model.neutralPicking, "Holding I must not repeatedly toggle the eyedropper")
    if let data = CanvasView.neutralCursor.image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: data), let png = bitmap.representation(using: .png, properties: [:]) {
      try png.write(to: output.appendingPathComponent("05-neutral-cursor.png"))
    }
    try await press("i", code: 34)
    try require(!model.neutralPicking && NSCursor.current === NSCursor.openHand,
      "I must cancel the eyedropper and restore the hand cursor")
    try await press("i", code: 34)
    try await movePointer(to: CGPoint(x: host.bounds.width - 28, y: masterFrame.midY + 32))
    try require(NSCursor.current !== CanvasView.neutralCursor, "Eyedropper cursor leaked into the inspector")
    try await movePointer(to: canvasCenter)
    try require(NSCursor.current === CanvasView.neutralCursor, "Re-entering the canvas must restore the eyedropper")
    try await press("\u{1b}", code: 53)
    try require(NSCursor.current === NSCursor.openHand, "Escape must restore the stationary cursor")
    print("PASS: I toggles eyedropper; cursor updates without movement, restores on Escape and stays inside canvas")
    try await press("i", code: 34)
    try await click(windowPoint: canvasCenter)
    try await ready()
    try require(!model.neutralPicking && !model.isNeutralSampling && NSCursor.current === NSCursor.openHand,
      "Completed neutral sampling must restore the hand cursor without movement")
    print("PASS: Picking a neutral point restores the stationary cursor")
    // Locate the Film Base button relative to the top of the actual canvas.
    let baseButton = CGPoint(x: host.bounds.width - 153,
      y: canvas.convert(CGPoint(x: 0, y: 0), to: nil).y - 20)
    try await click(windowPoint: baseButton)
    try require(model.sampling, "Film Base button did not enter selection")
    try await movePointer(to: canvasCenter)
    try require(NSCursor.current === NSCursor.crosshair, "Film Base selection must show the crosshair")
    try await press("i", code: 34)
    try require(model.sampling && !model.neutralPicking, "I must preserve Film Base mode exclusivity")
    try await click(windowPoint: baseButton)
    try require(!model.sampling && NSCursor.current === NSCursor.openHand,
      "Canceling Film Base selection must restore the stationary cursor")
    print("PASS: Film Base button shows crosshair; I respects exclusivity; cancel restores hand")
    try require(model.project?.frames[0].adjustments == FrameAdjustments(),
      "Keyboard edits leaked into the previous frame")
    try require(model.errorMessage == nil, "Keyboard QA ended with an application error")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", "-o", "-l", String(window.windowNumber),
      output.appendingPathComponent("04-keyboard-regression.png").path]
    try process.run()
    process.waitUntilExit()
    try require(process.terminationStatus == 0, "Keyboard QA screenshot failed")
    print("EDITOR KEYBOARD QA PASSED: real EditorView, active own window, queued AppKit key/mouse events; fixture=\(folder.path)")
  }
}
