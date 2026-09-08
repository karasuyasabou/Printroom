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
    #expect(model.adjustments == FrameAdjustments())
    #expect(model.selection.selectedFrameIDs.count == 1)
    window.makeFirstResponder(thumbnails)
    window.routesAsKeyWindow = false
    #expect(!router.handle(try key(13, "w", window: window), from: window))
    window.routesAsKeyWindow = true
    model.errorMessage = "Test dialog"
    #expect(!router.handle(try key(13, "w", window: window), from: window))
    model.errorMessage = nil
    model.showExportSummary = true
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
