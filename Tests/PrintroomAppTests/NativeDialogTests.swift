import AppKit
import SwiftUI
import Testing
@testable import PrintroomApp

@Suite(.serialized) @MainActor
struct NativeDialogTests {
  @Test func nativeButtonsKeepProgressOpenAndRespectValidation() async throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 400),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.orderFront(nil)
    var starts = 0, cancels = 0
    var dialog = NativeDialog(isPresented: true, title: "色罩分析", primaryTitle: "开始分析",
      primary: { starts += 1 }, cancel: { cancels += 1 },
      accessory: AnyView(Toggle("自动曝光", isOn: .constant(false)).toggleStyle(.checkbox).frame(width: 300)))
    let coordinator = dialog.makeCoordinator()
    defer { coordinator.close(); window.orderOut(nil) }
    coordinator.update(window: window)
    let alert = try #require(coordinator.alert)
    #expect(window.attachedSheet === alert.window)
    alert.buttons[0].performClick(nil)
    #expect(starts == 1)
    #expect(window.attachedSheet === alert.window)
    dialog.title = "正在分析"
    dialog.primaryTitle = nil
    dialog.cancelTitle = "取消分析"
    coordinator.parent = dialog; coordinator.update(window: window)
    #expect(alert.buttons[0].isHidden)
    #expect(!alert.buttons[0].isEnabled)
    alert.buttons[1].performClick(nil)
    #expect(cancels == 1)
    dialog.title = "分析成功"
    dialog.primaryTitle = "应用到整卷"
    dialog.primaryEnabled = false
    coordinator.parent = dialog; coordinator.update(window: window)
    alert.buttons[0].performClick(nil)
    #expect(starts == 1)
    dialog.primaryEnabled = true
    coordinator.parent = dialog; coordinator.update(window: window)
    alert.buttons[0].performClick(nil)
    #expect(starts == 2)
    dialog.isPresented = false
    coordinator.parent = dialog; coordinator.update(window: window)
    #expect(coordinator.alert == nil)
    try await Task.sleep(for: .milliseconds(300))
    #expect(window.attachedSheet == nil)
  }
}
