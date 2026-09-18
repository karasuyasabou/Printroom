import AppKit
import Testing
@testable import PrintroomApp

@Suite(.serialized) @MainActor
struct EditorWindowCloseTests {
  @Test func closeRequestsQuitAndKeepsWindowWhenQuitIsCancelled() {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let delegate = EditorCloseDelegate()
    var requests = 0
    delegate.requestTermination = { requests += 1 }
    window.delegate = delegate
    window.performClose(nil)
    #expect(requests == 1)
    #expect(delegate.windowShouldClose(window) == false)
  }

  @Test func handlerInstallsOnlyOnItsOwnWindow() {
    let editor = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
    let auxiliary = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
    editor.isReleasedWhenClosed = false
    auxiliary.isReleasedWhenClosed = false
    let view = CloseHandlerView()
    editor.contentView = view
    #expect(editor.delegate is EditorCloseDelegate)
    #expect(auxiliary.delegate == nil)
  }
}
