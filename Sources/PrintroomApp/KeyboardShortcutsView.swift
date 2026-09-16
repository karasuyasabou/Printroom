import SwiftUI

struct ShortcutHelpCommands: Commands {
  @Environment(\.openWindow) private var openWindow

  var body: some Commands {
    CommandGroup(replacing: .help) {
      Button("键盘快捷键…") { openWindow(id: "keyboard-shortcuts") }
        .keyboardShortcut("/", modifiers: [.command, .shift])
    }
  }
}

struct KeyboardShortcutsView: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 8) {
        Label("键盘快捷键", systemImage: "keyboard")
          .font(.title2.weight(.semibold))
      }.padding(24)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          group("调色 · 简易 Timing") {
            row("W / S", "曝光增加 / 减少")
            row("Q / E", "色温偏冷 / 偏暖")
            row("A / D", "色调偏绿 / 偏洋红")
            row("Z / C", "无操作")
          }
          group("调色 · RGB Timing") {
            row("W / S", "Master +1 / −1 CV")
            row("Q / E", "红色 −1 / +1 CV")
            row("A / D", "绿色 −1 / +1 CV")
            row("Z / C", "蓝色 −1 / +1 CV")
          }
          group("反差 · Contrast") {
            row("⌥ + W / S", "Master +0.01 / −0.01")
            row("⌥ + Q / E", "红色 −0.01 / +0.01")
            row("⌥ + A / D", "绿色 −0.01 / +0.01")
            row("⌥ + Z / C", "蓝色 −0.01 / +0.01")
          }
          group("照片与预览") {
            row("← / →", "上一张 / 下一张可用照片")
            row("[ / ]", "向左 / 向右旋转 90°（也支持【 / 】）")
            row("⌘F", "按当前画面水平翻转")
            row("⌘1", "查看 1:1")
            row("I", "开启 / 取消 Final 中性点吸管")
            row("Esc", "取消中性点取样")
            row("R", "进入裁剪")
            row("Enter / Esc", "完成 / 取消裁剪")
            row("W / S / A / D", "裁剪框上 / 下 / 左 / 右移动")
          }
          group("选择与调色快照") {
            row("⌘A", "全选当前胶卷可用照片")
            row("⌘C", "复制当前照片的 Timing、Contrast 与 Cineon Log LUT")
            row("⌘V", "将已复制调色覆盖到全部所选照片")
            row("⌘ + 点击", "添加 / 移除选择，保留当前照片")
            row("⇧ + 点击", "选择连续范围，保留当前照片")
            row("⌘⇧ + 点击", "追加连续范围，保留当前照片")
          }
          group("文件与编辑") {
            row("⌘O", "打开 TIFF、ARW 或胶卷")
            row("⌘S", "保存胶卷设置（平时自动保存）")
            row("⌘⇧E", "导出当前照片")
            row("⌘Z / ⌘⇧Z", "撤销 / 重做")
          }
          group("帮助与窗口") {
            row("⌘⇧/", "打开此快捷键窗口")
            row("⌘W", "关闭当前窗口")
            row("⌘M", "最小化当前窗口")
            row("⌘H / ⌘⌥H", "隐藏 Printroom / 隐藏其他应用")
            row("⌘Q", "退出 Printroom")
            row("Enter / Esc", "确认默认操作 / 取消（对话框支持时）")
          }
        }.padding(24)
      }
    }
    .frame(width: 620, height: 720)
  }

  private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title).font(.headline)
      content()
    }.frame(maxWidth: .infinity, alignment: .leading)
  }

  private func row(_ keys: String, _ action: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 16) {
      Text(keys).font(.system(.body, design: .monospaced).weight(.medium))
        .frame(width: 144, alignment: .leading)
      Text(action).frame(maxWidth: .infinity, alignment: .leading)
    }.fixedSize(horizontal: false, vertical: true)
  }

}
