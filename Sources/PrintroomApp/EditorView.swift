import AppKit
import PrintroomCore
import SwiftUI

struct EditorView: View {
  @Environment(\.openWindow) private var openWindow
  @ObservedObject var model: EditorModel
  @State private var resetToken = 0
  @State private var viewportMode: PreviewViewportMode? = .fit
  @State private var showPreviewLoadingHint = false
  @State private var showAutoCropDialog = false
  private let accent = Color(red: 0.84, green: 0.71, blue: 0.44)
  var body: some View {
    VStack(spacing: 0) {
      topBar
      if model.saveFailure || model.isExporting { operationStatus }
      Divider()
      HStack(spacing: 0) {
        VStack(spacing: 0) {
          ZStack {
            if model.isCropping {
              CropControlsView(model: model)
            } else {
              previewToolbar
            }
          }.frame(height: 38)
          GeometryReader { viewport in
            ZStack {
              PreviewCanvas(model: model, resetToken: resetToken, onViewportChange: { viewportMode = $0 })
                .frame(width: viewport.size.width, height: viewport.size.height)
              if model.project == nil { emptyState }
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
              if model.activeFrame != nil && !model.isCropping {
                HistogramView(model: model)
                  .padding(12)
              }
            }
            .overlay(alignment: .bottomLeading) {
              if showPreviewLoadingHint {
                Text("正在加载预览…")
                  .font(.caption2).foregroundStyle(.secondary)
                  .padding(8).background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                  .padding(12).allowsHitTesting(false)
              }
            }
            .clipped()
            .contentShape(Rectangle())
          }
          .clipped()
        }
        Divider()
        inspector.frame(width: 306)
      }
      Divider()
      filmstrip.frame(height: 153)
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
      if model.activeFrame != nil && !model.saveFailure {
        Button("重新载入照片") { model.errorMessage = nil; model.loadActive() }
      }
      Button("好", role: .cancel) { model.errorMessage = nil }
    } message: {
      Text(model.errorMessage ?? "")
    }
    .sheet(isPresented: $showAutoCropDialog) {
      AutoCropDialogView(model: model, isPresented: $showAutoCropDialog)
    }
    .sheet(item: $model.matrixManager) { kind in MatrixManagerView(model: model, kind: kind) }
    .sheet(isPresented: $model.showExportSummary) { ExportSummaryView(model: model) }
    .onOpenURL { model.open($0) }
    .task(id: previewIsWaiting) {
      showPreviewLoadingHint = false
      guard previewIsWaiting else { return }
      do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
      guard !Task.isCancelled, previewIsWaiting else { return }
      showPreviewLoadingHint = true
    }
  }
  private var previewIsWaiting: Bool {
    model.project != nil && model.previewImage == nil && (model.isLoading || model.isRendering)
  }
  private var operationStatus: some View {
    HStack(spacing: 10) {
      if model.saveFailure {
        Label("设置未保存", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        Button("重试保存") { model.flushSave() }.buttonStyle(.link)
      }
      if model.isLoading || model.isDetailLoading || model.isNeutralSampling || model.isPreparingGeometry {
        Text(model.isLoading ? "正在准备图像预览…" : "正在准备原始精度图像…")
          .font(.caption).foregroundStyle(.secondary)
      }
      Spacer(minLength: 10)
      if model.isExporting {
        Text(model.exportDetail).lineLimit(1)
        ProgressView(value: model.exportProgress).frame(width: 110)
        Text(model.exportProgress, format: .percent.precision(.fractionLength(0)))
          .monospacedDigit().frame(width: 34, alignment: .trailing)
        Button("取消导出") { model.cancelExport() }.controlSize(.small)
      }
    }.font(.caption2).padding(.horizontal, 18).padding(.bottom, 8)
  }
  private var topBar: some View {
    HStack(spacing: 10) {
      Image(systemName: "square.stack.3d.down.right").font(.title2).foregroundStyle(accent)
      VStack(alignment: .leading, spacing: 1) {
        Text("PRINTROOM").font(.system(size: 15, weight: .semibold, design: .monospaced)).tracking(
          3)
        Text(model.folder?.lastPathComponent ?? "NEGATIVE → PRINT").font(
          .system(size: 10, design: .monospaced)
        ).foregroundStyle(.secondary).lineLimit(1)
      }.frame(maxWidth: 190, alignment: .leading)
      Spacer(minLength: 10)
      Button {
        NSApp.keyWindow?.makeFirstResponder(nil)
        model.returnHome()
      } label: {
        Label("回到主页", systemImage: "house")
      }.disabled(model.project == nil || model.isExporting)
      Button {
        model.openPanel()
      } label: {
        Label("打开胶卷", systemImage: "folder")
      }.disabled(model.isExporting)
      Divider().frame(height: 20)
      Button {
        model.resetAdjustments()
      } label: {
        Label("重置调色", systemImage: "arrow.counterclockwise")
      }.disabled(model.activeFrame == nil)
        .help("重置当前照片的 Timing、Contrast 与 Cineon Log LUT · 可撤销")
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
      }.menuStyle(.borderlessButton).fixedSize()
        .disabled(model.project == nil || model.isExporting || model.isCropping)

    }.padding(.horizontal, 18).frame(height: 65)
  }
  private var previewToolbar: some View {
    HStack {
      Text(model.activeFrame?.filename ?? "预览").font(
        .system(size: 12, weight: .medium, design: .monospaced)
      ).lineLimit(1).truncationMode(.middle).layoutPriority(-1)
      if model.sourceWidth > 0 {
        Text("\(model.displayWidth) × \(model.displayHeight)").font(.caption2).foregroundStyle(
          .tertiary)
      }
      Spacer()
      HStack(spacing: 4) {
        Button { showAutoCropDialog = true } label: {
          PreviewToolLabel { Label("自动裁切", systemImage: "viewfinder") }
        }.buttonStyle(.plain).fixedSize()
          .disabled(!model.canStartAutoCrop)
          .help("设置并分析整卷自动裁切")
        Button { model.beginCrop() } label: {
          PreviewToolLabel(selected: model.isCropping) {
            Label("裁剪", systemImage: "crop")
          }
        }.buttonStyle(.plain).fixedSize()
          .disabled(!model.hasImage || model.isCropping || model.isAutoCropping)
          .help("裁剪与精细角度 · R")
        PreviewToolMenu(title: "方向") {
          Button("顺时针 90°") { model.changeOrientation(.rotateClockwise) }
          Button("逆时针 90°") { model.changeOrientation(.rotateCounterclockwise) }
          Divider()
          Button("水平翻转 · 当前画面") { model.changeOrientation(.flipHorizontal) }
          Button("垂直翻转 · 当前画面") { model.changeOrientation(.flipVertical) }
          Divider()
          Button("重置方向") { model.changeOrientation(.reset) }
        }.disabled(!model.hasImage || model.isCropping)
      }
      previewToolDivider
      PreviewToolMenu(title: "管线预览", value: pipelinePreviewTitle) {
        ForEach([PipelineStage.l2, .d3, .final], id: \.self) { stage in
          Toggle(pipelinePreviewTitle(for: stage), isOn: Binding(
            get: { model.stage == stage },
            set: { selected in if selected { model.stage = stage } }
          ))
        }
      }.help("管线预览：\(pipelinePreviewTitle)")
      previewToolDivider
      HStack(spacing: 0) {
        Button { resetToken += 1 } label: {
          PreviewToolLabel(selected: viewportMode == .fit) { Text("适应") }
        }.help("适应窗口 · 双击照片复位")
        Button { model.inspectNativeResolution() } label: {
          PreviewToolLabel(selected: viewportMode == .native) {
            Text("100%")
          }
        }
        .opacity(model.isDetailLoading ? 0.5 : 1)
        .help(model.activeFrame?.rawProcessing != nil
          ? "放大代理查看；全尺寸仅用于导出 · ⌘1"
          : (model.isDetailLoading ? "正在读取原始分辨率区域" : "查看原始分辨率 · ⌘1"))
      }
      .buttonStyle(.plain)
      .padding(2)
      .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
      .disabled(!model.hasImage || model.isCropping)
    }.padding(.horizontal, 12).frame(height: 38)
      .tint(Color(white: 0.8))
  }
  private var previewToolDivider: some View {
    Rectangle().fill(.white.opacity(0.10)).frame(width: 1, height: 14)
      .padding(.horizontal, 4)
  }
  private var pipelinePreviewTitle: String { pipelinePreviewTitle(for: model.stage) }
  private func pipelinePreviewTitle(for stage: PipelineStage) -> String {
    switch stage {
    case .l2: "线性"
    case .d3: "密度"
    default: "输出"
    }
  }

