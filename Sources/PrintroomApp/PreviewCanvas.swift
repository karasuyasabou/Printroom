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
    if view.frameID != model.activeFrame?.id || view.resetToken != resetToken
      || view.orientation != model.orientation || view.cropViewportToken != model.cropViewportToken {
      view.resetViewport()
    }
    if !model.sampling { view.selectionRect = nil }
    view.orientation = model.orientation
    view.cropViewportToken = model.cropViewportToken
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
  var cropViewportToken = 0
  var orientation = FrameOrientation.identity
  var zoom: CGFloat = 1
  var pan = CGPoint.zero
  var start: CGPoint?
  var previous: CGPoint?
  var selectionRect: CGRect?
  var cropGesture: CropGesture?
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
    cropGesture = nil
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
    if model?.isCropping == true {
      // Reserve the full ±10° envelope once; angle changes never move the viewport.
      let horizontalAngle = min(CGFloat.pi / 18, atan2(size.height, size.width))
      let verticalAngle = min(CGFloat.pi / 18, atan2(size.width, size.height))
      let width = size.width * cos(horizontalAngle) + size.height * sin(horizontalAngle)
      let height = size.height * cos(verticalAngle) + size.width * sin(verticalAngle)
      return min(max(0, bounds.width - 36) / width, max(0, bounds.height - 36) / height)
    }
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
      guard !model.isCropping else { model.requestDetail(nil); return }
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
    context.saveGState()
    if model?.isCropping == true, let crop = model?.cropDraft {
      context.translateBy(x: rect.midX, y: rect.midY)
      context.rotate(by: CGFloat(crop.angleDegrees) * .pi / 180)
      context.translateBy(x: -rect.midX, y: -rect.midY)
    }
    NSGraphicsContext.current?.imageInterpolation = .high
    NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)).draw(
      in: rect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
    if let model, !model.isCropping, let detail = model.detailImage, let tile = model.detailRect,
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
    context.restoreGState()
    if model?.isCropping == true { drawCropOverlay(context) }
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
    if let model, model.isCropping, let rect = cropRect, let handle = cropHandle(at: p, rect: rect),
      let geometry = model.cropDraftGeometry {
      cropGesture = CropGesture(handle: handle, initialPoint: p, initialRect: geometry.rect,
        originalCrop: model.cropDraft,
        draft: model.cropDraft ?? FrameCrop(portrait: model.displayHeight > model.displayWidth))
    }
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
    if cropGesture != nil {
      updateCropGesture(to: p)
    } else if model?.sampling == true {
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
      cropGesture = nil
      needsDisplay = true
    }
    guard start != nil, let model, model.sourceWidth > 0, model.sourceHeight > 0 else { return }
    let p = convert(event.locationInWindow, from: nil)
    if let gesture = cropGesture {
      if !bounds.contains(p), model.isCropping {
        if let crop = gesture.originalCrop { model.updateCropDraft(crop) }
        else { model.resetCropDraft() }
      }
      return
    }
    guard bounds.contains(p) else { return }
    guard !model.isCropping else { return }
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
      // AppKit already applies the user's natural scrolling preference.
      // Move the image with that delta in this flipped (y-down) canvas.
      pan.x += event.scrollingDeltaX
      pan.y += event.scrollingDeltaY
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
    guard model?.isCropping == true, let rect = cropRect else { return }
    func cursor(_ area: CGRect, _ cursor: NSCursor) {
      let visible = area.intersection(bounds)
      if !visible.isNull && !visible.isEmpty { addCursorRect(visible, cursor: cursor) }
    }
    for x in [rect.minX, rect.maxX] {
      cursor(CGRect(x: x - 6, y: rect.minY, width: 12, height: rect.height), .resizeLeftRight)
    }
    for y in [rect.minY, rect.maxY] {
      cursor(CGRect(x: rect.minX, y: y - 6, width: rect.width, height: 12), .resizeUpDown)
    }
    for point in cropCorners(rect) {
      cursor(CGRect(x: point.x - 9, y: point.y - 9, width: 18, height: 18), .crosshair)
    }
  }
}

