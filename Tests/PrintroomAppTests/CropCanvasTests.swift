import AppKit
import PrintroomCore
import SwiftUI
import Testing

@testable import PrintroomApp

@Suite(.serialized) @MainActor
struct CropCanvasTests {
  private func fixture(angle: Double = 0) throws -> (EditorModel, CanvasView) {
    let model = EditorModel()
    model.errorMessage = nil
    var project = RollProject()
    let frame = FrameRecord(filename: "crop.tiff")
    project.frames = [frame]
    model.project = project
    model.selection.click(frame.id, ordered: [frame.id])
    model.sourceWidth = 600
    model.sourceHeight = 400
    model.beginCrop()
    model.updateCropDraft(FrameCrop(width: 0.6, angleDegrees: angle))
    model.previewImage = try DisplayImage.make(
      PixelBuffer(width: 60, height: 40,
        pixels: Array(repeating: SIMD4<Float>(0.5, 0.25, 0.1, 1), count: 2400)),
      profile: nil, diagnostic: true)
    let canvas = CanvasView(frame: CGRect(x: 0, y: 0, width: 700, height: 500))
    canvas.model = model
    return (model, canvas)
  }

  private func mouse(_ type: NSEvent.EventType, at point: CGPoint, in view: CanvasView) throws -> NSEvent {
    try #require(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil),
      modifierFlags: [], timestamp: 0, windowNumber: view.window?.windowNumber ?? 0,
      context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
  }

