import AppKit
import PrintroomCore
import SwiftUI

@main struct PrintroomApp: App {
  @StateObject private var model = EditorModel()
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  init() {
    if CommandLine.arguments.contains("--verify-resources") {
      do {
        let assets = try AppAssets()
        let buffer = PixelBuffer(width: 1, height: 1, pixels: [SIMD4<Float>(0.5, 0.4, 0.3, 1)])
        let output = try assets.gpu.render(
          buffer, calibration: FilmCalibration(), adjustments: FrameAdjustments(), lut: assets.lut)
        guard output.pixels[0].x.isFinite else { throw PrintroomError.invalid("GPU 冒烟检查失败") }
        print(
          "Printroom 0.1.0: bundled ICC/LUT hashes verified; Metal \(assets.gpu.deviceName) rendered successfully"
        )
        exit(0)
      } catch {
        fputs("Printroom verification failed: \(error.localizedDescription)\n", stderr)
        exit(1)
      }
    }
  }
  var body: some Scene {
    Window("Printroom", id: "editor") {
      EditorView(model: model).onAppear { delegate.model = model }
    }.defaultSize(width: 1360, height: 900)
      .commands {
        CommandGroup(replacing: .newItem) {
          Button("打开 TIFF 或胶卷…") { model.openPanel() }.keyboardShortcut("o").disabled(
            model.isExporting)
        }
        CommandGroup(replacing: .saveItem) {
          Button("保存胶卷设置") { model.flushSave() }.keyboardShortcut("s")
          Button("另存设置副本…") { model.backupPanel() }.disabled(
            model.project == nil || model.isExporting)
          Button("恢复本卷设置副本…") { model.restoreBackupPanel() }.disabled(
            model.project == nil || model.isExporting)
          Button("导出当前照片…") { model.exportPanel() }.keyboardShortcut(
            "e", modifiers: [.command, .shift]
          ).disabled(!model.hasImage || model.isExporting)
        }
        CommandGroup(replacing: .undoRedo) {
          Button("撤销") { model.undo() }.keyboardShortcut("z").disabled(
            !model.canUndo || model.isExporting)
          Button("重做") { model.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!model.canRedo || model.isExporting)
        }
        CommandMenu("调色") {
          Button("复制参数") { model.copyParameters() }.keyboardShortcut(
            "c", modifiers: [.command, .shift]
          ).disabled(model.activeFrame == nil)
          Button("应用到所选照片") { model.applyParameters() }.keyboardShortcut(
            "v", modifiers: [.command, .shift]
          ).disabled(!model.canApply)
        }
      }
  }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
  weak var model: EditorModel?
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if model?.isExporting == true {
      let alert = NSAlert()
      alert.messageText = "正在导出照片"
      alert.informativeText = "请先完成或取消导出，再退出。"
      alert.runModal()
      return .terminateCancel
    }
    guard model?.flushSave() != false else {
      let alert = NSAlert()
      alert.messageText = "胶卷设置尚未保存"
      alert.informativeText = "请保留窗口，处理保存错误后重试。"
      alert.runModal()
      return .terminateCancel
    }
    return .terminateNow
  }
}
