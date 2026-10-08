import AppKit
import PrintroomCore
import Testing
@testable import PrintroomApp

// Exercise the event router with an explicit source window: sandboxed tests
// cannot obtain a WindowServer ID for synthetic NSEvent.window lookup. Native
// responder state is real; OS key dispatch remains a separate UI acceptance.
@MainActor private final class RoutingWindow: NSWindow {
  var routesAsKeyWindow = true
  override var isKeyWindow: Bool { routesAsKeyWindow }
}
@MainActor private final class ThumbnailResponder: NSView {
  override var acceptsFirstResponder: Bool { true }
}

@Suite(.serialized) @MainActor
struct EditorKeyboardRoutingTests {
  private func fixture() -> (EditorModel, RoutingWindow, ShortcutView, ThumbnailResponder) {
    _ = NSApplication.shared
    let model = EditorModel()
    var project = RollProject()
    project.frames = [FrameRecord(filename: "one.tif"), FrameRecord(filename: "two.tif")]
    project.calibration = try! Pipeline.calibrate(
      image: LinearImage(width: 4, height: 4, samples: [UInt16](repeating: 32768, count: 48)),
      rect: .init(x: 0, y: 0, width: 4, height: 4), matrix: project.calibration.matrix,
      sourceFrameID: project.frames[0].id, cmosMatrix: project.calibration.cmosMatrix)
    model.project = project
    model.selection.click(project.frames[0].id, ordered: project.frames.map(\.id))
    model.errorMessage = nil
    let window = RoutingWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let root = NSView(frame: window.contentView!.bounds)
    let router = ShortcutView(model: model)
    let thumbnails = ThumbnailResponder(frame: root.bounds)
    root.addSubview(thumbnails)
    root.addSubview(router)
    window.contentView = root
    window.makeFirstResponder(thumbnails)
    return (model, window, router, thumbnails)
  }

