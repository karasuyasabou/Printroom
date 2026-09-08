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
        let preview = try DisplayImage.make(output, profile: assets.profile)
        guard preview.bitsPerComponent == 16, !preview.bitmapInfo.contains(.floatComponents),
          preview.colorSpace?.copyICCData() as Data? == assets.profile
        else { throw PrintroomError.invalid("SDR 预览格式或 ICC 校验失败") }
        for profile in OutputColorProfile.allCases {
          let converter = try OutputColorConverter(p3Profile: assets.profile, output: profile)
          let converted = try converter.quantized(output)
          guard converted.count == 3 else { throw PrintroomError.invalid("输出 profile 冒烟检查失败") }
        }
        print(
          "Printroom 0.3.0: bundled ICC/LUT and four output profiles verified; Metal \(assets.gpu.deviceName) rendered successfully; \(DisplayImage.presentationVersion) preview verified"
        )
        exit(0)
      } catch {
        fputs("Printroom verification failed: \(error.localizedDescription)\n", stderr)
        exit(1)
      }
    }
  }
  var body: some Scene {
    Window("Printroom 0.3.0", id: "editor") {
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
            model.project == nil || model.isExporting || model.isCropping)
          Button("恢复本卷设置副本…") { model.restoreBackupPanel() }.disabled(
            model.project == nil || model.isExporting || model.isCropping)
          Button("导出当前照片…") { model.exportPanel() }.keyboardShortcut(
            "e", modifiers: [.command, .shift]
          ).disabled(!model.hasImage || model.isExporting || model.isCropping)
        }
        CommandMenu("批量输出") {
          Button("导出所选照片…") { model.batchExportPanel(allFrames: false) }.disabled(model.selection.selectedFrameIDs.isEmpty || model.isExporting || model.isCropping)
          Button("导出整卷…") { model.batchExportPanel(allFrames: true) }.disabled(model.project == nil || model.isExporting || model.isCropping)
          Button("取消导出") { model.cancelExport() }.disabled(!model.isExporting)
        }
        CommandGroup(replacing: .undoRedo) {
          Button("撤销") { model.undo() }.keyboardShortcut("z").disabled(
            !model.canUndo)
          Button("重做") { model.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!model.canRedo)
        }
        CommandMenu("方向") {
          Button("顺时针 90°") { model.changeOrientation(.rotateClockwise) }.disabled(!model.hasImage || model.isCropping)
          Button("逆时针 90°") { model.changeOrientation(.rotateCounterclockwise) }.disabled(!model.hasImage || model.isCropping)
          Button("水平翻转") { model.changeOrientation(.flipHorizontal) }.disabled(!model.hasImage || model.isCropping)
          Button("垂直翻转") { model.changeOrientation(.flipVertical) }.disabled(!model.hasImage || model.isCropping)
          Button("重置方向") { model.changeOrientation(.reset) }.disabled(!model.hasImage || model.isCropping)
          Divider()
          Button("原始分辨率 1:1") { model.inspectNativeResolution() }.keyboardShortcut("1").disabled(!model.hasImage || model.isCropping)
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
