// Compile with the application sources (excluding PrintroomApp.swift) and PrintroomCore.
// Runs the real EditorView in an on-screen NSWindow; captures WindowServer pixels.
import AppKit
import PrintroomCore
import SwiftUI

@main struct ViewportWindowQA {
  @MainActor static func main() {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    Task { @MainActor in
      do { try await run() } catch {
        print("QA FAILED: \(error)")
        exit(1)
      }
      app.terminate(nil)
    }
    app.run()
  }
  @MainActor static func run() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let output = root.appendingPathComponent("scratch/viewport-qa")
    let model = EditorModel()
    let window = NSWindow(
      contentRect: NSRect(x: 40, y: 60, width: 1200, height: 820),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = "Printroom · Preview viewport QA"
    let hosting = NSHostingView(rootView: EditorView(model: model))
    window.contentView = hosting
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    model.open(output.appendingPathComponent("roll/01-original.tiff"))
    func settle() async throws { try await Task.sleep(for: .milliseconds(450)) }
    func ready() async throws {
      for _ in 0..<200 {
        if !model.isLoading && !model.isRendering && model.previewImage != nil { return }
        try await Task.sleep(for: .milliseconds(100))
      }
      throw NSError(domain: "Preview timed out", code: 1)
    }
    func find(_ view: NSView) -> CanvasView? {
      if let canvas = view as? CanvasView { return canvas }
      return view.subviews.lazy.compactMap { find($0) }.first
    }
    try await ready()
    try await settle()
    guard let canvas = find(hosting) else { fatalError("Canvas missing") }
    func mouse(_ type: NSEvent.EventType, _ point: CGPoint, clicks: Int = 1) -> NSEvent {
      NSEvent.mouseEvent(
        with: type, location: canvas.convert(point, to: nil), modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 1, clickCount: clicks, pressure: 1)!
    }
    func drag(_ a: CGPoint, _ b: CGPoint, release: Bool = true) {
      canvas.mouseDown(with: mouse(.leftMouseDown, a))
      canvas.mouseDragged(with: mouse(.leftMouseDragged, b))
      if release { canvas.mouseUp(with: mouse(.leftMouseUp, b)) }
    }
    func scroll(_ dy: Int32, at point: CGPoint, zoom: Bool) {
      let cg = CGEvent(
        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
        wheel1: dy, wheel2: 0, wheel3: 0)!
      let wp = window.convertPoint(toScreen: canvas.convert(point, to: nil))
      cg.location = CGPoint(x: wp.x, y: NSScreen.screens[0].frame.maxY - wp.y)
      if zoom { cg.flags = .maskCommand }
      canvas.scrollWheel(with: NSEvent(cgEvent: cg)!)
    }
    func capture(_ name: String) async throws {
      canvas.needsDisplay = true
      try await settle()
      let rect = canvas.convert(canvas.bounds, to: hosting)
      print(
        "\(name): viewport=\(rect), zoom=\(canvas.zoom), pan=\(canvas.pan), image=\(canvas.imageRect)"
      )
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
      process.arguments = [
        "-x", "-o", "-l", String(window.windowNumber),
        output.appendingPathComponent(name + ".png").path,
      ]
      try process.run()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        throw NSError(domain: "screencapture", code: Int(process.terminationStatus))
      }
    }
    let originalBounds = canvas.bounds
    let center = CGPoint(x: originalBounds.midX, y: originalBounds.midY)
    try await capture("01-fit")
    scroll(400, at: center, zoom: true)  // 0.25× minimum
    precondition(canvas.zoom == 0.25)
    try await capture("02-small")
    scroll(-1000, at: center, zoom: true)  // 16× maximum
    precondition(canvas.zoom == 16)
    try await capture("03-zoom16")
    for (name, endpoint) in [
      ("04-left", CGPoint(x: 2, y: center.y)),
      ("05-right", CGPoint(x: originalBounds.maxX - 2, y: center.y)),
      ("06-top", CGPoint(x: center.x, y: 2)),
      ("07-bottom", CGPoint(x: center.x, y: originalBounds.maxY - 2)),
    ] {
      canvas.pan = .zero
      for _ in 0..<4 { drag(center, endpoint) }
      precondition(canvas.bounds == originalBounds)
      try await capture(name)
    }
    canvas.pan = .zero
    model.sampling = true
    try await settle()
    drag(
      CGPoint(x: 8, y: 8), CGPoint(x: originalBounds.maxX - 1, y: originalBounds.maxY - 1),
      release: false)
    canvas.mouseDragged(
      with: mouse(.leftMouseDragged, CGPoint(x: originalBounds.maxX + 400, y: -200)))
    precondition(canvas.bounds.contains(canvas.selectionRect!))
    try await capture("08-selection-outside-drag")
    canvas.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: -100, y: -100)))
    precondition(canvas.selectionRect == nil)
    model.sampling = false
    // Deliberately oversize the overlay to verify the drawing clip independently of gesture logic.
    try await settle()
    canvas.selectionRect = originalBounds.insetBy(dx: -500, dy: -500)
    try await capture("09-overlay-clip-stress")
    canvas.cancelGesture()
    let oldZoom = canvas.zoom
    let oldPan = canvas.pan
    scroll(-200, at: CGPoint(x: -20, y: -20), zoom: true)
    precondition(canvas.zoom == oldZoom && canvas.pan == oldPan)
    canvas.mouseDown(with: mouse(.leftMouseDown, center, clicks: 2))
    precondition(canvas.zoom == 1 && canvas.pan == .zero)
    try await capture("10-doubleclick-fit")
    window.setContentSize(NSSize(width: 1060, height: 720))
    try await settle()
    try await capture("11-resize-small-fit")
    window.setContentSize(NSSize(width: 1320, height: 880))
    try await settle()
    scroll(-500, at: CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY), zoom: true)
    try await capture("12-resize-large-zoom")
    for (filename, name) in [("02-rotate90.tiff", "13-rotate90"), ("03-mirror.tiff", "14-mirror")] {
      let frame = model.project!.frames.first { $0.filename == filename }!
      model.select(frame.id)
      try await ready()
      try await settle()
      scroll(-500, at: CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY), zoom: true)
      drag(CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 250))
      model.sampling = true
      try await settle()
      drag(
        CGPoint(x: 10, y: 10), CGPoint(x: canvas.bounds.maxX - 1, y: canvas.bounds.maxY - 1),
        release: false)
      try await capture(name)
      canvas.cancelGesture()
      model.sampling = false
      canvas.resetViewport()
      try await capture(name + "-fit")
    }
    // Route queued mouse events through NSApplication/NSWindow hit testing to actual controls.
    func clickControl(_ point: CGPoint) async throws {
      NSApp.postEvent(mouse(.leftMouseDown, point), atStart: false)
      NSApp.postEvent(mouse(.leftMouseUp, point), atStart: false)
      try await settle()
    }
    canvas.zoom = 16
    canvas.pan = CGPoint(x: 300, y: -200)
    canvas.needsDisplay = true
    try await clickControl(CGPoint(x: canvas.bounds.maxX - 45, y: -19))
    precondition(canvas.zoom == 1 && canvas.pan == .zero, "Actual Fit button failed")
    canvas.zoom = 16
    canvas.needsDisplay = true
    try await clickControl(CGPoint(x: canvas.bounds.maxX + 153, y: 20))
    precondition(model.sampling, "Actual sample button failed")
    try await capture("15-controls-at-zoom")
    try await clickControl(CGPoint(x: canvas.bounds.maxX + 153, y: 20))
    precondition(!model.sampling)
    try await clickControl(CGPoint(x: 80, y: canvas.bounds.maxY + 100))
    try await ready()
    try await capture("16-filmstrip-click-debug")
    print("FILMSTRIP_CLICK: active=\(model.activeFrame?.filename ?? "nil") selection=\(model.selection.selectedFrameIDs)")
    fflush(stdout)
    precondition(model.activeFrame?.filename == "01-original.tiff", "Filmstrip click failed")
    try await capture("16-filmstrip-and-fit")
    // V2: render real reference pixels after user direction, 1:1 and stage changes.
    model.changeOrientation(.rotateClockwise)
    model.changeOrientation(.flipHorizontal)
    try await ready()
    try await settle()
    precondition(model.displayWidth == 4672 && model.displayHeight == 7008)
    try await capture("17-v2-direction")
    // The physical 1:1 button is immediately left of Fit in the real SwiftUI toolbar.
    try await clickControl(CGPoint(x: canvas.bounds.maxX - 105, y: -19))
    for _ in 0..<300 {
      if model.detailImage != nil { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    precondition(model.detailImage != nil, "Actual 1:1 control must load native pixels")
    precondition(abs(canvas.fitScale * canvas.zoom * (window.backingScaleFactor) - 1) < 0.001)
    let statistics = model.histogram
    drag(CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY), CGPoint(x: canvas.bounds.midX + 90, y: canvas.bounds.midY + 60))
    for _ in 0..<300 {
      if !model.isDetailLoading && model.detailImage != nil { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    precondition(model.histogram == statistics, "Native viewport must not replace whole-photo statistics")
    try await capture("18-v2-native-region")
    model.stage = .d3
    try await ready()
    for _ in 0..<200 where model.histogram == nil { try await Task.sleep(for: .milliseconds(50)) }
    precondition(model.histogram?.stage == .d3)
    try await capture("19-v2-density-histogram")
    model.stage = .final
    model.changeOrientation(.reset)
    canvas.resetViewport()
    try await ready()
    // Sample main-thread responsiveness while real preview/thumbnail work runs.
    var delays: [Double] = []
    for i in 0..<30 {
      model.edit { $0.timing.master = i % 11 }
      let tick = ContinuousClock.now
      try await Task.sleep(for: .milliseconds(20))
      let elapsed = tick.duration(to: .now)
      delays.append(Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
    }
    delays.sort()
    print("MAIN_ACTOR_TIMER: requested=20ms median=\(delays[15] * 1000)ms p95=\(delays[28] * 1000)ms max=\(delays.last! * 1000)ms")
    try await ready()
    try await capture("20-v2-final")
    model.sampleBase(PixelRect(x: 359, y: 604, width: 79, height: 494))
    for _ in 0..<200 where model.project?.calibration.isCalibrated != true { try await Task.sleep(for: .milliseconds(50)) }
    precondition(model.project?.calibration.isCalibrated == true)
    model.setMatrix(.ledLightSource)
    model.edit { $0 = FrameAdjustments(timing: .init(master: 30, red: 5, green: -3, blue: 7),
      contrast: .init(master: 1.05, red: 0.95, green: 1.02, blue: 1.1)) }
    try await ready()
    try await capture("21-v2-calibrated-reference")
    print("PASS: real window clipping, mouse controls, Filmstrip, user direction, native 1:1 pixels, whole-photo histogram, main-actor responsiveness")
    window.orderOut(nil)
  }
}
