import AppKit
import PrintroomCore
import SwiftUI

@main struct PrintroomApp: App {
  @AppStorage(AppAppearance.defaultsKey) private var appearance: AppAppearance = .dark
  @StateObject private var history: RecentRolls
  @StateObject private var model: EditorModel
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  init() {
    let history = RecentRolls()
    _history = StateObject(wrappedValue: history)
    _model = StateObject(wrappedValue: EditorModel(recentRolls: history))
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
          "Printroom: bundled ICC/LUT and five output profiles verified; Metal \(assets.gpu.deviceName) rendered successfully; \(DisplayImage.presentationVersion) preview verified"
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
      EditorView(model: model)
        .background(EditorWindowCloseHandler())
        .onAppear { delegate.model = model; appearance.apply() }
        .onChange(of: appearance) { _, value in value.apply() }
    }.defaultSize(width: 1360, height: 900)
      .windowStyle(.hiddenTitleBar)
      .windowToolbarStyle(.unified)
      .commands {
        ShortcutHelpCommands()
        CacheManagerCommands()
        CommandGroup(replacing: .newItem) {
          Menu("最近打开的胶卷") {
            if history.entries.isEmpty { Text("暂无最近胶卷") }
            ForEach(history.entries) { entry in
              Button("\(entry.displayName) — \(entry.path)") { model.openRecent(entry) }
            }
          }.disabled(model.isExporting || history.entries.isEmpty)
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
        CommandGroup(replacing: .undoRedo) {
          Button("撤销") { model.undo() }.keyboardShortcut("z").disabled(
            !model.canUndo)
          Button("重做") { model.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!model.canRedo)
        }
      }
    Window("管理缓存", id: "cache-manager") {
      CacheManagerView()
    }.windowResizability(.contentSize)
    Window("键盘快捷键", id: "keyboard-shortcuts") {
      KeyboardShortcutsView()
    }
    .defaultSize(width: 620, height: 720)
    .windowResizability(.contentSize)
  }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
  weak var model: EditorModel?
  private var cacheMaintenanceTimer: Timer?
  func applicationDidFinishLaunching(_ notification: Notification) {
    SourceProxyService.shared.scheduleMaintenance()
    cacheMaintenanceTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
      SourceProxyService.shared.scheduleMaintenance()
    }
    (AppAppearance(rawValue: UserDefaults.standard.string(forKey: AppAppearance.defaultsKey) ?? "") ?? .dark).apply()
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
