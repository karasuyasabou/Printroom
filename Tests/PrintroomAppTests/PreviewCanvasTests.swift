import AppKit
import PrintroomCore
import SwiftUI
import Testing

@testable import PrintroomApp

@Suite(.serialized) @MainActor
struct PreviewCanvasTests {
  private func image(width: Int = 300, height: Int = 200) throws -> CGImage {
    try DisplayImage.make(
      PixelBuffer(
        width: width, height: height,
        pixels: Array(repeating: SIMD4<Float>(1, 0, 0, 1), count: width * height)),
      profile: nil, diagnostic: true)
  }

  private func mouse(
    _ type: NSEvent.EventType, _ point: CGPoint, in view: CanvasView,
    clicks: Int = 1
  ) throws -> NSEvent {
    try #require(
      NSEvent.mouseEvent(
        with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
        windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
        clickCount: clicks, pressure: 1))
  }

  @Test func cropToolbarReusesCanvasAndViewportAtMinimumWindowSize() async throws {
    _ = NSApplication.shared
    let model = EditorModel()
    let frame = FrameRecord(filename: "layout.tiff")
    var project = RollProject()
    project.frames = [frame]
    model.project = project
    model.selection.click(frame.id, ordered: [frame.id])
    model.sourceWidth = 300
    model.sourceHeight = 200
    model.previewImage = try image()
    let host = NSHostingView(rootView: EditorView(model: model))
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1060, height: 720),
      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    func canvasIn(_ view: NSView) -> CanvasView? {
      if let canvas = view as? CanvasView { return canvas }
      return view.subviews.lazy.compactMap { canvasIn($0) }.first
    }
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(50))
    let canvas = try #require(canvasIn(host))
    let before = canvas.convert(canvas.bounds, to: host)
    for _ in 0..<3 {
      model.beginCrop()
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(50))
      #expect(canvasIn(host) === canvas)
      #expect(canvas.convert(canvas.bounds, to: host) == before)
      model.cancelCrop()
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(50))
      #expect(canvasIn(host) === canvas)
      #expect(canvas.convert(canvas.bounds, to: host) == before)
    }
  }

  @Test func hostedEditorKeepsPanelsOutsideCanvasDuringTransformsAndResize() async throws {
    _ = NSApplication.shared
    let model = EditorModel()
    model.errorMessage = nil
    let frame = FrameRecord(filename: "layout.tiff")
    var project = RollProject()
    project.frames = [frame]
    model.project = project
    model.selection.click(frame.id, ordered: [frame.id])
    model.previewImage = try image()
    let host = NSHostingView(rootView: EditorView(model: model))
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 1200, height: 850),
      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    func canvasIn(_ view: NSView) -> CanvasView? {
      if let canvas = view as? CanvasView { return canvas }
      return view.subviews.lazy.compactMap { canvasIn($0) }.first
    }
    for size in [
      CGSize(width: 1200, height: 850), CGSize(width: 1060, height: 720),
      CGSize(width: 1440, height: 1000),
    ] {
      window.setContentSize(size)
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(50))
      let canvas = try #require(canvasIn(host))
      let initial = canvas.convert(canvas.bounds, to: host)
      #expect(abs(initial.minX) < 1)
      // Reserve inspector, preview toolbar, Filmstrip and dividers.
      #expect(abs(initial.maxX - (host.bounds.width - 307)) <= 1)
      let top = host.isFlipped ? initial.minY : host.bounds.height - initial.maxY
      let bottom = host.isFlipped ? host.bounds.height - initial.maxY : initial.minY
      #expect(abs(top - 104) <= 2)
      #expect(abs(bottom - 154) <= 2)
      canvas.zoom = 16
      canvas.pan = CGPoint(x: -1200, y: 900)
      canvas.needsDisplay = true
      host.layoutSubtreeIfNeeded()
      #expect(canvas.convert(canvas.bounds, to: host) == initial)
      canvas.resetViewport()
      #expect(canvas.imageRect.midX == canvas.bounds.midX)
      #expect(canvas.imageRect.midY == canvas.bounds.midY)
      model.sampling = true
      try await Task.sleep(for: .milliseconds(50))
      host.layoutSubtreeIfNeeded()
      #expect(canvas.convert(canvas.bounds, to: host) == initial)
      model.sampling = false
    }
  }

  @Test func drawingAndSelectionCannotTouchPixelsOutsideViewport() throws {
    let model = EditorModel()
    let canvas = CanvasView(frame: CGRect(x: 0, y: 0, width: 200, height: 160))
    canvas.model = model
    #expect(canvas.clipsToBounds)
    #expect(canvas.layer?.masksToBounds == true)
    // Exercise both landscape and transposed dimensions, as produced by TIFF orientation.
    for dimensions in [(300, 200), (200, 300)] {
      model.previewImage = try image(width: dimensions.0, height: dimensions.1)
      for zoom: CGFloat in [0.25, 1, 16] {
        for pan in [
          CGPoint.zero, CGPoint(x: -900, y: 0), CGPoint(x: 900, y: 0),
          CGPoint(x: 0, y: -900), CGPoint(x: 0, y: 900),
        ] {
          canvas.zoom = zoom
          canvas.pan = pan
          // Deliberately hostile overlay also proves drawing enforces its own clip.
          canvas.selectionRect = CGRect(x: -50, y: -50, width: 300, height: 260)
          let context = try #require(
            CGContext(
              data: nil, width: 400, height: 320, bitsPerComponent: 8, bytesPerRow: 1600,
              space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
          context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
          context.fill(CGRect(x: 0, y: 0, width: 400, height: 320))
          let baseline = Array(
            UnsafeBufferPointer(
              start: try #require(context.data).bindMemory(to: UInt8.self, capacity: 400 * 320 * 4),
              count: 400 * 320 * 4))
          context.translateBy(x: 100, y: 80)
          NSGraphicsContext.saveGraphicsState()
          NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
          canvas.draw(canvas.bounds)
          NSGraphicsContext.restoreGraphicsState()
          let bytes = try #require(context.data).bindMemory(to: UInt8.self, capacity: 400 * 320 * 4)
          var escapedPixels = 0
          for y in 0..<320 {
            for x in 0..<400 where x < 100 || x >= 300 || y < 80 || y >= 240 {
              let i = (y * 400 + x) * 4
              if (0..<4).contains(where: { bytes[i + $0] != baseline[i + $0] }) {
                escapedPixels += 1
              }
            }
          }
          #expect(escapedPixels == 0)
          #expect(canvas.frame.size == CGSize(width: 200, height: 160))
        }
      }
    }
  }

  @Test func outsideMouseEventsDoNotStartOrContinuePanningAndSelectionStaysVisible() throws {
    let model = EditorModel()
    model.previewImage = try image()
    let canvas = CanvasView(frame: CGRect(x: 0, y: 0, width: 200, height: 160))
    canvas.model = model
    canvas.zoom = 16
    let outside = CGPoint(x: 230, y: 80)
    try canvas.mouseDown(with: mouse(.leftMouseDown, outside, in: canvas))
    #expect(canvas.start == nil)
    try canvas.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 100, y: 80), in: canvas))
    try canvas.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 120, y: 90), in: canvas))
    #expect(canvas.pan == CGPoint(x: 20, y: 10))
    try canvas.mouseDragged(with: mouse(.leftMouseDragged, outside, in: canvas))
    #expect(canvas.pan == CGPoint(x: 20, y: 10))
    try canvas.mouseUp(with: mouse(.leftMouseUp, outside, in: canvas))
    #expect(canvas.start == nil && canvas.previous == nil)
    model.sampling = true
    try canvas.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 30, y: 40), in: canvas))
    try canvas.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 190, y: 150), in: canvas))
    let visibleSelection = canvas.selectionRect
    try canvas.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 400, y: 300), in: canvas))
    #expect(canvas.selectionRect == visibleSelection)
    let selection = try #require(canvas.selectionRect)
    #expect(selection.width > 1 && selection.height > 1)
    #expect(canvas.bounds.contains(selection))
    #expect(canvas.imageRect.contains(selection))
    try canvas.mouseUp(with: mouse(.leftMouseUp, outside, in: canvas))
    #expect(canvas.selectionRect == nil)
  }

  @Test func wheelAndMagnifyOnlyTransformInsideViewport() throws {
    let model = EditorModel()
    model.previewImage = try image()
    let canvas = CanvasView(frame: CGRect(x: 0, y: 0, width: 200, height: 160))
    canvas.model = model
    let event = CanvasGestureEvent()
    for point in [
      CGPoint(x: -1, y: 80), CGPoint(x: 201, y: 80),
      CGPoint(x: 100, y: -1), CGPoint(x: 100, y: 161),
    ] {
      event.testLocation = canvas.convert(point, to: nil)
      canvas.magnify(with: event)
      canvas.scrollWheel(with: event)
      event.testModifiers = .command
      canvas.scrollWheel(with: event)
      event.testModifiers = []
      #expect(canvas.zoom == 1 && canvas.pan == .zero)
    }
    event.testLocation = canvas.convert(CGPoint(x: 100, y: 80), to: nil)
    canvas.magnify(with: event)
    #expect(canvas.zoom == 1.5)
    canvas.scrollWheel(with: event)
    #expect(canvas.pan == CGPoint(x: 10, y: -30))
    event.testModifiers = .option
    canvas.scrollWheel(with: event)
    #expect(canvas.zoom > 1.5)
    #expect(canvas.frame.size == CGSize(width: 200, height: 160))
    #expect(
      canvas.intrinsicContentSize
        == NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric))
  }

  @Test func toolbarZoomSelectionTracksViewportAndDoubleClick() async throws {
    let model = EditorModel()
    model.previewImage = try image(width: 1200, height: 800)
    let canvas = CanvasView(frame: CGRect(x: 0, y: 0, width: 500, height: 400))
    canvas.model = model
    var reported: PreviewViewportMode?
    canvas.onViewportChange = { reported = $0 }
    canvas.resetViewport()
    try await Task.sleep(for: .milliseconds(20))
    #expect(reported == .fit)
    canvas.setNativeZoom()
    try await Task.sleep(for: .milliseconds(20))
    #expect(reported == .native)
    canvas.pan = CGPoint(x: 30, y: 40)
    canvas.scheduleDetail()
    try await Task.sleep(for: .milliseconds(20))
    #expect(reported == .native)
    canvas.zoom *= 1.2
    canvas.scheduleDetail()
    try await Task.sleep(for: .milliseconds(20))
    #expect(reported == nil)
    try canvas.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 100, y: 100), in: canvas, clicks: 2))
    try await Task.sleep(for: .milliseconds(20))
    #expect(reported == .fit)
    canvas.pan.x = 10
    canvas.scheduleDetail()
    try await Task.sleep(for: .milliseconds(20))
    #expect(reported == nil)
  }

  @Test func fitAndDoubleClickRecenterAfterZoomPanAndResize() throws {
    let model = EditorModel()
    model.previewImage = try image()
    let canvas = CanvasView(frame: CGRect(x: 0, y: 0, width: 500, height: 400))
    canvas.model = model
    for dimensions in [CGSize(width: 500, height: 400), CGSize(width: 200, height: 600)] {
      canvas.setFrameSize(dimensions)
      canvas.zoom = 16
      canvas.pan = CGPoint(x: -200, y: 900)
      canvas.resetViewport()
      #expect(canvas.zoom == 1 && canvas.pan == .zero)
      #expect(canvas.imageRect.midX == canvas.bounds.midX)
      #expect(canvas.imageRect.midY == canvas.bounds.midY)
      #expect(canvas.bounds.contains(canvas.imageRect))
      canvas.zoom = 0.25
      canvas.pan = CGPoint(x: 90, y: -100)
      try canvas.mouseDown(
        with: mouse(.leftMouseDown, CGPoint(x: 100, y: 100), in: canvas, clicks: 2))
      #expect(canvas.zoom == 1 && canvas.pan == .zero)
      #expect(canvas.imageRect.midX == canvas.bounds.midX)
      #expect(canvas.imageRect.midY == canvas.bounds.midY)
    }
  }

  @Test func zoomedClicksOnlySampleWithNeutralToolAndOutsideReleaseDoesNotCommit() async throws {
    let model = EditorModel()
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "PrintroomViewport-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let assets = try #require(model.assets)
    try TIFFCodec.write(
      url: folder.appendingPathComponent("frame.tiff"), width: 120, height: 80,
      profile: assets.profile
    ) { rows in
      // A coloured midtone in Final, outside the already-neutral dark tolerance.
      (0..<(rows.count * 120)).flatMap { _ in [UInt16(10387), 7524, 5206] }
    }
    model.open(folder)
    for _ in 0..<100 where !model.canPickNeutral {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.canPickNeutral)
    let frame = try #require(model.activeFrame)
    // A 10× smaller preview must still map tools to the full source.
    model.previewImage = try image(width: 12, height: 8)
    let canvas = CanvasView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
    canvas.model = model
    canvas.zoom = 4
    canvas.pan = CGPoint(x: 31, y: -17)
    let rect = canvas.imageRect
    let point = CGPoint(
      x: rect.minX + rect.width * 60.5 / 120,
      y: rect.minY + rect.height * 40.5 / 80)
    let originalAdjustments = model.adjustments
    try canvas.mouseDown(with: mouse(.leftMouseDown, point, in: canvas))
    try canvas.mouseUp(with: mouse(.leftMouseUp, point, in: canvas))
    #expect(model.adjustments == originalAdjustments)
    #expect(!model.neutralPicking && !model.isNeutralSampling)
    model.toggleNeutralPicker()
    #expect(model.neutralPicking)
    let edge = CGPoint(x: 399, y: 150)
    try canvas.mouseDown(with: mouse(.leftMouseDown, edge, in: canvas))
    // Less than click threshold, still on the enlarged image, but outside the viewport.
    try canvas.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 401, y: 150), in: canvas))
    try await Task.sleep(for: .milliseconds(100))
    #expect(model.adjustments == originalAdjustments)
    #expect(model.neutralPicking && !model.isNeutralSampling)
    try canvas.mouseDown(with: mouse(.leftMouseDown, point, in: canvas))
    try canvas.mouseUp(with: mouse(.leftMouseUp, point, in: canvas))
    #expect(!model.neutralPicking)
    for _ in 0..<100 where model.isNeutralSampling || model.isRendering {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.adjustments != originalAdjustments)
    #expect(model.errorMessage == nil)

    let roiStart = CGPoint(
      x: rect.minX + rect.width * 50.25 / 120,
      y: rect.minY + rect.height * 35.25 / 80)
    let roiEnd = CGPoint(
      x: rect.minX + rect.width * 65.75 / 120,
      y: rect.minY + rect.height * 45.75 / 80)
    model.sampling = true
    let before = try #require(model.project?.calibration)
    try canvas.mouseDown(with: mouse(.leftMouseDown, roiStart, in: canvas))
    try canvas.mouseDragged(with: mouse(.leftMouseDragged, roiEnd, in: canvas))
    #expect(canvas.selectionRect?.width ?? 0 > 1)
    try canvas.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 401, y: 150), in: canvas))
    try await Task.sleep(for: .milliseconds(100))
    #expect(model.project?.calibration == before)
    #expect(model.sampling)
    #expect(canvas.selectionRect == nil)

    try canvas.mouseDown(with: mouse(.leftMouseDown, roiStart, in: canvas))
    try canvas.mouseDragged(with: mouse(.leftMouseDragged, roiEnd, in: canvas))
    try canvas.mouseUp(with: mouse(.leftMouseUp, roiEnd, in: canvas))
    let expected = PixelRect(x: 50, y: 35, width: 16, height: 11)
    for _ in 0..<100 where model.project?.calibration.selection != expected {
      try await Task.sleep(for: .milliseconds(10))
    }
    let calibration = try #require(model.project?.calibration)
    #expect(calibration.selection == expected)
    #expect(calibration.sourceFrameID == frame.id)
    #expect(calibration.sourceWidth == 120 && calibration.sourceHeight == 80)
    #expect(model.baseStatistics.hasPrefix("176 像素"))
    #expect(calibration.isCalibrated && !model.sampling)
    // Let the render and thumbnail work triggered by calibration finish before fixture cleanup.
    for _ in 0..<100 where model.isRendering || model.thumbnails[frame.id] == nil {
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}

private final class CanvasGestureEvent: NSEvent, @unchecked Sendable {
  var testLocation = CGPoint.zero
  var testModifiers: NSEvent.ModifierFlags = []
  override var locationInWindow: NSPoint { testLocation }
  override var modifierFlags: NSEvent.ModifierFlags { testModifiers }
  override var magnification: CGFloat { 0.5 }
  override var scrollingDeltaY: CGFloat { -30 }
  override var scrollingDeltaX: CGFloat { 10 }
}
