import AppKit
import PrintroomCore
import SwiftUI

struct PreviewCanvas: NSViewRepresentable {
  @ObservedObject var model: EditorModel
  let resetToken: Int
  func makeNSView(context: Context) -> CanvasView {
    let view = CanvasView()
    view.model = model
    return view
  }
  func updateNSView(_ view: CanvasView, context: Context) {
    if view.frameID != model.activeFrame?.id || view.resetToken != resetToken || view.orientation != model.orientation {
      view.resetViewport()
    }
    if !model.sampling { view.selectionRect = nil }
    view.orientation = model.orientation
    if view.nativeZoomToken != model.nativeZoomToken {
      view.nativeZoomToken = model.nativeZoomToken
      view.setNativeZoom()
    }
    view.frameID = model.activeFrame?.id
    view.resetToken = resetToken
    view.model = model
    view.needsDisplay = true
    view.scheduleDetail()
    view.window?.invalidateCursorRects(for: view)
  }
}
@MainActor final class CanvasView: NSView {
  weak var model: EditorModel?
  var frameID: UUID?
  var resetToken = 0
  var nativeZoomToken = 0
  var orientation = FrameOrientation.identity
  var zoom: CGFloat = 1
  var pan = CGPoint.zero
  var start: CGPoint?
  var previous: CGPoint?
  var selectionRect: CGRect?
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    // macOS 14 no longer clips NSView drawing to bounds by default.
    clipsToBounds = true
    wantsLayer = true
    layer?.masksToBounds = true
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
  }
  func cancelGesture() {
    start = nil
    previous = nil
    selectionRect = nil
    needsDisplay = true
  }
  func resetViewport() {
    zoom = 1
    pan = .zero
    cancelGesture()
    scheduleDetail()
  }
  override func setFrameSize(_ newSize: NSSize) {
    if newSize != frame.size { cancelGesture() }
    super.setFrameSize(newSize)
    scheduleDetail()
    needsDisplay = true
  }
  override var acceptsFirstResponder: Bool { true }
  override var isFlipped: Bool { true }
  var displaySize: CGSize {
    guard let model, let image = model.previewImage else { return .zero }
    return CGSize(width: model.displayWidth > 0 ? model.displayWidth : image.width,
                  height: model.displayHeight > 0 ? model.displayHeight : image.height)
  }
  var fitScale: CGFloat {
    let size = displaySize
    guard size.width > 0, size.height > 0 else { return 0 }
    return min(max(0, bounds.width - 36) / size.width, max(0, bounds.height - 36) / size.height)
  }
  var imageRect: CGRect {
    let scale = fitScale * zoom
    let size = CGSize(width: displaySize.width * scale, height: displaySize.height * scale)
    return CGRect(x: bounds.midX - size.width / 2 + pan.x,
      y: bounds.midY - size.height / 2 + pan.y, width: size.width, height: size.height)
  }
  func setNativeZoom() {
    guard fitScale > 0 else { return }
    // One source pixel per physical display pixel, including Retina backing scale.
    zoom = 1 / ((window?.backingScaleFactor ?? 1) * fitScale)
    pan = .zero
    cancelGesture()
    scheduleDetail()
  }
  func scheduleDetail() {
    // UI updates and layout callbacks may not publish synchronously into SwiftUI.
    Task { @MainActor [weak self] in
      guard let self, let model = self.model else { return }
      let rect = self.imageRect
      let size = self.displaySize
      guard size.width > 0, size.height > 0,
        self.fitScale * self.zoom * (self.window?.backingScaleFactor ?? 1) >= 0.999 else {
        model.requestDetail(nil)
        return
      }
      let visible = rect.intersection(self.bounds)
      guard !visible.isNull, visible.width > 0, visible.height > 0 else { model.requestDetail(nil); return }
      let x = max(0, Int(floor((visible.minX - rect.minX) / rect.width * size.width)))
      let y = max(0, Int(floor((visible.minY - rect.minY) / rect.height * size.height)))
      let right = min(Int(size.width), Int(ceil((visible.maxX - rect.minX) / rect.width * size.width)))
      let bottom = min(Int(size.height), Int(ceil((visible.maxY - rect.minY) / rect.height * size.height)))
      model.requestDetail(PixelRect(x: x, y: y, width: right - x, height: bottom - y))
    }
  }
  override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    context.saveGState()
    defer { context.restoreGState() }
    // Apply before either the image or the selection overlay is drawn.
    context.clip(to: bounds)
    NSColor(calibratedWhite: 0.075, alpha: 1).setFill()
    bounds.fill()
    guard let image = model?.previewImage else { return }
    let rect = imageRect
    NSGraphicsContext.current?.imageInterpolation = .high
    NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)).draw(
      in: rect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
    if let model, let detail = model.detailImage, let tile = model.detailRect,
      model.displayWidth > 0, model.displayHeight > 0 {
      let destination = CGRect(
        x: rect.minX + CGFloat(tile.x) / CGFloat(model.displayWidth) * rect.width,
        y: rect.minY + CGFloat(tile.y) / CGFloat(model.displayHeight) * rect.height,
        width: CGFloat(tile.width) / CGFloat(model.displayWidth) * rect.width,
        height: CGFloat(tile.height) / CGFloat(model.displayHeight) * rect.height)
      NSGraphicsContext.current?.imageInterpolation = .none
      NSImage(cgImage: detail, size: NSSize(width: detail.width, height: detail.height)).draw(
        in: destination, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
    }
    if let selectionRect {
      NSColor.systemYellow.withAlphaComponent(0.15).setFill()
      selectionRect.fill()
      NSColor.systemYellow.setStroke()
      let path = NSBezierPath(rect: selectionRect)
      path.lineWidth = 1.5
      path.stroke()
    }
  }
  override func mouseDown(with event: NSEvent) {
    cancelGesture()
    let p = convert(event.locationInWindow, from: nil)
    guard bounds.contains(p), model?.previewImage != nil else { return }
    window?.makeFirstResponder(self)
    if event.clickCount == 2 {
      resetViewport()
      return
    }
    if model?.sampling == true && !imageRect.contains(p) { return }
    start = p
    previous = p
    if model?.sampling == true { selectionRect = CGRect(origin: p, size: .zero) }
  }
  override func mouseDragged(with event: NSEvent) {
    guard let start else { return }
    let p = convert(event.locationInWindow, from: nil)
    guard bounds.contains(p) else {
      // Pause outside; re-entry must not accumulate an off-viewport pan delta.
      previous = nil
      return
    }
    if model?.sampling == true {
      selectionRect = CGRect(
        x: min(start.x, p.x), y: min(start.y, p.y), width: abs(start.x - p.x),
        height: abs(start.y - p.y)
      ).intersection(imageRect).intersection(bounds)
    } else if let previous {
      pan.x += p.x - previous.x
      pan.y += p.y - previous.y
    }
    previous = p
    if model?.sampling != true { scheduleDetail() }
    needsDisplay = true
  }
  override func mouseUp(with event: NSEvent) {
    defer {
      start = nil
      previous = nil
      selectionRect = nil
      needsDisplay = true
    }
    guard start != nil, let model, model.sourceWidth > 0, model.sourceHeight > 0 else { return }
    let p = convert(event.locationInWindow, from: nil)
    guard bounds.contains(p) else { return }
    let display = imageRect
    guard display.width > 0, display.height > 0 else { return }
    func point(_ p: CGPoint) -> CGPoint {
      CGPoint(
        x: (p.x - display.minX) / display.width * CGFloat(model.displayWidth),
        y: (p.y - display.minY) / display.height * CGFloat(model.displayHeight))
    }
    if model.sampling, let selected = selectionRect, !selected.isNull, selected.width > 1,
      selected.height > 1
    {
      let a = point(selected.origin)
      let b = point(CGPoint(x: selected.maxX, y: selected.maxY))
      let x = max(0, Int(floor(a.x)))
      let y = max(0, Int(floor(a.y)))
      let right = min(model.displayWidth, Int(ceil(b.x)))
      let bottom = min(model.displayHeight, Int(ceil(b.y)))
      model.sampleDisplayedBase(PixelRect(x: x, y: y, width: right - x, height: bottom - y))
    } else if !model.sampling, display.contains(p), let start,
      hypot(p.x - start.x, p.y - start.y) < 4
    {
      let q = point(p)
      model.readDisplayedPixel(x: Int(q.x), y: Int(q.y))
    }
  }
  override func magnify(with event: NSEvent) {
    guard bounds.contains(convert(event.locationInWindow, from: nil)), model?.previewImage != nil
    else { return }
    cancelGesture()
    zoom = max(0.25, min(16, zoom * (1 + event.magnification)))
    scheduleDetail()
    needsDisplay = true
  }
  override func scrollWheel(with event: NSEvent) {
    guard bounds.contains(convert(event.locationInWindow, from: nil)), model?.previewImage != nil
    else { return }
    cancelGesture()
    if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
      zoom = max(0.25, min(16, zoom * exp(-event.scrollingDeltaY * 0.01)))
    } else {
      pan.x -= event.scrollingDeltaX
      pan.y -= event.scrollingDeltaY
    }
    scheduleDetail()
    needsDisplay = true
  }
  override func keyDown(with event: NSEvent) {
    if event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
      let key = event.charactersIgnoringModifiers, "qeadzcws".contains(key.lowercased()),
      key.count == 1
    {
      let targetWindow = window
      model?.startTimingKey(key, shift: event.modifierFlags.contains(.shift),
        isRepeat: event.isARepeat) { [weak self, weak targetWindow] in
          guard let self, let targetWindow else { return false }
          return targetWindow.isKeyWindow && targetWindow.firstResponder === self
            && targetWindow.attachedSheet == nil && NSApp.modalWindow == nil && NSApp.isActive
        }
    } else {
      super.keyDown(with: event)
    }
  }
  override func resetCursorRects() {
    addCursorRect(bounds, cursor: model?.sampling == true ? .crosshair : .openHand)
  }
}
