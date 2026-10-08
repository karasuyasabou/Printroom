import AppKit
import PrintroomCore
import SwiftUI

struct PreviewCanvas: NSViewRepresentable {
  @ObservedObject var model: EditorModel
  func makeNSView(context: Context) -> CanvasView {
    let view = CanvasView()
    view.model = model
    return view
  }
  func updateNSView(_ view: CanvasView, context: Context) {
    if model.cropPreviewTransition == nil && (view.frameID != model.activeFrame?.id
      || view.orientation != model.orientation || view.cropViewportToken != model.cropViewportToken) {
      view.resetViewport()
    }
    if !model.sampling { view.selectionRect = nil }
    view.orientation = model.orientation
    if model.cropPreviewTransition == nil { view.cropViewportToken = model.cropViewportToken }
    view.frameID = model.activeFrame?.id
    view.model = model
    view.needsDisplay = true
    view.constrainPan()
    // Hit-testing can ask SwiftUI to lay out overlays; do it after this update finishes.
    Task { @MainActor [weak view] in view?.refreshCursor(); view?.refreshHistogramProbe() }
  }
}
@MainActor final class CanvasView: NSView {
  weak var model: EditorModel?
  var frameID: UUID?
  var cropViewportToken = 0
  var orientation = FrameOrientation.identity
  var zoom: CGFloat = 1
  var pan = CGPoint.zero
  var start: CGPoint?
  var previous: CGPoint?
  var selectionRect: CGRect?
  var cropGesture: CropGesture?
  private(set) var isPanning = false
  private var cursorTrackingArea: NSTrackingArea?
  // Draw an outlined pipette with an exact tip/hotspot, visible on light and dark photos.
  static let neutralCursor: NSCursor = {
    let image = NSImage(size: NSSize(width: 26, height: 26), flipped: true) { _ in
      let tube = NSBezierPath()
      tube.move(to: NSPoint(x: 3, y: 22))
      tube.line(to: NSPoint(x: 3, y: 18))
      tube.line(to: NSPoint(x: 12, y: 9))
      tube.line(to: NSPoint(x: 16, y: 13))
      tube.line(to: NSPoint(x: 7, y: 22))
      tube.close()
      let bulb = NSBezierPath()
      bulb.move(to: NSPoint(x: 10, y: 8))
      bulb.line(to: NSPoint(x: 13, y: 5))
      bulb.line(to: NSPoint(x: 15, y: 7))
      bulb.line(to: NSPoint(x: 18, y: 4))
      bulb.curve(to: NSPoint(x: 22, y: 8), controlPoint1: NSPoint(x: 22, y: 0),
        controlPoint2: NSPoint(x: 26, y: 4))
      bulb.line(to: NSPoint(x: 19, y: 11))
      bulb.line(to: NSPoint(x: 21, y: 13))
      bulb.line(to: NSPoint(x: 18, y: 16))
      bulb.close()
      for path in [tube, bulb] {
        path.lineJoinStyle = .round
        path.lineWidth = 2.5
        NSColor.white.setStroke()
        path.stroke()
        NSColor.black.setFill()
        path.fill()
      }
      return true
    }
    return NSCursor(image: image, hotSpot: NSPoint(x: 3, y: 22))
  }()
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
    isPanning = false
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
    constrainPan()
  }
  override func setFrameSize(_ newSize: NSSize) {
    if newSize != frame.size { cancelGesture() }
    super.setFrameSize(newSize)
    constrainPan()
    needsDisplay = true
  }
  override var acceptsFirstResponder: Bool { true }
  override var isFlipped: Bool { true }
  var presentsCrop: Bool { model?.cropPreviewTransition?.isCropping ?? (model?.isCropping == true) }
  var presentedCropGeometry: CropGeometry? {
    if let transition = model?.cropPreviewTransition { return transition.geometry }
    return model?.cropDraftGeometry
  }
  var displaySize: CGSize {
    if let transition = model?.cropPreviewTransition { return transition.size }
    guard let model, let image = model.previewImage else { return .zero }
    return CGSize(width: model.displayWidth > 0 ? model.displayWidth : image.width,
                  height: model.displayHeight > 0 ? model.displayHeight : image.height)
  }
  var fitScale: CGFloat {
    let size = displaySize
    guard size.width > 0, size.height > 0 else { return 0 }
    if presentsCrop {
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
  func constrainPan() {
    let size = imageRect.size
    guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else {
      pan = .zero
      return
    }
    // A small photo stays inside the viewport; a large photo covers it along that axis.
    var limitX = abs(size.width - bounds.width) / 2
    var limitY = abs(size.height - bounds.height) / 2
    if presentsCrop {
      // Use a fixed ±10° envelope, so adjusting the crop angle never moves the viewport.
      let angle = CGFloat.pi / 18
      let horizontalAngle = min(angle, atan2(size.height, size.width))
      let verticalAngle = min(angle, atan2(size.width, size.height))
      let outerWidth = size.width * cos(horizontalAngle) + size.height * sin(horizontalAngle)
      let outerHeight = size.height * cos(verticalAngle) + size.width * sin(verticalAngle)
      limitX = outerWidth <= bounds.width ? (bounds.width - outerWidth) / 2
        : max(0, (size.width - bounds.width) / 2)
      limitY = outerHeight <= bounds.height ? (bounds.height - outerHeight) / 2
        : max(0, (size.height - bounds.height) / 2)
      // Keep a common safe range for every angle. The four separating-axis bounds
      // ensure the actual rotated photo overlaps the viewport, even at extreme zoom.
      // Only tighten extreme corner positions; ordinary zoomed panning stays available.
      let cosine = cos(angle), sine = sin(angle)
      limitX = min(limitX, (size.width * cosine + bounds.width) / 2)
      limitY = min(limitY, (size.height * cosine + bounds.height) / 2)
      let horizontalDemand = limitX + limitY * sine
      let verticalDemand = limitY + limitX * sine
      let safety = min(1, (size.width + bounds.width * cosine) / (2 * max(1, horizontalDemand)),
        (size.height + bounds.height * cosine) / (2 * max(1, verticalDemand)))
      limitX *= safety
      limitY *= safety
    }
    pan.x = max(-limitX, min(limitX, pan.x))
    pan.y = max(-limitY, min(limitY, pan.y))
  }
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    context.saveGState()
    defer { context.restoreGState() }
    // Apply before either the image or the selection overlay is drawn.
    context.clip(to: bounds)
    let backdrop = model?.project == nil ? InterfaceColors.home : InterfaceColors.canvas
    backdrop.setFill()
    bounds.fill()
    guard let image = model?.previewImage else { return }
    let rect = imageRect
    context.saveGState()
    if presentsCrop, let crop = presentedCropGeometry?.displayCrop {
      context.translateBy(x: rect.midX, y: rect.midY)
      context.rotate(by: CGFloat(crop.angleDegrees) * .pi / 180)
      context.translateBy(x: -rect.midX, y: -rect.midY)
    }
    NSGraphicsContext.current?.imageInterpolation = .high
    NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)).draw(
      in: rect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
    context.restoreGState()
    if presentsCrop { drawCropOverlay(context) }
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
    guard !isOverHistogram(convert(event.locationInWindow, from: nil)) else { return }
    cancelGesture()
    let p = convert(event.locationInWindow, from: nil)
    guard bounds.contains(p), model?.previewImage != nil, model?.cropPreviewTransition == nil else { return }
    window?.makeFirstResponder(self)
    if (model?.sampling == true || model?.neutralPicking == true) && !imageRect.contains(p) { return }
    start = p
    previous = p
    if let model, model.isCropping, let rect = cropRect,
      let geometry = model.cropDraftGeometry {
      cropGesture = CropGesture(handle: cropHandle(at: p, rect: rect) ?? .rotate, initialPoint: p, initialRect: geometry.rect,
        originalCrop: model.cropDraft, ratioLocked: model.cropRatioLocked,
        draft: model.displayedCropDraft ?? FrameCrop(
          aspect: .free, geometryVersion: 1,
          freeRatio: Double(model.displayWidth) / Double(model.displayHeight)))
    }
    if model?.sampling == true { selectionRect = CGRect(origin: p, size: .zero) }
  }
  override func mouseDragged(with event: NSEvent) {
    guard let start, model?.cropPreviewTransition == nil else { return }
    model?.clearHistogramProbe()
    let p = convert(event.locationInWindow, from: nil)
    guard bounds.contains(p) else {
      // Pause outside; re-entry must not accumulate an off-viewport pan delta.
      previous = nil
      return
    }
    if cropGesture != nil {
      updateCropGesture(to: p)
      refreshCursor()
    } else if model?.sampling == true {
      selectionRect = CGRect(
        x: min(start.x, p.x), y: min(start.y, p.y), width: abs(start.x - p.x),
        height: abs(start.y - p.y)
      ).intersection(imageRect).intersection(bounds)
    } else if model?.neutralPicking != true, let previous {
      isPanning = true
      refreshCursor()
      pan.x += p.x - previous.x
      pan.y += p.y - previous.y
    }
    previous = p
    if model?.sampling != true { constrainPan() }
    needsDisplay = true
  }
  override func mouseUp(with event: NSEvent) {
    defer {
      isPanning = false
      start = nil
      previous = nil
      selectionRect = nil
      cropGesture = nil
      refreshCursor()
      refreshHistogramProbe()
      needsDisplay = true
    }
    guard start != nil, let model, model.cropPreviewTransition == nil, model.sourceWidth > 0, model.sourceHeight > 0 else { return }
    let p = convert(event.locationInWindow, from: nil)
    if let gesture = cropGesture {
      if !bounds.contains(p), model.isCropping {
        if let crop = gesture.originalCrop { model.updateCropDraft(crop) }
        else { model.resetCropDraft() }
        model.cropRatioLocked = gesture.ratioLocked
      }
      return
    }
    guard bounds.contains(p) else { return }
    guard !model.isCropping else { return }
    let display = imageRect
    guard display.width > 0, display.height > 0 else { return }
    func point(_ p: CGPoint) -> CGPoint {
      CGPoint(
        x: (p.x - display.minX) / display.width * displaySize.width,
        y: (p.y - display.minY) / display.height * displaySize.height)
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
    } else if model.neutralPicking, model.canPickNeutral, display.contains(p), let start,
      hypot(p.x - start.x, p.y - start.y) < 4
    {
      let q = point(p)
      model.pickNeutralDisplayed(x: Int(q.x), y: Int(q.y))
    }
  }
  override func magnify(with event: NSEvent) {
    guard bounds.contains(convert(event.locationInWindow, from: nil)), model?.previewImage != nil,
      model?.cropPreviewTransition == nil
    else { return }
    cancelGesture()
    zoom = max(0.25, min(16, zoom * (1 + event.magnification)))
    constrainPan()
    refreshHistogramProbe()
    needsDisplay = true
  }
  override func scrollWheel(with event: NSEvent) {
    guard !isOverHistogram(convert(event.locationInWindow, from: nil)) else { return }
    guard bounds.contains(convert(event.locationInWindow, from: nil)), model?.previewImage != nil,
      model?.cropPreviewTransition == nil
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
    constrainPan()
    refreshHistogramProbe()
    needsDisplay = true
  }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let cursorTrackingArea { removeTrackingArea(cursorTrackingArea) }
    let area = NSTrackingArea(rect: .zero,
      options: [.inVisibleRect, .activeInKeyWindow, .cursorUpdate, .mouseMoved, .mouseEnteredAndExited],
      owner: self, userInfo: nil)
    addTrackingArea(area)
    cursorTrackingArea = area
  }
  private func isOverHistogram(_ point: CGPoint) -> Bool {
    guard let content = window?.contentView else { return false }
    func containsPanel(_ view: NSView) -> Bool {
      guard !view.isHidden else { return false }
      if view is HistogramPointerView {
        return view.bounds.contains(view.convert(point, from: self))
      }
      return view.subviews.contains { containsPanel($0) }
    }
    return containsPanel(content)
  }
  func cursor(at point: CGPoint) -> NSCursor {
    // SwiftUI may route non-interactive background hits through to the canvas.
    // The panel's actual laid-out bounds also exclude its chart and padding.
    if isOverHistogram(point) { return .arrow }
    guard bounds.contains(point), let model, model.previewImage != nil else { return .arrow }
    if model.sampling { return .crosshair }
    if model.neutralPicking { return Self.neutralCursor }
    if model.isCropping, cropGesture?.handle == .rotate { return rotationCursor(at: point) }
    if model.isCropping, let rect = cropRect, let handle = cropHandle(at: point, rect: rect) {
      if handle.x != 0 && handle.y != 0 { return .crosshair }
      if handle.x != 0 { return .resizeLeftRight }
      if handle.y != 0 { return .resizeUpDown }
    }
    if model.isCropping, cropRect != nil {
      return cropGesture?.handle == .rotate || !(cropRect?.contains(point) ?? true) ? rotationCursor(at: point) : .arrow
    }
    return isPanning ? .closedHand : .arrow
  }
  func refreshHistogramProbe() {
    guard let model else { return }
    guard let window, window.isKeyWindow, window.attachedSheet == nil,
      NSApp.modalWindow == nil, !isPanning, start == nil else {
      model.clearHistogramProbe(); return
    }
    let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
    let rect = imageRect
    guard bounds.contains(p), rect.contains(p), rect.width > 0, rect.height > 0,
      !isOverHistogram(p) else { model.clearHistogramProbe(); return }
    model.probeHistogram(
      displayX: Int((p.x - rect.minX) / rect.width * displaySize.width),
      displayY: Int((p.y - rect.minY) / rect.height * displaySize.height))
  }
  func refreshCursor() {
    // SwiftUI overlay backgrounds can hit either the canvas or a shared graphics
    // view. Use the actual panel bounds instead of that unstable hit-test result.
    guard let window, window.isKeyWindow, window.attachedSheet == nil,
      NSApp.modalWindow == nil else { return }
    let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
    guard bounds.contains(point) else { return }
    cursor(at: point).set()
  }
  override func cursorUpdate(with event: NSEvent) { refreshCursor() }
  override func mouseEntered(with event: NSEvent) { refreshCursor(); refreshHistogramProbe() }
  override func mouseMoved(with event: NSEvent) { refreshCursor(); refreshHistogramProbe() }
  override func mouseExited(with event: NSEvent) {
    model?.clearHistogramProbe()
    NSCursor.arrow.set()
  }
}