  private func key(_ code: UInt16, _ characters: String, window: NSWindow,
                   modifiers: NSEvent.ModifierFlags = [], type: NSEvent.EventType = .keyDown,
                   repeatKey: Bool = false) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
      timestamp: 0, windowNumber: window.windowNumber, context: nil,
      characters: characters, charactersIgnoringModifiers: characters,
      isARepeat: repeatKey, keyCode: code))
  }

  @Test func returnAndKeypadEnterConfirmPendingCropWithoutRepeating() throws {
    for code: UInt16 in [36, 76] {
      let (model, window, router, thumbnails) = fixture()
      defer { router.stopMonitoring(); window.close() }
      let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PrintroomReturn-\(UUID())")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: folder) }
      let profile = try #require(model.assets).profile
      try TIFFCodec.write(url: folder.appendingPathComponent("one.tif"),
                          width: 200, height: 200, profile: profile) { rows in
        [UInt16](repeating: 32768, count: rows.count * 200 * 3)
      }
      model.folder = folder
      model.sourceWidth = 200
      model.sourceHeight = 200
      model.project?.frames[0].cropNeedsReview = true
      model.reviewOnlyPendingCrops = true
      model.beginCrop()
      let text = NSTextView(frame: .zero)
      window.contentView?.addSubview(text)
      window.makeFirstResponder(text)
      #expect(!router.handle(try key(code, "\r", window: window), from: window))
      #expect(model.activeFrame?.cropNeedsReview == true)
      window.makeFirstResponder(thumbnails)
      #expect(router.handle(try key(code, "\r", window: window, repeatKey: true), from: window))
      #expect(model.activeFrame?.cropNeedsReview == true)
      #expect(model.isCropping)
      #expect(router.handle(try key(code, "\r", window: window), from: window))
      #expect(model.pendingAutoCropFrameIDs.isEmpty)
      #expect(!model.isCropping)
      #expect(!model.reviewOnlyPendingCrops)
      model.beginCrop()
      #expect(router.handle(try key(code, "\r", window: window), from: window))
      #expect(!model.isCropping)
    }
  }

  @Test func thumbnailResponderCanAdjustAndCommandASelectsPhotos() throws {
    let (model, window, router, thumbnails) = fixture()
    defer { router.stopMonitoring(); window.close() }
    #expect(window.firstResponder === thumbnails)
    #expect(router.handle(try key(13, "w", window: window), from: window))
    _ = router.handle(try key(13, "w", window: window, type: .keyUp), from: window)
    #expect(model.adjustments.timing.master == 1)
    #expect(router.handle(try key(0, "a", window: window, modifiers: [.command]), from: window))
    #expect(model.selection.selectedFrameIDs.count == 2)
    #expect(window.firstResponder === thumbnails)
  }

  @Test func wsadNudgesCropDraftOnlyWhileCropping() throws {
    let (model, window, router, _) = fixture()
    defer { router.stopMonitoring(); window.close() }
    model.sourceWidth = 200
    model.sourceHeight = 200
    var project = try #require(model.project)
    project.frames[0].crop = FrameCrop(aspect: .square, centerX: 0.5, centerY: 0.5, width: 0.5)
    model.project = project
    model.beginCrop()
    #expect(model.isCropping)
    #expect(router.handle(try key(13, "w", window: window), from: window))
    #expect(model.displayedCropDraft?.centerY == 0.495)
    #expect(router.handle(try key(0, "a", window: window), from: window))
    #expect(model.displayedCropDraft?.centerX == 0.495)
    #expect(router.handle(try key(1, "s", window: window, repeatKey: true), from: window))
    #expect(router.handle(try key(2, "d", window: window), from: window))
    #expect(model.displayedCropDraft?.centerX == 0.5)
    #expect(model.displayedCropDraft?.centerY == 0.5)
    #expect(model.project?.frames[0].crop?.centerX == 0.5)
    #expect(model.project?.frames[0].crop?.centerY == 0.5)
  }

  @Test func qeAdjustsCropAngleWithRepeatBoundsAndFocusProtection() throws {
    let (model, window, router, thumbnails) = fixture()
    defer { router.stopMonitoring(); window.close() }
    model.sourceWidth = 200
    model.sourceHeight = 200
    model.beginCrop()
    let original = model.project
    #expect(router.handle(try key(12, "q", window: window), from: window))
    #expect(model.displayedCropDraft?.angleDegrees == -0.1)
    #expect(router.handle(try key(12, "q", window: window, repeatKey: true), from: window))
    #expect(model.displayedCropDraft?.angleDegrees == -0.2)
    #expect(router.handle(try key(14, "e", window: window), from: window))
    #expect(model.displayedCropDraft?.angleDegrees == -0.1)
    for modifiers: NSEvent.ModifierFlags in [[.option], [.shift]] {
      _ = router.handle(try key(14, "e", window: window, modifiers: modifiers), from: window)
      #expect(model.displayedCropDraft?.angleDegrees == -0.1)
    }
    let text = NSTextView(frame: .zero)
    window.contentView?.addSubview(text)
    window.makeFirstResponder(text)
    #expect(!router.handle(try key(14, "e", window: window), from: window))
    #expect(model.displayedCropDraft?.angleDegrees == -0.1)
    window.makeFirstResponder(thumbnails)
    model.isLoading = true
    _ = router.handle(try key(14, "e", window: window), from: window)
    #expect(model.displayedCropDraft?.angleDegrees == -0.1)
    model.isLoading = false
    for (code, character, expected) in [(UInt16(14), "e", 10.0), (UInt16(12), "q", -10.0)] {
      for _ in 0..<220 {
        _ = router.handle(try key(code, character, window: window, repeatKey: true), from: window)
      }
      #expect(model.displayedCropDraft?.angleDegrees == expected)
    }
    #expect(model.project?.frames == original?.frames)
    #expect(model.adjustments == FrameAdjustments())
    model.resetCropDraft()
    _ = router.handle(try key(14, "e", window: window), from: window)
    #expect(model.displayedCropDraft?.angleDegrees == 0.1)
    model.cancelCrop()
    #expect(model.project?.frames == original?.frames)
  }

  @Test func commandCopyCapturesSnapshotWithoutAdjustingBlue() throws {
    let (model, window, router, _) = fixture()
    defer { router.stopMonitoring(); window.close() }
    model.edit { $0.timing.master = 12 }
    #expect(router.handle(try key(8, "c", window: window, modifiers: [.command]), from: window))
    let copied = try #require(model.snapshot)
    #expect(model.adjustments.timing.blue == 0)
    model.edit { $0.timing.master = 77 }
    #expect(router.handle(try key(8, "c", window: window, modifiers: [.command], repeatKey: true), from: window))
    #expect(model.snapshot?.adjustments == copied.adjustments)
    model.snapshot = nil
    #expect(router.handle(try key(9, "v", window: window, modifiers: [.command]), from: window))
    #expect(model.adjustments.timing.master == 77)
  }

  @Test func optionDeadKeyAndShiftUseOneHundredthAndReleaseByKeyCode() async throws {
    let (model, window, router, _) = fixture()
    defer { router.stopMonitoring(); window.close() }
    #expect(router.handle(try key(14, "´", window: window, modifiers: [.option, .shift]), from: window))
    #expect(model.adjustments.contrast.red == 1.01)
    #expect(model.adjustments.timing.red == 0)
    _ = router.handle(try key(14, "", window: window, modifiers: [.option], type: .keyUp), from: window)
    try await Task.sleep(for: .milliseconds(500))
    #expect(model.adjustments.contrast.red == 1.01)
    model.undo()
    #expect(model.adjustments.contrast.red == 1)
    #expect(!model.canUndo)
  }

  @Test func nativeTextAndInactiveWindowDoNotConsumeShortcuts() throws {
    let (model, window, router, thumbnails) = fixture()
    defer { router.stopMonitoring(); window.close() }
    let text = NSTextView(frame: .zero)
    window.contentView?.addSubview(text)
    window.makeFirstResponder(text)
    #expect(window.firstResponder === text)
    #expect(!router.handle(try key(13, "w", window: window), from: window))
    #expect(!router.handle(try key(14, "´", window: window, modifiers: [.option]), from: window))
    #expect(!router.handle(try key(0, "a", window: window, modifiers: [.command]), from: window))
    #expect(!router.handle(try key(8, "c", window: window, modifiers: [.command]), from: window))
    #expect(!router.handle(try key(9, "v", window: window, modifiers: [.command]), from: window))
    #expect(model.snapshot == nil)
    #expect(model.adjustments == FrameAdjustments())
    #expect(model.selection.selectedFrameIDs.count == 1)
    window.makeFirstResponder(thumbnails)
    window.routesAsKeyWindow = false
    #expect(!router.handle(try key(13, "w", window: window), from: window))
    window.routesAsKeyWindow = true
    model.errorMessage = "Test dialog"
    #expect(!router.handle(try key(13, "w", window: window), from: window))
    model.errorMessage = nil
    model.showExportDialog = true
    #expect(!router.handle(try key(13, "w", window: window), from: window))
  }

  @Test func modifierChangeAndWindowResignCloseUndoGesture() throws {
    let (model, window, router, _) = fixture()
    defer { router.stopMonitoring(); window.close() }
    #expect(router.handle(try key(13, "w", window: window), from: window))
    _ = router.handle(try key(58, "", window: window, modifiers: [.option], type: .flagsChanged), from: window)
    #expect(model.canUndo)
    #expect(router.handle(try key(13, "∑", window: window, modifiers: [.option]), from: window))
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
    model.undo()
    #expect(model.adjustments.timing.master == 1)
    #expect(model.adjustments.contrast.master == 1)
    model.undo()
    #expect(model.adjustments == FrameAdjustments())
  }
}
