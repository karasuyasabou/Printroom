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
    #expect(abs(top - 143) <= 2) // 104 px preview toolbar + one 38 px crop row + divider.
    // Native sliders/text fields above the preview belong to crop controls.
    let cropControls = views.filter { $0 is NSSlider || $0 is NSTextField }.filter { control in
      let frame = control.convert(control.bounds, to: host)
      let y = host.isFlipped ? frame.midY : host.bounds.height - frame.midY
      return y > 104 && y < top
    }
    for control in cropControls {
      let frame = control.convert(control.bounds, to: host)
      #expect(frame.minX >= 0 && frame.maxX <= viewport.maxX)
      let y = host.isFlipped ? frame.midY : host.bounds.height - frame.midY
      #expect(abs(y - 123) <= 4)
    }
  }
}