extension CanvasView {
  // Clockwise in the canvas's flipped coordinates: right, bottom-right, bottom, ...
  static func rotationCursorDirection(at point: CGPoint, around rect: CGRect) -> Int {
    let x: Double = point.x < rect.minX ? -1 : (point.x > rect.maxX ? 1 : 0)
    let y: Double = point.y < rect.minY ? -1 : (point.y > rect.maxY ? 1 : 0)
    // During an active rotation the pointer may cross into the crop rectangle.
    let angle = x == 0 && y == 0
      ? atan2(point.y - rect.midY, point.x - rect.midX) : atan2(y, x)
    return (Int((angle / (.pi / 4)).rounded()) + 8) % 8
  }
  func rotationCursor(at point: CGPoint) -> NSCursor {
    Self.rotationCursors[Self.rotationCursorDirection(at: point, around: cropRect ?? imageRect)]
  }
  static let rotationCursors: [NSCursor] = (0..<8).map { direction in
    let image = NSImage(size: NSSize(width: 28, height: 28), flipped: false) { _ in
      guard let context = NSGraphicsContext.current?.cgContext else { return false }
      context.saveGState()
      defer { context.restoreGState() }
      context.translateBy(x: 14, y: 14)
      context.rotate(by: -CGFloat(direction) * .pi / 4)
      context.translateBy(x: -14, y: -14)
      // A short, double-headed arc. Its concave side faces the crop rectangle.
      let radius = 9.0, halfAngle = 45.0 * Double.pi / 180
      func point(_ angle: Double) -> CGPoint {
        CGPoint(x: 5 + radius * cos(angle), y: 14 + radius * sin(angle))
      }
      let path = CGMutablePath()
      path.addArc(center: CGPoint(x: 5, y: 14), radius: radius,
        startAngle: -halfAngle, endAngle: halfAngle, clockwise: false)
      var shapes = [path.copy(strokingWithWidth: 2.4, lineCap: .round, lineJoin: .round, miterLimit: 2)]
      for sign in [-1.0, 1.0] {
        let arrow = CGMutablePath()
        let angle = sign * halfAngle
        let base = point(angle)
        let tangent = CGPoint(x: -sin(angle) * sign, y: cos(angle) * sign)
        let normal = CGPoint(x: cos(angle), y: sin(angle))
        // The arc ends at the wide base; the head extends beyond it instead
        // of folding back over the curved shaft and obscuring its silhouette.
        arrow.move(to: CGPoint(x: base.x + tangent.x * 4.5, y: base.y + tangent.y * 4.5))
        arrow.addLine(to: CGPoint(x: base.x + normal.x * 4.5, y: base.y + normal.y * 4.5))
        arrow.addLine(to: CGPoint(x: base.x - normal.x * 4.5, y: base.y - normal.y * 4.5))
        arrow.closeSubpath()
        shapes.append(arrow)
      }
      context.setLineCap(.round)
      context.setLineJoin(.round)
      // Outline all shapes first, then fill them so the solid heads join the shaft.
      context.setStrokeColor(NSColor.white.cgColor)
      context.setLineWidth(2.2)
      for shape in shapes {
        context.addPath(shape)
        context.strokePath()
      }
      context.setFillColor(NSColor.black.cgColor)
      for shape in shapes {
        context.addPath(shape)
        context.fillPath()
      }
      return true
    }
    return NSCursor(image: image, hotSpot: NSPoint(x: 14, y: 14))
  }
  static func rotationDelta(from start: CGPoint, to end: CGPoint, center: CGPoint) -> Double {
    let delta = atan2(end.y - center.y, end.x - center.x)
      - atan2(start.y - center.y, start.x - center.x)
    return atan2(sin(delta), cos(delta)) * 180 / .pi
  }
  struct CropHandle: Equatable {
    // Zero on an axis means that axis stays centered; both zero means move the frame.
    let x: Int
    let y: Int
    static let move = CropHandle(x: 0, y: 0)
    static let rotate = CropHandle(x: 2, y: 2)
  }
  struct CropGesture {
    let handle: CropHandle
    let initialPoint: CGPoint
    let initialRect: CGRect
    let originalCrop: FrameCrop?
    let ratioLocked: Bool
    let draft: FrameCrop
  }
  var cropRect: CGRect? {
    guard let geometry = presentedCropGeometry, displaySize.width > 0, displaySize.height > 0 else {
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
    if gesture.handle == .rotate {
      var draft = gesture.draft
      let delta = Self.rotationDelta(from: gesture.initialPoint, to: point,
        center: CGPoint(x: imageRect.midX, y: imageRect.midY))
      draft.angleDegrees = (min(10, max(-10, draft.angleDegrees + delta)) * 100).rounded() / 100
      model.updateDisplayedCropDraft(draft)
      return
    }
    let dx = (point.x - gesture.initialPoint.x) / imageRect.width * displaySize.width
    let dy = (point.y - gesture.initialPoint.y) / imageRect.height * displaySize.height
    let rect = Self.resizedCropRect(gesture.initialRect, handle: gesture.handle,
      delta: CGPoint(x: dx, y: dy),
      ratio: gesture.ratioLocked ? gesture.draft.ratio : nil)
    var draft = gesture.draft
    if draft.aspect == .free {
      let ratio = Double(rect.width / rect.height)
      draft.freeRatio = draft.portrait ? 1 / ratio : ratio
    }
    draft.centerX = min(2, max(-1, rect.midX / displaySize.width))
    draft.centerY = min(2, max(-1, rect.midY / displaySize.height))
    draft.width = min(2, max(1 / displaySize.width, rect.width / displaySize.width))
    model.updateDisplayedCropDraft(draft)
  }
  static func resizedCropRect(_ initial: CGRect, handle: CropHandle, delta: CGPoint, ratio: Double?) -> CGRect {
    if handle == .move { return initial.offsetBy(dx: delta.x, dy: delta.y) }
    let sx = CGFloat(handle.x), sy = CGFloat(handle.y)
    guard let fixedRatio = ratio else {
      let width = handle.x == 0 ? initial.width : max(1, initial.width + sx * delta.x)
      let height = handle.y == 0 ? initial.height : max(1, initial.height + sy * delta.y)
      let centerX = initial.midX + sx * (width - initial.width) / 2
      let centerY = initial.midY + sy * (height - initial.height) / 2
      return CGRect(x: centerX - width / 2, y: centerY - height / 2, width: width, height: height)
    }
    let ratio = CGFloat(fixedRatio)
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
    context.saveGState()
    // Dim only the rotated photo; keep the surrounding preview backdrop unchanged.
    let image = imageRect
    let angle = CGFloat(presentedCropGeometry?.displayCrop?.angleDegrees ?? 0) * .pi / 180
    let photo = CGPath(rect: image, transform: nil)
    var rotation = CGAffineTransform(translationX: image.midX, y: image.midY)
      .rotated(by: angle).translatedBy(x: -image.midX, y: -image.midY)
    if let rotatedPhoto = photo.copy(using: &rotation) {
      context.addPath(rotatedPhoto)
      context.clip()
    }
    context.addRect(bounds)
    context.addRect(rect)
    context.setFillColor(NSColor.black.withAlphaComponent(0.52).cgColor)
    context.drawPath(using: .eoFill)
    context.restoreGState()
    context.saveGState()
    context.clip(to: rect)
    // Denser fixed grid supplies visual angle references without a separate straighten tool.
    let divisions = abs(presentedCropGeometry?.displayCrop?.angleDegrees ?? 0) > 0.00001 ? 6 : 3
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
