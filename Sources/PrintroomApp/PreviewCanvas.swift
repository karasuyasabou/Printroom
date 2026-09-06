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
    if view.frameID != model.activeFrame?.id || view.resetToken != resetToken {
      view.zoom = 1
      view.pan = .zero
    }
    view.frameID = model.activeFrame?.id
    view.resetToken = resetToken
    view.model = model
    view.needsDisplay = true
    view.window?.invalidateCursorRects(for: view)
  }
}
@MainActor final class CanvasView: NSView {
  weak var model: EditorModel?
  var frameID: UUID?
  var resetToken = 0
  var zoom: CGFloat = 1
  var pan = CGPoint.zero
  var start: CGPoint?
  var previous: CGPoint?
  var selectionRect: CGRect?
  override var acceptsFirstResponder: Bool { true }
  override var isFlipped: Bool { true }
  var imageRect: CGRect {
    guard let image = model?.previewImage else { return .zero }
    let scale =
      min((bounds.width - 36) / CGFloat(image.width), (bounds.height - 36) / CGFloat(image.height))
      * zoom
    let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
    return CGRect(
      x: (bounds.width - size.width) / 2 + pan.x, y: (bounds.height - size.height) / 2 + pan.y,
      width: size.width, height: size.height)
  }
  override func draw(_ dirtyRect: NSRect) {
    NSColor(calibratedWhite: 0.075, alpha: 1).setFill()
    bounds.fill()
    guard let image = model?.previewImage else { return }
    let rect = imageRect
    NSGraphicsContext.current?.imageInterpolation = .high
    NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)).draw(
      in: rect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
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
    window?.makeFirstResponder(self)
    if event.clickCount == 2 {
      zoom = 1
      pan = .zero
      needsDisplay = true
      return
    }
    let p = convert(event.locationInWindow, from: nil)
    start = p
    previous = p
    if model?.sampling == true { selectionRect = CGRect(origin: p, size: .zero) }
  }
  override func mouseDragged(with event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    if model?.sampling == true, let start {
      selectionRect = CGRect(
        x: min(start.x, p.x), y: min(start.y, p.y), width: abs(start.x - p.x),
        height: abs(start.y - p.y)
      ).intersection(imageRect)
    } else if let previous {
      pan.x += p.x - previous.x
      pan.y += p.y - previous.y
    }
    previous = p
    needsDisplay = true
  }
  override func mouseUp(with event: NSEvent) {
    defer {
      start = nil
      previous = nil
      selectionRect = nil
      needsDisplay = true
    }
    guard let model, model.sourceWidth > 0, model.sourceHeight > 0 else { return }
    let p = convert(event.locationInWindow, from: nil)
    let display = imageRect
    guard display.width > 0, display.height > 0 else { return }
    func point(_ p: CGPoint) -> CGPoint {
      CGPoint(
        x: (p.x - display.minX) / display.width * CGFloat(model.sourceWidth),
        y: (p.y - display.minY) / display.height * CGFloat(model.sourceHeight))
    }
    if model.sampling, let selected = selectionRect, !selected.isNull, selected.width > 1,
      selected.height > 1
    {
      let a = point(selected.origin)
      let b = point(CGPoint(x: selected.maxX, y: selected.maxY))
      let x = max(0, Int(floor(a.x)))
      let y = max(0, Int(floor(a.y)))
      let right = min(model.sourceWidth, Int(ceil(b.x)))
      let bottom = min(model.sourceHeight, Int(ceil(b.y)))
      model.sampleBase(PixelRect(x: x, y: y, width: right - x, height: bottom - y))
    } else if !model.sampling, display.contains(p), let start,
      hypot(p.x - start.x, p.y - start.y) < 4
    {
      let q = point(p)
      model.readPixel(x: Int(q.x), y: Int(q.y))
    }
  }
  override func magnify(with event: NSEvent) {
    zoom = max(0.25, min(16, zoom * (1 + event.magnification)))
    needsDisplay = true
  }
  override func scrollWheel(with event: NSEvent) {
    if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
      zoom = max(0.25, min(16, zoom * exp(-event.scrollingDeltaY * 0.01)))
    } else {
      pan.x -= event.scrollingDeltaX
      pan.y -= event.scrollingDeltaY
    }
    needsDisplay = true
  }
  override func keyDown(with event: NSEvent) {
    if event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
      let key = event.charactersIgnoringModifiers, "qeadzcws".contains(key.lowercased()),
      key.count == 1
    {
      model?.handleTimingKey(key)
    } else {
      super.keyDown(with: event)
    }
  }
  override func resetCursorRects() {
    addCursorRect(bounds, cursor: model?.sampling == true ? .crosshair : .openHand)
  }
}