  private var emptyState: some View {
    VStack(spacing: 12) {
      Image(systemName: "viewfinder.rectangular").font(.system(size: model.recentRolls != nil ? 32 : 52, weight: .ultraLight))
        .foregroundStyle(accent)
      HStack(spacing: 10) {
        Button("打开底片文件夹") { model.openPanel() }.buttonStyle(.borderedProminent)
        Button { openWindow(id: "cache-manager") } label: {
          Label("管理缓存", systemImage: "internaldrive")
        }.buttonStyle(.bordered)
      }
      Text("16-BIT LINEAR RGB  /  CINEON LOG LUT").font(.system(size: 10, design: .monospaced))
        .tracking(1.5).foregroundStyle(.tertiary)
      if let history = model.recentRolls { RecentRollsView(history: history, model: model) }
    }
  }
  private func heading(_ index: String, _ title: String, bottomPadding: CGFloat = 5) -> some View {
    HStack {
      Text(index).font(.system(size: 10, design: .monospaced)).foregroundStyle(accent)
      Text(title).font(.system(size: 12, weight: .semibold))
      Spacer()
    }.padding(.bottom, bottomPadding)
  }
  private func matrixPicker(_ kind: MatrixKind) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(kind.label).font(.caption).foregroundStyle(.secondary)
      Picker(kind.label, selection: Binding(
        get: { kind == .cmos ? model.cmosMatrix : model.matrix },
        set: { model.setMatrixPreset($0, kind: kind) })) {
          ForEach(model.matrixOptions(kind), id: \.self) { value in
            Text(value.label + (model.isMatrixSnapshot(value, kind: kind) ? " · 本卷快照" : ""))
              .tag(value)
          }
        }.labelsHidden().disabled(model.project == nil)
        .accessibilityLabel(kind.label)
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  private var inspector: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        VStack(alignment: .leading, spacing: 10) {
          HStack {
            heading("01", "矩阵矫正 · 整卷", bottomPadding: 0)
            Button("管理矩阵") {
              model.stopTimingKey()
              model.showMatrixMenu = true
            }
            .buttonStyle(.borderless)
            .popover(isPresented: $model.showMatrixMenu, arrowEdge: .bottom) {
              VStack(alignment: .leading, spacing: 12) {
                ForEach(MatrixKind.allCases) { kind in
                  Button("管理\(kind.label)…") {
                    model.showMatrixMenu = false
                    model.reloadMatrixLibrary()
                    model.matrixManager = kind
                  }.buttonStyle(.plain)
                }
              }.padding(16)
            }
          }
          HStack(spacing: 10) {
            matrixPicker(.cmos)
            matrixPicker(.density)
          }
        }
        Divider()
        VStack(alignment: .leading, spacing: 10) {
          HStack(spacing: 6) {
            heading("02", "FILM BASE 对齐 · 整卷", bottomPadding: 0)
              .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
            Button {
              model.sampling.toggle()
            } label: {
              Label(model.sampling ? "取消框选" : "框选片基", systemImage: "viewfinder")
            }.controlSize(.regular).font(.system(size: 13))
              .fixedSize().disabled(!model.hasImage || model.isCropping)
          }
          if model.project?.calibrationNeedsReview == true {
            Label("片基来源变化 · 请重新采样", systemImage: "exclamationmark.triangle")
              .foregroundStyle(accent).font(.caption)
          }
        }
        Divider()
        VStack(alignment: .leading, spacing: 10) {
          HStack(spacing: 8) {
            Text("03").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            Text("TIMING").font(.system(size: 11, weight: .medium))
            Spacer(minLength: 0)
            Picker("Timing 模式", selection: $model.timingMode) {
              Text("简易").tag(TimingMode.simple)
              Text("RGB").tag(TimingMode.rgb)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 108)
              .help("切换 Timing 控件与快捷键，保持照片参数")
            Button {
              model.toggleNeutralPicker()
            } label: {
              Image(systemName: "eyedropper")
                .foregroundStyle(model.neutralPicking ? accent : Color.secondary)
                .opacity(model.isNeutralSampling ? 0.4 : 1)
                .frame(width: 24, height: 20)
            }.buttonStyle(.plain)
              .disabled(!model.canPickNeutral || model.isNeutralSampling)
              .help(model.neutralPicking ? "点击照片，使 Final 取样位置中性并保持亮度 · I / Esc 取消" : "Final 中性点吸管 (I) · 保持亮度")
              .accessibilityLabel(model.neutralPicking ? "取消 Final 中性点吸管" : "标定 Final 中性点，保持亮度")
          }
          VStack(spacing: 9) {
            if model.timingMode == .simple {
              simpleTimingRow(.exposure, color: .white)
              simpleTimingRow(.temperature, color: .orange)
              simpleTimingRow(.tint, color: .purple)
              Color.clear.frame(height: 24)
            } else {
              timingRow("Master", \.master, color: .white)
              timingRow("Red", \.red, color: ChannelColors.red)
              timingRow("Green", \.green, color: ChannelColors.green)
              timingRow("Blue", \.blue, color: ChannelColors.blue)
            }
          }
        }.disabled(model.activeFrame == nil)
        Divider()
        VStack(alignment: .leading, spacing: 9) {
          heading("04", "RGB CONTRAST")
          contrastRow("Master", \.master, color: .white)
          contrastRow("Red", \.red, color: ChannelColors.red)
          contrastRow("Green", \.green, color: ChannelColors.green)
          contrastRow("Blue", \.blue, color: ChannelColors.blue)
        }.disabled(model.activeFrame == nil)
        Divider()
        HStack(spacing: 6) {
          heading("05", "Cineon Log LUT", bottomPadding: 0)
            .fixedSize(horizontal: true, vertical: false)
          Picker("Cineon Log LUT", selection: Binding(
            get: { model.adjustments.cineonLogLUT },
            set: { value in model.edit { $0.cineonLogLUT = value } })) {
              ForEach(CineonLogLUT.allCases, id: \.self) { lut in Text(lut.label).tag(lut) }
            }.labelsHidden()
        }.disabled(model.activeFrame == nil)
      }.padding(16)
    }.background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
  }
  private func simpleTimingRow(_ axis: SimpleTimingAxis, color: Color) -> some View {
    HStack(spacing: 6) {
      Text(axis.title).font(.system(size: 11)).frame(width: 28, alignment: .leading)
      AdjustmentRow(title: axis.help,
        value: Binding(get: { axis.value(in: model.adjustments.timing) },
          set: { model.setSimpleTiming(axis, value: $0) }),
        range: axis.range, step: 1, fractionDigits: 0, color: color,
        onEditingChanged: { if $0 { model.beginAdjustment() } else { model.endAdjustment() } },
        resetValue: 0, quantizesValue: false, valueWidth: 72)
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
        if let snapshot = model.snapshot, !model.isAutoCropping {
          Text("已复制调色：\(snapshot.sourceName)").font(.caption2).foregroundStyle(accent)
        }
        Button("同步…") { model.beginSync() }
          .disabled(!model.canSync)
          .help(model.isCropping ? "先完成当前照片裁剪，再同步" : "把当前照片的设置同步到其余所选照片")
          .popover(isPresented: $model.showSync, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 14) {
              Text("同步当前照片").font(.headline)
              Text("来源：\(model.activeFrame?.filename ?? "")").lineLimit(2)
              Text("目标：其余 \(model.syncTargetIDs.count) 张").foregroundStyle(.secondary)
              Divider()
              Toggle("RGB Timing", isOn: $model.syncTiming)
              Toggle("RGB Contrast", isOn: $model.syncContrast)
              Toggle("Cineon Log LUT", isOn: $model.syncLUT)
              Toggle("裁剪 · 范围与精细角度", isOn: $model.syncCrop)
              Text("保留每张照片的旋转与翻转").font(.caption).foregroundStyle(.secondary)
              HStack {
                Button("取消") { model.showSync = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("应用到其余 \(model.syncTargetIDs.count) 张") { model.syncCurrentSettings() }
                  .buttonStyle(.borderedProminent)
                  .disabled(!model.canSync || !model.hasSyncSelection)
              }
            }.toggleStyle(.checkbox).padding(18).frame(width: 310)
          }
          .onChange(of: model.selection.selectedFrameIDs) { _, _ in model.showSync = false }
          .onChange(of: model.selection.activeFrameID) { _, _ in model.showSync = false }
          .onChange(of: model.isCropping) { _, _ in model.showSync = false }
      }
      ScrollViewReader { proxy in
        ScrollView(.horizontal) {
          LazyHStack(spacing: 8) {
            ForEach(visibleFilmstripFrames, id: \.element.id) {
              index, frame in
              if frame.isMissing {
                thumbnail(frame, index: index).id(frame.id).contextMenu {
                  Button("重新定位此照片…") { model.relocatePanel(frame.id) }
                }
              } else {
                Button {
                  let flags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
                  // Commit a numeric field before switching photos, without a separate Filmstrip mode.
                  NSApp.keyWindow?.makeFirstResponder(nil)
                  model.select(frame.id, command: flags.contains(.command), shift: flags.contains(.shift))
                } label: {
                  thumbnail(frame, index: index).contentShape(Rectangle())
                }.buttonStyle(.plain).id(frame.id)
                  .contextMenu {
                    Button("复制调色 · 当前照片（⌘C）") { model.copyParameters() }
                    Button("粘贴调色到所选照片（⌘V）") { model.applyParameters() }
                      .disabled(!model.canApply)
                    Divider()
                    Group {
                      Button("水平翻转\(model.selection.selectedFrameIDs.count)张底片") {
                        model.changeSelectedOrientations(.flipHorizontal)
                      }
                      Button("垂直翻转\(model.selection.selectedFrameIDs.count)张底片") {
                        model.changeSelectedOrientations(.flipVertical)
                      }
                      Button("顺时针旋转\(model.selection.selectedFrameIDs.count)张底片") {
                        model.changeSelectedOrientations(.rotateClockwise)
                      }
                      Button("逆时针旋转\(model.selection.selectedFrameIDs.count)张底片") {
                        model.changeSelectedOrientations(.rotateCounterclockwise)
                      }
                    }.disabled(!model.canChangeSelectedOrientations)
                  }
              }
            }
          }.padding(.vertical, 2)
        }
          .onChange(of: model.selection.activeFrameID) { _, id in
            if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
          }
      }
    }.padding(.horizontal, 14).padding(.vertical, 10)
  }
  private var visibleFilmstripFrames: [(offset: Int, element: FrameRecord)] {
    let frames = Array((model.project?.frames ?? []).enumerated())
    guard model.isCropping && model.reviewOnlyPendingCrops else { return frames }
    return frames.filter { model.pendingAutoCropFrameIDs.contains($0.element.id) }
  }

  private func thumbnail(_ frame: FrameRecord, index: Int) -> some View {
    let active = frame.id == model.selection.activeFrameID
    let selected = model.selection.selectedFrameIDs.contains(frame.id)
    return VStack(spacing: 4) {
      ZStack {
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
          }
          Spacer()
          if frame.adjustments != FrameAdjustments() || frame.orientation != .identity || frame.crop != nil {
            HStack {
              Spacer()
              Circle().fill(accent).frame(width: 5, height: 5).padding(5)
            }
          }
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

private struct AutoCropDialogView: View {
  @ObservedObject var model: EditorModel
  @Binding var isPresented: Bool
  @State private var preserveExisting = true
  @State private var inwardPercent = 0
  @State private var started = false

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("自动裁切").font(.title3.weight(.semibold))

      Toggle("保留已裁切", isOn: $preserveExisting)
        .toggleStyle(.checkbox)
        .disabled(model.isAutoCropping)

      Picker("每边内收", selection: $inwardPercent) {
        ForEach(0...5, id: \.self) { percent in
          Text("\(percent)%").tag(percent)
        }
      }
      .pickerStyle(.menu)
      .disabled(model.isAutoCropping)

      if model.isAutoCropping {
        VStack(alignment: .leading, spacing: 8) {
          ProgressView()
          Text(model.autoCropProgressText)
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
      }

      HStack {
        if model.isAutoCropping {
          Button("取消分析") {
            started = false
            model.cancelAutoCrop()
          }
        } else {
          Button("取消") { isPresented = false }.keyboardShortcut(.cancelAction)
        }
        Spacer()
        Button("开始") {
          started = true
          model.startAutoCrop(preserveExisting: preserveExisting, inwardPercent: Double(inwardPercent))
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(model.isAutoCropping)
      }
    }
    .padding(22).frame(width: 300)
    .interactiveDismissDisabled(model.isAutoCropping)
    .onChange(of: model.autoCropCompletedRun) { _, _ in
      guard started else { return }
      started = false
      isPresented = false
      if !model.pendingAutoCropFrameIDs.isEmpty { model.reviewAutoCrops() }
    }
  }
}