extension CanvasView {
  struct CropHandle: Equatable {
    // Zero on an axis means that axis stays centered; both zero means move the frame.
    let x: Int
    let y: Int
    static let move = CropHandle(x: 0, y: 0)
  }
  struct CropGesture {
    let handle: CropHandle
    let initialPoint: CGPoint
    let initialRect: CGRect
    let originalCrop: FrameCrop?
    let draft: FrameCrop
  }
  var cropRect: CGRect? {
    guard let geometry = model?.cropDraftGeometry, displaySize.width > 0, displaySize.height > 0 else {
      return nil
    }
    let image = imageRect
    return CGRect(
      x: image.minX + geometry.rect.minX / displaySize.width * image.width,
      y: image.minY + geometry.rect.minY / displaySize.height * image.height,
      width: geometry.rect.width / displaySize.width * image.width,
      height: geometry.rect.height / displaySize.height * image.height)
  }
  func cropCorners(_ rect: CGRect) -> [CGPoint] {
    [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
      CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
  }
  func cropHandle(at point: CGPoint, rect: CGRect) -> CropHandle? {
    for x in [-1, 1] {
      for y in [-1, 1] {
        let corner = CGPoint(x: x < 0 ? rect.minX : rect.maxX, y: y < 0 ? rect.minY : rect.maxY)
        if hypot(point.x - corner.x, point.y - corner.y) <= 12 { return CropHandle(x: x, y: y) }
      }
    }
    if point.y >= rect.minY && point.y <= rect.maxY {
      if abs(point.x - rect.minX) <= 7 { return CropHandle(x: -1, y: 0) }
      if abs(point.x - rect.maxX) <= 7 { return CropHandle(x: 1, y: 0) }
    }
    if point.x >= rect.minX && point.x <= rect.maxX {
      if abs(point.y - rect.minY) <= 7 { return CropHandle(x: 0, y: -1) }
      if abs(point.y - rect.maxY) <= 7 { return CropHandle(x: 0, y: 1) }
    }
    return rect.contains(point) ? .move : nil
  }
  func updateCropGesture(to point: CGPoint) {
    guard let model, model.isCropping, let gesture = cropGesture,
      imageRect.width > 0, imageRect.height > 0 else { return }
    let dx = (point.x - gesture.initialPoint.x) / imageRect.width * displaySize.width
    let dy = (point.y - gesture.initialPoint.y) / imageRect.height * displaySize.height
    let rect = Self.resizedCropRect(gesture.initialRect, handle: gesture.handle,
      delta: CGPoint(x: dx, y: dy), ratio: gesture.draft.ratio)
    var draft = gesture.draft
    draft.centerX = min(2, max(-1, rect.midX / displaySize.width))
    draft.centerY = min(2, max(-1, rect.midY / displaySize.height))
    draft.width = min(2, max(1 / displaySize.width, rect.width / displaySize.width))
    model.updateCropDraft(draft)
  }
  static func resizedCropRect(_ initial: CGRect, handle: CropHandle, delta: CGPoint, ratio: Double) -> CGRect {
    if handle == .move { return initial.offsetBy(dx: delta.x, dy: delta.y) }
    let sx = CGFloat(handle.x), sy = CGFloat(handle.y), ratio = CGFloat(ratio)
    let width: CGFloat
    if handle.x == 0 { width = max(1, initial.height + sy * delta.y) * ratio }
    else if handle.y == 0 { width = max(1, initial.width + sx * delta.x) }
    else {
      let horizontal = initial.width + sx * delta.x
      let vertical = initial.height + sy * delta.y
      width = max(1, (horizontal * ratio + vertical) * ratio / (ratio * ratio + 1))
    }
    let height = width / ratio
    let centerX = initial.midX + sx * (width - initial.width) / 2
    let centerY = initial.midY + sy * (height - initial.height) / 2
    return CGRect(x: centerX - width / 2, y: centerY - height / 2, width: width, height: height)
  }
  func drawCropOverlay(_ context: CGContext) {
    guard let rect = cropRect, !rect.isEmpty else { return }
    context.saveGState()
    defer { context.restoreGState() }
    context.addRect(bounds)
    context.addRect(rect)
    context.setFillColor(NSColor.black.withAlphaComponent(0.52).cgColor)
    context.drawPath(using: .eoFill)
    context.saveGState()
    context.clip(to: rect)
    // Denser fixed grid supplies visual angle references without a separate straighten tool.
    let divisions = abs(model?.cropDraft?.angleDegrees ?? 0) > 0.00001 ? 6 : 3
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor)
    context.setLineWidth(0.5)
    for index in 1..<divisions {
      let fraction = CGFloat(index) / CGFloat(divisions)
      context.move(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.minY))
      context.addLine(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.maxY))
      context.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * fraction))
      context.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * fraction))
    }
    context.strokePath()
    context.restoreGState()
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
    context.setLineWidth(1)
    context.stroke(rect)
    context.setLineWidth(3)
    let length = min(16, min(rect.width, rect.height) / 5)
    for corner in cropCorners(rect) {
      let sx: CGFloat = corner.x < rect.midX ? 1 : -1
      let sy: CGFloat = corner.y < rect.midY ? 1 : -1
      context.move(to: CGPoint(x: corner.x + sx * length, y: corner.y))
      context.addLine(to: corner)
      context.addLine(to: CGPoint(x: corner.x, y: corner.y + sy * length))
    }
    for x in [rect.minX, rect.maxX] {
      context.move(to: CGPoint(x: x, y: rect.midY - length / 2))
      context.addLine(to: CGPoint(x: x, y: rect.midY + length / 2))
    }
    for y in [rect.minY, rect.maxY] {
      context.move(to: CGPoint(x: rect.midX - length / 2, y: y))
      context.addLine(to: CGPoint(x: rect.midX + length / 2, y: y))
    }
    context.strokePath()
  }
}
