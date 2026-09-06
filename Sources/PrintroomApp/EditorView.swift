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
          ZStack {
            PreviewCanvas(model: model, resetToken: resetToken)
            if model.project == nil { emptyState }
            if model.isLoading {
              ProgressView("正在读取原始 TIFF…").padding(18).background(
                .regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            if model.sampling {
              VStack {
                Label("拖动框选未曝光片基 · 使用原始像素中位数", systemImage: "viewfinder").padding(10).background(
                  .regularMaterial, in: Capsule())
                Spacer()
              }.padding().allowsHitTesting(false)
            }
          }
          HStack {
            Text(model.sampleReadout).font(.system(size: 10, design: .monospaced)).lineLimit(2)
            Spacer()
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
      Button {
        model.exportPanel()
      } label: {
        Label("导出当前照片", systemImage: "square.and.arrow.up")
      }.buttonStyle(.borderedProminent).disabled(!model.hasImage || model.isExporting)
    }.padding(.horizontal, 18).frame(height: 65)
  }
  private var previewToolbar: some View {
    HStack {
      Text(model.activeFrame?.filename ?? "预览").font(
        .system(size: 12, weight: .medium, design: .monospaced)
      ).lineLimit(1)
      if model.sourceWidth > 0 {
        Text("\(model.sourceWidth) × \(model.sourceHeight)").font(.caption2).foregroundStyle(
          .tertiary)
      }
      Spacer()
      Picker("阶段", selection: $model.stage) {
        ForEach(PipelineStage.allCases, id: \.self) { Text($0.label).tag($0) }
      }.labelsHidden().frame(width: 95)
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
          if let calibration = model.project?.calibration, calibration.isCalibrated {
            Label(
              model.project?.calibrationNeedsReview == true ? "片基来源变化 · 请重新采样" : "已校准 · 95 CV",
              systemImage: model.project?.calibrationNeedsReview == true
                ? "exclamationmark.triangle" : "checkmark.circle.fill"
            ).foregroundStyle(accent).font(.caption)
            if let base = calibration.baseRGB { vectorLine("BASE", base) }
            vectorLine("GAIN", calibration.gainRGB)
            vectorLine("OFFSET CV", calibration.filmBaseOffsetCV)
            if !model.baseStatistics.isEmpty {
              Text(model.baseStatistics).font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
            }
          } else {
            Text("尚未校准 · 全卷共享").font(.caption).foregroundStyle(.secondary)
          }
        }
        Divider()
        VStack(alignment: .leading, spacing: 10) {
          heading("02", "TIMING · 当前照片")
          Text(model.activeFrame.map { "正在编辑：\($0.filename)" } ?? "未选择照片").font(.caption2)
            .foregroundStyle(.secondary)
          timingRow("Master", \.master, color: .white)
          timingRow("Red", \.red, color: Color(red: 0.92, green: 0.49, blue: 0.43))
          timingRow("Green", \.green, color: Color(red: 0.48, green: 0.75, blue: 0.55))
          timingRow("Blue", \.blue, color: Color(red: 0.47, green: 0.65, blue: 0.88))
          Text("Q/E  R−/+    A/D  G−/+    Z/C  B−/+\nW / S  Master +1 CV").font(
            .system(size: 9, design: .monospaced)
          ).foregroundStyle(.tertiary)
        }.disabled(model.activeFrame == nil || model.isExporting)
        Divider()
        VStack(alignment: .leading, spacing: 10) {
          heading("03", "RGB CONTRAST")
          contrastRow("Master", \.master)
          contrastRow("Red", \.red)
          contrastRow("Green", \.green)
          contrastRow("Blue", \.blue)
          HStack {
            Text("Pivot")
            Spacer()
            Text("470 CV · 固定")
          }.font(.caption).foregroundStyle(.secondary)
          Button("重置当前照片参数") { model.resetAdjustments() }.font(.caption)
        }.disabled(model.activeFrame == nil || model.isExporting)
        Divider()
        VStack(alignment: .leading, spacing: 7) {
          heading("04", "PIPELINE / OUTPUT")
          Text(
            "输入解释：P3-D65 Linear\n嵌入：\(model.embeddedProfile.isEmpty ? "—":model.embeddedProfile)\n保留原始通道数值，未转换"
          ).font(.system(size: 10)).foregroundStyle(.secondary)
          Text("Kodak 2383 D65 · 33³\n16-bit TIFF · P3 D65 Gamma 2.6\n嵌入 ICC · 无抖动").font(
            .system(size: 10)
          ).foregroundStyle(.secondary)
          if model.stage != .final {
            Text("当前为数值诊断画面；导出始终使用 Final。").font(.caption2).foregroundStyle(accent)
          }
        }
      }.padding(16)
    }.background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
      .onKeyPress(phases: [.down, .repeat]) { press in
        guard !(NSApp.keyWindow?.firstResponder is NSTextView),
          press.modifiers.intersection([.command, .control, .option]).isEmpty,
          press.characters.count == 1, "qeadzcws".contains(press.characters.lowercased())
        else { return .ignored }
        model.handleTimingKey(press.characters)
        return .handled
      }
  }
  private func vectorLine(_ label: String, _ v: SIMD3<Float>) -> some View {
    HStack {
      Text(label).foregroundStyle(.tertiary)
      Spacer()
      Text(String(format: "%.4f  %.4f  %.4f", v.x, v.y, v.z)).foregroundStyle(.secondary)
    }.font(.system(size: 9, design: .monospaced))
  }
  private func timingRow(
    _ title: String, _ path: WritableKeyPath<TimingParameters, Int>, color: Color
  ) -> some View {
    VStack(spacing: 3) {
      HStack {
        Text(title).font(.caption).foregroundStyle(color)
        Spacer()
        TextField(
          "CV",
          value: Binding(
            get: { model.adjustments.timing[keyPath: path] },
            set: { value in model.edit { $0.timing[keyPath: path] = max(-256, min(256, value)) } }),
          format: .number
        ).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 62).font(
          .system(size: 11, design: .monospaced))
        Text("CV").font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
      }
      Slider(
        value: Binding(
          get: { Double(model.adjustments.timing[keyPath: path]) },
          set: { v in model.edit { $0.timing[keyPath: path] = Int(v.rounded()) } }), in: -256...256,
        step: 1,
        onEditingChanged: { if $0 { model.beginAdjustment() } else { model.endAdjustment() } }
      ).tint(color)
    }
  }
  private func contrastRow(_ title: String, _ path: WritableKeyPath<ContrastParameters, Float>)
    -> some View
  {
    HStack(spacing: 8) {
      Text(title).font(.caption).frame(width: 44, alignment: .leading)
      Slider(
        value: Binding(
          get: { Double(model.adjustments.contrast[keyPath: path]) },
          set: { v in model.edit { $0.contrast[keyPath: path] = Float(v) } }), in: 0.25...4,
        step: 0.01,
        onEditingChanged: { if $0 { model.beginAdjustment() } else { model.endAdjustment() } })
      TextField(
        "Contrast",
        value: Binding(
          get: { Double(model.adjustments.contrast[keyPath: path]) },
          set: { v in model.edit { $0.contrast[keyPath: path] = Float(max(0.25, min(4, v))) } }),
        format: .number.precision(.fractionLength(2))
      ).textFieldStyle(.roundedBorder).frame(width: 52).multilineTextAlignment(.trailing).font(
        .system(size: 11, design: .monospaced))
    }
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
              thumbnail(frame, index: index).id(frame.id).onTapGesture {
                filmstripFocused = true
                let flags = NSEvent.modifierFlags
                model.select(
                  frame.id, command: flags.contains(.command), shift: flags.contains(.shift))
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
            if frame.adjustments != FrameAdjustments() {
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
