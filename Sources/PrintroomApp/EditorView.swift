import AppKit
import PrintroomCore
import SwiftUI

struct EditorView: View {
  @ObservedObject var model: EditorModel
  @State private var resetToken = 0
  @FocusState private var filmstripFocused: Bool
  private let accent = Color(red: 0.84, green: 0.71, blue: 0.44)
  var body: some View {
    VStack(spacing: 0) {
      topBar
      Divider()
      HStack(spacing: 0) {
        VStack(spacing: 0) {
          previewToolbar
          GeometryReader { viewport in
            ZStack {
              PreviewCanvas(model: model, resetToken: resetToken)
                .frame(width: viewport.size.width, height: viewport.size.height)
              if model.project == nil { emptyState }
              if model.isLoading {
                ProgressView("正在读取原始 TIFF…").padding(18).background(
                  .regularMaterial, in: RoundedRectangle(cornerRadius: 12))
              }
              if model.sampling {
                VStack {
                  Spacer()
                  Label("拖动框选未曝光片基", systemImage: "viewfinder").padding(10).background(
                    .regularMaterial, in: Capsule())
                }.padding().allowsHitTesting(false)
              }
            }
            .frame(width: viewport.size.width, height: viewport.size.height)
            .overlay(alignment: .topTrailing) {
              if model.activeFrame != nil {
                HistogramView(model: model)
                  .frame(width: 248)
                  .padding(12)
              }
            }
            .clipped()
            .contentShape(Rectangle())
          }
          .clipped()
          HStack {
            Text(model.sampleReadout).font(.system(size: 10, design: .monospaced)).lineLimit(2)
            Spacer()
            if model.isDetailLoading { Text("读取 1:1 区域…").font(.caption2) }
            else if model.detailImage != nil { Text("原始像素 1:1").font(.caption2) }
            if model.isRendering { ProgressView().controlSize(.mini) }
          }.foregroundStyle(.secondary).padding(.horizontal, 12).frame(height: 35)
        }
        Divider()
        inspector.frame(width: 306)
      }
      Divider()
      filmstrip.frame(height: 153)
      Divider()
      HStack {
        Circle().fill(model.dirty ? Color.orange : Color.green).frame(width: 5, height: 5)
        Text(model.dirty ? "未保存" : "已保存").font(.caption)
        if model.dirty { Button("重试保存") { model.flushSave() }.buttonStyle(.link).font(.caption) }
        Text(model.status).font(.caption).lineLimit(1)
        Spacer()
        if model.isExporting {
          Text(model.exportDetail).font(.caption2).lineLimit(1)
          ProgressView(value: model.exportProgress).frame(width: 110)
          Text(model.exportProgress, format: .percent.precision(.fractionLength(0))).font(.caption)
          Button("取消") { model.cancelExport() }
        }
        Text("P3 D65 · γ 2.6").font(.system(size: 10, design: .monospaced)).foregroundStyle(
          .secondary)
      }.padding(.horizontal, 14).frame(height: 30)
    }
    .frame(minWidth: 1060, minHeight: 720)
    .background(Color(nsColor: .windowBackgroundColor))
    .background(EditorKeyboardShortcuts(model: model))
    .preferredColorScheme(.dark)
    .tint(accent)
    .alert(
      "操作未完成",
      isPresented: Binding(
        get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    ) {
      if model.saveFailure {
        Button("另存设置副本…") { model.backupPanel() }
        Button("放弃未保存修改并重新载入", role: .destructive) { model.reloadDiscardingUnsaved() }
      }
      Button("好", role: .cancel) { model.errorMessage = nil }
    } message: {
      Text(model.errorMessage ?? "")
    }
    .sheet(isPresented: $model.showExportSummary) { ExportSummaryView(model: model) }
    .onOpenURL { model.open($0) }
  }
  private var topBar: some View {
    HStack(spacing: 14) {
      Image(systemName: "square.stack.3d.down.right").font(.title2).foregroundStyle(accent)
      VStack(alignment: .leading, spacing: 1) {
        Text("PRINTROOM").font(.system(size: 15, weight: .semibold, design: .monospaced)).tracking(
          3)
        Text(model.folder?.lastPathComponent ?? "NEGATIVE → PRINT").font(
          .system(size: 10, design: .monospaced)
        ).foregroundStyle(.secondary)
      }
      Spacer()
      Button {
        model.openPanel()
      } label: {
        Label("打开胶卷", systemImage: "folder")
      }.disabled(model.isExporting)
      Divider().frame(height: 20)
      Button {
        model.copyParameters()
      } label: {
        Label("复制参数", systemImage: "doc.on.doc")
      }.disabled(model.activeFrame == nil)
      Button("应用到 \(model.selection.selectedFrameIDs.count) 张") { model.applyParameters() }
        .disabled(!model.canApply)
      Menu {
        Button("导出当前照片…") { model.exportPanel() }.disabled(!model.hasImage)
        Button("导出选中 \(model.selection.selectedFrameIDs.count) 张…") { model.batchExportPanel(allFrames: false) }
          .disabled(model.selection.selectedFrameIDs.isEmpty)
        Button("导出整卷…") { model.batchExportPanel(allFrames: true) }
        if model.exportSummary != nil {
          Divider()
          Button("查看上次导出结果") { model.showExportSummary = true }
        }
      } label: {
        Label("导出 TIFF", systemImage: "square.and.arrow.up")
      }.menuStyle(.borderlessButton).fixedSize().disabled(model.project == nil || model.isExporting)
      Menu {
        Button("清理本卷缩略图缓存") { model.clearThumbnailCache() }
      } label: {
        Image(systemName: "ellipsis.circle")
      }.menuStyle(.borderlessButton).fixedSize().disabled(model.project == nil)
        .help("胶卷管理").accessibilityLabel("胶卷管理")
    }.padding(.horizontal, 18).frame(height: 65)
  }
  private var previewToolbar: some View {
    HStack {
      Text(model.activeFrame?.filename ?? "预览").font(
        .system(size: 12, weight: .medium, design: .monospaced)
      ).lineLimit(1)
      if model.sourceWidth > 0 {
        Text("\(model.displayWidth) × \(model.displayHeight)").font(.caption2).foregroundStyle(
          .tertiary)
      }
      Spacer()
      Menu("方向") {
        Button("顺时针 90°") { model.changeOrientation(.rotateClockwise) }
        Button("逆时针 90°") { model.changeOrientation(.rotateCounterclockwise) }
        Divider()
        Button("水平翻转 · 当前画面") { model.changeOrientation(.flipHorizontal) }
        Button("垂直翻转 · 当前画面") { model.changeOrientation(.flipVertical) }
        Button("重置方向") { model.changeOrientation(.reset) }
      }.menuStyle(.borderlessButton).foregroundStyle(.primary).fixedSize().disabled(!model.hasImage)
      Picker("阶段", selection: $model.stage) {
        ForEach(PipelineStage.allCases, id: \.self) { Text($0.label).tag($0) }
      }.labelsHidden().frame(width: 95)
      Button("1:1") { model.inspectNativeResolution() }.controlSize(.small).disabled(!model.hasImage)
      Button("适应窗口") { resetToken += 1 }.controlSize(.small)
    }.padding(.horizontal, 12).frame(height: 38)
  }
  private var emptyState: some View {
    VStack(spacing: 20) {
      Image(systemName: "viewfinder.rectangular").font(.system(size: 52, weight: .ultraLight))
        .foregroundStyle(accent)
      Text("一卷底片，一个工作间").font(.title2.weight(.medium))
      Text("打开线性 TIFF，校准片基，再把调色应用到整组选片。").font(.callout).foregroundStyle(.secondary)
      Button("打开 TIFF 或文件夹") { model.openPanel() }.buttonStyle(.borderedProminent)
      Text("16-BIT LINEAR RGB  /  KODAK 2383 D65").font(.system(size: 10, design: .monospaced))
        .tracking(1.5).foregroundStyle(.tertiary)
    }
  }
  private func heading(_ index: String, _ title: String) -> some View {
    HStack {
      Text(index).font(.system(size: 10, design: .monospaced)).foregroundStyle(accent)
      Text(title).font(.system(size: 12, weight: .semibold))
      Spacer()
    }.padding(.bottom, 5)
  }
  private var inspector: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 19) {
        VStack(alignment: .leading, spacing: 10) {
          heading("01", "FILM BASE · 整卷")
          Button {
            model.sampling.toggle()
          } label: {
            Label(model.sampling ? "取消框选" : "框选片基", systemImage: "viewfinder")
          }.frame(maxWidth: .infinity).disabled(!model.hasImage)
          Picker("密度矩阵", selection: Binding(get: { model.matrix }, set: { model.setMatrix($0) })) {
            ForEach(PrintDensityMatrix.allCases, id: \.self) { Text($0.label).tag($0) }
          }
          if model.project?.calibrationNeedsReview == true {
            Label("片基来源变化 · 请重新采样", systemImage: "exclamationmark.triangle")
              .foregroundStyle(accent).font(.caption)
          }
        }
        Divider()
        VStack(alignment: .leading, spacing: 10) {
          heading("02", "COLOR TIMING")
          timingRow("Master", \.master, color: .white)
          timingRow("Red", \.red, color: ChannelColors.red)
          timingRow("Green", \.green, color: ChannelColors.green)
          timingRow("Blue", \.blue, color: ChannelColors.blue)
        }.disabled(model.activeFrame == nil)
        Divider()
        VStack(alignment: .leading, spacing: 10) {
          heading("03", "RGB CONTRAST")
          contrastRow("Master", \.master, color: .white)
          contrastRow("Red", \.red, color: ChannelColors.red)
          contrastRow("Green", \.green, color: ChannelColors.green)
          contrastRow("Blue", \.blue, color: ChannelColors.blue)
          Button("重置当前照片参数") { model.resetAdjustments() }.font(.caption)
        }.disabled(model.activeFrame == nil)
      }.padding(16)
    }.background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
      .onKeyPress(phases: [.down, .repeat]) { press in
        guard !(NSApp.keyWindow?.firstResponder is NSTextView),
          press.modifiers.intersection([.command, .control, .option]).isEmpty,
          press.characters.count == 1, "qeadzcws".contains(press.characters.lowercased())
        else { return .ignored }
        let window = NSApp.keyWindow
        let responder = window?.firstResponder
        model.startTimingKey(press.characters, shift: press.modifiers.contains(.shift),
          isRepeat: press.phase == .repeat) { [weak window, weak responder] in
            window?.isKeyWindow == true && window?.firstResponder === responder
              && window?.attachedSheet == nil && NSApp.modalWindow == nil && NSApp.isActive
          }
        return .handled
      }
  }
  private func timingRow(
    _ title: String, _ path: WritableKeyPath<TimingParameters, Int>, color: Color
  ) -> some View {
    AdjustmentRow(
      title: "Color Timing \(title)",
      value: Binding(
        get: { Double(model.adjustments.timing[keyPath: path]) },
        set: { v in model.edit { $0.timing[keyPath: path] = Int(v.rounded()) } }),
      range: Double(TimingParameters.range.lowerBound)...Double(TimingParameters.range.upperBound),
      step: 1, fractionDigits: 0, color: color,
      onEditingChanged: { if $0 { model.beginAdjustment() } else { model.endAdjustment() } })
  }
  private func contrastRow(
    _ title: String, _ path: WritableKeyPath<ContrastParameters, Float>, color: Color
  ) -> some View {
    AdjustmentRow(
      title: "Contrast \(title)",
      value: Binding(
        get: { Double(model.adjustments.contrast[keyPath: path]) },
        set: { v in model.edit { $0.contrast[keyPath: path] = Float(v) } }),
      range: 0.25...2, step: 0.01, fractionDigits: 2, color: color,
      onEditingChanged: { if $0 { model.beginAdjustment() } else { model.endAdjustment() } })
  }
  private var filmstrip: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("FILMSTRIP").font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(
          1.5)
        Text(
          "\(model.project?.frames.count ?? 0) 张 · 已选 \(model.selection.selectedFrameIDs.count) 张"
        ).font(.caption2).foregroundStyle(.secondary)
        Spacer()
        if let snapshot = model.snapshot {
          Text("已复制：\(snapshot.sourceName)").font(.caption2).foregroundStyle(accent)
        }
        Text("⌘ 多选  ·  Shift 连选").font(.caption2).foregroundStyle(.tertiary)
      }
      ScrollViewReader { proxy in
        ScrollView(.horizontal) {
          LazyHStack(spacing: 8) {
            ForEach(Array((model.project?.frames ?? []).enumerated()), id: \.element.id) {
              index, frame in
              if frame.isMissing {
                thumbnail(frame, index: index).id(frame.id).contextMenu {
                  Button("重新定位此照片…") { model.relocatePanel(frame.id) }
                }
              } else {
                Button {
                  filmstripFocused = true
                  let flags = NSEvent.modifierFlags
                  model.select(frame.id, command: flags.contains(.command), shift: flags.contains(.shift))
                } label: {
                  thumbnail(frame, index: index).contentShape(Rectangle())
                }.buttonStyle(.plain).id(frame.id)
              }
            }
          }.padding(.vertical, 2)
        }.focusable().focused($filmstripFocused)
          .onKeyPress(phases: .down) { press in
            if press.characters.lowercased() == "a" && press.modifiers.contains(.command) {
              model.selectAll()
              return .handled
            }
            return .ignored
          }
          .onChange(of: model.selection.activeFrameID) { _, id in
            if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
          }
      }
    }.padding(.horizontal, 14).padding(.vertical, 10)
  }
  private func thumbnail(_ frame: FrameRecord, index: Int) -> some View {
    let active = frame.id == model.selection.activeFrameID
    let selected = model.selection.selectedFrameIDs.contains(frame.id)
    return VStack(spacing: 4) {
      ZStack {
        Rectangle().fill(Color.black.opacity(0.4))
        if let image = model.thumbnails[frame.id] {
          Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
        } else {
          Image(systemName: frame.isMissing ? "exclamationmark.triangle" : "photo").foregroundStyle(
            .tertiary)
        }
        VStack {
          HStack {
            Text(String(format: "%02d", index + 1)).font(.system(size: 9, design: .monospaced))
              .padding(3).background(.black.opacity(0.65))
            Spacer()
            if frame.adjustments != FrameAdjustments() || frame.orientation != .identity {
              Circle().fill(accent).frame(width: 5, height: 5).padding(5)
            }
          }
          Spacer()
        }
      }.frame(width: 124, height: 78).clipped()
      Text(frame.filename).font(.system(size: 9, design: .monospaced)).lineLimit(1).frame(
        width: 124)
    }.padding(4).background(selected ? accent.opacity(0.16) : Color.clear).overlay(
      RoundedRectangle(cornerRadius: 5).stroke(
        active ? accent : selected ? accent.opacity(0.45) : Color.clear, lineWidth: active ? 2 : 1)
    ).cornerRadius(5).opacity(frame.isMissing ? 0.4 : 1).accessibilityElement(children: .ignore)
      .accessibilityLabel("\(frame.filename)\(active ? "，当前照片":"")\(selected ? "，已选中":"")")
      .accessibilityAddTraits(.isButton)
  }
}