  @Test func panLimitsKeepRotatedPhotoVisibleAndAngleChangesKeepViewportStable() throws {
    let (model, canvas) = try fixture()
    for zoom: CGFloat in [0.25, 1, 1.5, 16] {
      canvas.zoom = zoom
      for direction in [CGPoint(x: -1, y: -1), CGPoint(x: 1, y: -1),
        CGPoint(x: -1, y: 1), CGPoint(x: 1, y: 1)] {
        canvas.pan = CGPoint(x: direction.x * 100_000, y: direction.y * 100_000)
        canvas.constrainPan()
        let pan = canvas.pan
        if zoom >= 1.5 { #expect(pan.x != 0 && pan.y != 0) }
        for angle in [-10.0, 0, 10] {
          var crop = try #require(model.cropDraft)
          crop.angleDegrees = angle
          model.updateCropDraft(crop)
          canvas.constrainPan()
          #expect(canvas.pan == pan)
          let context = try #require(CGContext(data: nil, width: 700, height: 500,
            bitsPerComponent: 8, bytesPerRow: 2800,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
          NSGraphicsContext.saveGraphicsState()
          NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
          canvas.draw(canvas.bounds)
          NSGraphicsContext.restoreGraphicsState()
          let bytes = try #require(context.data).bindMemory(to: UInt8.self, capacity: 700 * 500 * 4)
          // The fixture photo has distinct R/G values; the backdrop, grid and mask are neutral.
          let photoPixels = (0..<(700 * 500)).filter {
            abs(Int(bytes[$0 * 4]) - Int(bytes[$0 * 4 + 1])) > 8
          }.count
          #expect(photoPixels > 100)
          if zoom <= 1 {
            let rect = canvas.imageRect
            let radians = CGFloat(angle) * .pi / 180
            for x in [rect.minX, rect.maxX] {
              for y in [rect.minY, rect.maxY] {
                let dx = x - rect.midX, dy = y - rect.midY
                let rotated = CGPoint(x: rect.midX + dx * cos(radians) - dy * sin(radians),
                  y: rect.midY + dx * sin(radians) + dy * cos(radians))
                #expect(canvas.bounds.insetBy(dx: -0.0001, dy: -0.0001).contains(rotated))
              }
            }
          }
        }
      }
    }
  }

  @Test func freeHandlesResizeEachDimensionAndKeepOppositeAnchor() {
    let initial = CGRect(x: 100, y: 90, width: 300, height: 200)
    for x in -1...1 {
      for y in -1...1 where x != 0 || y != 0 {
        let resized = CanvasView.resizedCropRect(initial, handle: .init(x: x, y: y),
          delta: CGPoint(x: 32, y: -19), ratio: nil)
        #expect(resized.width == initial.width + CGFloat(x) * 32)
        #expect(resized.height == initial.height - CGFloat(y) * 19)
        if x < 0 { #expect(resized.maxX == initial.maxX) }
        if x > 0 { #expect(resized.minX == initial.minX) }
        if y < 0 { #expect(resized.maxY == initial.maxY) }
        if y > 0 { #expect(resized.minY == initial.minY) }
      }
    }
    let minimum = CanvasView.resizedCropRect(initial, handle: .init(x: 1, y: 1),
      delta: CGPoint(x: -1000, y: -1000), ratio: nil)
    #expect(minimum == CGRect(x: 100, y: 90, width: 1, height: 1))
  }

  @Test func freeEdgeDragKeepsOtherDimensionThroughModelConversion() throws {
    let (model, canvas) = try fixture()
    model.updateCropDraft(FrameCrop(aspect: .free, width: 0.6, freeRatio: 1.8))
    model.setCropRatioLocked(false)
    let before = try #require(model.cropDraftGeometry)
    let rect = try #require(canvas.cropRect)
    let start = CGPoint(x: rect.maxX, y: rect.midY)
    let end = CGPoint(x: start.x - canvas.imageRect.width * 30 / 600, y: start.y)
    try canvas.mouseDown(with: mouse(.leftMouseDown, at: start, in: canvas))
    try canvas.mouseDragged(with: mouse(.leftMouseDragged, at: end, in: canvas))
    try canvas.mouseUp(with: mouse(.leftMouseUp, at: end, in: canvas))
    let after = try #require(model.cropDraftGeometry)
    #expect(after.outputWidth == before.outputWidth - 30)
    #expect(after.outputHeight == before.outputHeight)
    #expect(model.cropDraft?.aspect == .free)
  }

  @Test func ratioLockSelectionSwapAndReset() throws {
    let (model, canvas) = try fixture()
    #expect(model.cropRatioLocked)
    model.selectCropRatio(1.8)
    let before = try #require(model.cropDraftGeometry)
    let rect = try #require(canvas.cropRect)
    let start = CGPoint(x: rect.maxX, y: rect.midY)
    let end = CGPoint(x: start.x - 40, y: start.y)
    try canvas.mouseDown(with: mouse(.leftMouseDown, at: start, in: canvas))
    try canvas.mouseDragged(with: mouse(.leftMouseDragged, at: end, in: canvas))
    try canvas.mouseUp(with: mouse(.leftMouseUp, at: end, in: canvas))
    let after = try #require(model.cropDraftGeometry)
    #expect(after.outputWidth < before.outputWidth)
    #expect(after.outputHeight < before.outputHeight)
    #expect(abs(Double(after.outputWidth) / Double(after.outputHeight) - 1.8) < 0.02)
    model.setCropRatioLocked(false)
    #expect(!model.cropRatioLocked)
    let ratio = model.currentDisplayedCrop.ratio
    model.swapCropRatio()
    #expect(abs(model.currentDisplayedCrop.ratio - 1 / ratio) < 0.02)
    model.selectCropRatio(4.0 / 3, aspect: .fourThree)
    #expect(model.cropRatioLocked)
    model.resetCropDraft()
    #expect(model.cropRatioLocked && model.cropDraft == nil)
    #expect(model.currentDisplayedCrop.ratio == 1.5)
  }

  @Test func rotationCursorsFollowEightRegionsAndKeepResizePriority() throws {
    let (model, canvas) = try fixture()
    defer { withExtendedLifetime(model) {} }
    let rect = try #require(canvas.cropRect)
    let directions = [(1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1)]
    for (index, direction) in directions.enumerated() {
      let point = CGPoint(x: rect.midX + CGFloat(direction.0) * (rect.width / 2 + 24),
        y: rect.midY + CGFloat(direction.1) * (rect.height / 2 + 24))
      #expect(CanvasView.rotationCursorDirection(at: point, around: rect) == index)
      #expect(canvas.cursor(at: point) === CanvasView.rotationCursors[index])
      #expect(CanvasView.rotationCursors[index].hotSpot == CGPoint(x: 14, y: 14))
    }
    #expect(canvas.cursor(at: CGPoint(x: rect.maxX, y: rect.midY)) === NSCursor.resizeLeftRight)
    #expect(canvas.cursor(at: CGPoint(x: rect.maxX, y: rect.minY)) === NSCursor.crosshair)
    #expect(canvas.cursor(at: CGPoint(x: -1, y: -1)) === NSCursor.arrow)
    if let output = ProcessInfo.processInfo.environment["PRINTROOM_CURSOR_QA_PATH"] {
      let sheet = NSImage(size: NSSize(width: 384, height: 96), flipped: false) { _ in
        for row in 0..<2 {
          (row == 0 ? NSColor(white: 0.85, alpha: 1) : NSColor(white: 0.2, alpha: 1)).setFill()
          NSRect(x: 0, y: row * 48, width: 384, height: 48).fill()
          for index in 0..<8 {
            CanvasView.rotationCursors[index].image.draw(in:
              NSRect(x: index * 48 + 10, y: row * 48 + 10, width: 28, height: 28))
          }
        }
        return true
      }
      let data = try #require(sheet.tiffRepresentation)
      let bitmap = try #require(NSBitmapImageRep(data: data))
      try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
    }
  }

  @Test func outsideDragRotatesAboutImageCenterAndOutsideReleaseCancels() throws {
    let (model, canvas) = try fixture()
    let original = model.cropDraft
    let center = CGPoint(x: canvas.imageRect.midX, y: canvas.imageRect.midY)
    let start = CGPoint(x: center.x + canvas.imageRect.width * 0.45, y: center.y)
    let radius = start.x - center.x
    let end = CGPoint(x: center.x + radius * cos(5 * .pi / 180),
      y: center.y + radius * sin(5 * .pi / 180))
    #expect(canvas.cursor(at: start) === CanvasView.rotationCursors[0])
    try canvas.mouseDown(with: mouse(.leftMouseDown, at: start, in: canvas))
    try canvas.mouseDragged(with: mouse(.leftMouseDragged, at: end, in: canvas))
    #expect(model.displayedCropDraft?.angleDegrees == 5)
    #expect(canvas.pan == .zero)
    #expect(model.activeFrame?.crop == nil)
    try canvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: -1, y: 0), in: canvas))
    #expect(model.cropDraft == original)
    #expect(abs(CanvasView.rotationDelta(from: CGPoint(x: -1, y: 0.01),
      to: CGPoint(x: -1, y: -0.01), center: .zero)) < 2)
  }

  @Test func cornersAndEdgesKeepRatioAndTheirOppositeAnchor() {
    let rect = CGRect(x: 100, y: 90, width: 300, height: 200)
    for ratio in [1.5, 4.0 / 3, 1, 7.0 / 6] {
      let initial = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.width / ratio)
      for x in -1...1 {
        for y in -1...1 where x != 0 || y != 0 {
          let resized = CanvasView.resizedCropRect(initial,
            handle: .init(x: x, y: y), delta: CGPoint(x: 32, y: -19), ratio: ratio)
          #expect(abs(resized.width / resized.height - ratio) < 1e-12)
          if x < 0 { #expect(abs(resized.maxX - initial.maxX) < 1e-10) }
          if x > 0 { #expect(abs(resized.minX - initial.minX) < 1e-10) }
          if x == 0 { #expect(resized.midX == initial.midX) }
          if y < 0 { #expect(abs(resized.maxY - initial.maxY) < 1e-10) }
          if y > 0 { #expect(abs(resized.minY - initial.minY) < 1e-10) }
          if y == 0 { #expect(resized.midY == initial.midY) }
        }
      }
    }
  }

  @Test func handleHitTestingIncludesFourCornersFourSidesAndInterior() throws {
    let (model, canvas) = try fixture()
    let rect = try #require(canvas.cropRect)
    for x in -1...1 {
      for y in -1...1 {
        let point = CGPoint(x: rect.midX + CGFloat(x) * rect.width / 2,
          y: rect.midY + CGFloat(y) * rect.height / 2)
        #expect(canvas.cropHandle(at: point, rect: rect) == .init(x: x, y: y))
      }
    }
    #expect(canvas.cropHandle(at: CGPoint(x: rect.minX - 20, y: rect.midY), rect: rect) == nil)
    #expect(model.isCropping)
  }

  @Test func cropDragUsesFullResolutionAndOnlyChangesDraft() throws {
    let (model, canvas) = try fixture(angle: 7.25)
    let before = try #require(model.cropDraftGeometry)
    let rect = try #require(canvas.cropRect)
    let start = CGPoint(x: rect.midX, y: rect.midY)
    let end = CGPoint(x: start.x + canvas.imageRect.width * 30 / 600,
      y: start.y + canvas.imageRect.height * 20 / 400)
    try canvas.mouseDown(with: mouse(.leftMouseDown, at: start, in: canvas))
    try canvas.mouseDragged(with: mouse(.leftMouseDragged, at: end, in: canvas))
    try canvas.mouseUp(with: mouse(.leftMouseUp, at: end, in: canvas))
    let after = try #require(model.cropDraftGeometry)
    #expect(abs(after.rect.midX - before.rect.midX - 30) < 1e-8)
    #expect(abs(after.rect.midY - before.rect.midY - 20) < 1e-8)
    #expect(after.outputWidth == before.outputWidth && after.outputHeight == before.outputHeight)
    #expect(model.activeFrame?.crop == nil)
    #expect(model.cropDraft?.angleDegrees == 7.25)
    #expect(canvas.pan == .zero && canvas.zoom == 1)
  }

  @Test func edgeResizeAndOutsideReleaseRestoreDraftWithoutChangingViewport() throws {
    let (model, canvas) = try fixture()
    let original = model.cropDraft
    let rect = try #require(canvas.cropRect)
    let start = CGPoint(x: rect.maxX, y: rect.midY)
    let end = CGPoint(x: start.x - 35, y: start.y)
    try canvas.mouseDown(with: mouse(.leftMouseDown, at: start, in: canvas))
    try canvas.mouseDragged(with: mouse(.leftMouseDragged, at: end, in: canvas))
    #expect((model.cropDraft?.width ?? 0) < (original?.width ?? 0))
    try canvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: -1, y: start.y), in: canvas))
    #expect(model.cropDraft == original)
    #expect(canvas.cropGesture == nil && canvas.start == nil)
    #expect(canvas.pan == .zero && canvas.zoom == 1)
  }

  @Test func fineRotationDoesNotRefitAndItsFullEnvelopeStaysInsideViewport() throws {
    let (model, canvas) = try fixture()
    let scale = canvas.fitScale
    let original = canvas.imageRect
    for angle in [-10.0, -4.1, 0, 8.73, 10] {
      var draft = try #require(model.cropDraft)
      draft.angleDegrees = angle
      model.updateCropDraft(draft)
      #expect(canvas.fitScale == scale && canvas.imageRect == original)
      let radians = angle * .pi / 180
      for corner in canvas.cropCorners(original) {
        let dx = corner.x - original.midX, dy = corner.y - original.midY
        let point = CGPoint(x: original.midX + cos(radians) * dx - sin(radians) * dy,
          y: original.midY + sin(radians) * dx + cos(radians) * dy)
        #expect(canvas.bounds.contains(point))
      }
    }
  }

  @Test func minimumWindowKeepsCropControlsAndPreviewInsideEditorColumn() async throws {
    _ = NSApplication.shared
    let (model, _) = try fixture(angle: 4.75)
    let host = NSHostingView(rootView: EditorView(model: model))
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1060, height: 720),
      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(80))
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let views = descendants(host)
    let canvas = try #require(views.compactMap { $0 as? CanvasView }.first)
    let viewport = canvas.convert(canvas.bounds, to: host)
    #expect(abs(host.bounds.width - 1060) <= 1)
    #expect(abs(viewport.maxX - 753) <= 1)
    #expect(canvas.bounds.height > 330)
    let top = host.isFlipped ? viewport.minY : host.bounds.height - viewport.maxY
    #expect(abs(top - 39) <= 2) // One crop row plus divider; main toolbar is native.
    // Native sliders/text fields above the preview belong to crop controls.
    let cropControls = views.filter { $0 is NSSlider || $0 is NSTextField }.filter { control in
      let frame = control.convert(control.bounds, to: host)
      let y = host.isFlipped ? frame.midY : host.bounds.height - frame.midY
      return y > 0 && y < top
    }
    #expect(!cropControls.isEmpty)
    for control in cropControls {
      let frame = control.convert(control.bounds, to: host)
      #expect(frame.minX >= 0 && frame.maxX <= viewport.maxX)
      let y = host.isFlipped ? frame.midY : host.bounds.height - frame.midY
      #expect(abs(y - 19) <= 4)
    }
  }
}
