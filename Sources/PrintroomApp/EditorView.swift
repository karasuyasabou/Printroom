import AppKit
import PrintroomCore
import SwiftUI

struct EditorView: View {
  @Environment(\.openWindow) private var openWindow
  @ObservedObject var model: EditorModel
  @State private var showPreviewLoadingHint = false
  @State private var showAutoCropDialog = false
  @State private var showSprocketWhitening = false
  @State private var autoExposure = true
  @State private var preserveRollTimingEdits = false
  private let accent = InterfaceColors.accent
  var body: some View {
    Group {
      if model.isImporting { importPage } else { editorContent }
    }
    .frame(minWidth: 1060, minHeight: 720)
    .tint(accent)
    .foregroundStyle(InterfaceColors.primaryText)
    .toolbar { mainToolbar }
    .modifier(MainToolbarVisibility())
    .toolbarBackground(InterfaceColors.secondaryPanel, for: .windowToolbar)
    .toolbarBackground(.visible, for: .windowToolbar)
    .onOpenURL { model.open($0) }
    .onChange(of: model.newRollNamingID, initial: true) { _, _ in model.nameNewRollIfNeeded() }
  }
  private var importPage: some View {
    VStack(spacing: 18) {
      if let failure = model.importFailure {
        Text("加载未完成").font(.title2)
        ScrollView { Text(failure).font(.callout).textSelection(.enabled) }
          .frame(maxWidth: 560, maxHeight: 180)
        HStack {
          Button("返回主页") { model.cancelImport() }
          Button("重试") { model.retryImport() }.buttonStyle(.borderedProminent)
        }
      } else {
        Text("正在加载…").font(.title2)
        ProgressView(value: Double(model.importCompleted), total: Double(max(1, model.importTotal)))
          .frame(width: 280)
        Text("\(model.importCompleted) / \(model.importTotal)").monospacedDigit().foregroundStyle(InterfaceColors.secondaryText)
        Button("取消加载") { model.cancelImport() }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(InterfaceColors.window)
  }
  private var editorContent: some View {
    VStack(spacing: 0) {
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
              PreviewCanvas(model: model)
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
              if model.hasFilmBase && model.activeFrame != nil && !model.isCropping {
                HistogramView(model: model)
                  .padding(12)
              }
            }
            .overlay(alignment: .bottomLeading) {
              if showPreviewLoadingHint {
                Text("正在加载预览…")
                  .font(.caption2).foregroundStyle(.white.opacity(0.8))
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
      filmstrip
    }
    .frame(minWidth: 1060, minHeight: 720)
    .background(InterfaceColors.window)
    .background(EditorKeyboardShortcuts(model: model))
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
    .nativeDialog(isPresented: model.showMissingFilmBaseDialog,
      title: "请先框选片基", primaryTitle: "框选片基",
      primaryEnabled: model.hasImage, compactCenteredTitle: true,
      primary: { model.beginFilmBaseSelection(continueToRollTiming: true) },
      cancel: { model.showMissingFilmBaseDialog = false }) { EmptyView() }
    .nativeDialog(isPresented: model.showRollTimingConfirmation || model.showRollTimingDialog,
      title: model.showRollTimingConfirmation ? "色罩分析" : (model.isAnalyzingRollTiming ? "色罩分析" : (model.rollTimingError == nil ? "分析成功" : "分析未完成")),
      message: model.showRollTimingConfirmation ? "将开始整卷色罩分析，请确认已完成有效画幅裁剪和片基框选" : (model.rollTimingError ?? ""),
      primaryTitle: model.showRollTimingConfirmation ? "开始分析" : (!model.isAnalyzingRollTiming && model.rollTimingError == nil ? "应用到整卷" : nil),
      cancelTitle: model.isAnalyzingRollTiming ? "取消分析" : "取消",
      primary: {
        if model.showRollTimingConfirmation {
          model.showRollTimingConfirmation = false
          model.startRollTiming(autoExposure: autoExposure)
        } else { model.applyRollTiming(preserveEdited: preserveRollTimingEdits) }
      }, cancel: {
        model.showRollTimingConfirmation = false
        model.cancelRollTiming()
      }) {
        if model.showRollTimingConfirmation {
          Toggle("自动曝光", isOn: $autoExposure).toggleStyle(.checkbox)
        } else if model.isAnalyzingRollTiming {
          HStack { ProgressView().controlSize(.small); Text(model.rollTimingProgress); Spacer() }
        } else if model.rollTimingError == nil {
          Toggle("保留已调色", isOn: $preserveRollTimingEdits).toggleStyle(.checkbox)
        }
      }
    .onChange(of: model.showRollTimingConfirmation) { _, presented in
      if presented {
        autoExposure = true
        preserveRollTimingEdits = false
      }
    }
    .background(AutoCropDialogView(model: model, isPresented: $showAutoCropDialog))
    .sheet(item: $model.matrixManager) { kind in MatrixManagerView(model: model, kind: kind) }
    .task(id: previewIsWaiting) {
      showPreviewLoadingHint = false
      guard previewIsWaiting else { return }
      do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
      guard !Task.isCancelled, previewIsWaiting else { return }
      showPreviewLoadingHint = true
    }
  }
  private var previewIsWaiting: Bool {
    model.project != nil && (model.previewImage == nil || model.isPreviewPlaceholder)
      && (model.isLoading || model.isRendering)
  }
  @ToolbarContentBuilder private var mainToolbar: some ToolbarContent {
    if #available(macOS 26.0, *) {
      ToolbarItem(id: "printroom-branding", placement: .navigation) { toolbarBranding }
        .sharedBackgroundVisibility(.hidden)
      ToolbarSpacer(.flexible, placement: .primaryAction)
      ToolbarItem(id: "printroom-actions", placement: .primaryAction) { toolbarActions }
        .sharedBackgroundVisibility(.hidden)
    } else {
      ToolbarItem(id: "printroom-branding", placement: .navigation) { toolbarBranding }
      ToolbarItem(placement: .principal) { Spacer(minLength: 0) }
      ToolbarItem(id: "printroom-actions", placement: .primaryAction) { toolbarActions }
    }
  }
  private var toolbarBranding: some View {
    HStack(spacing: 10) {
      Image(systemName: "square.stack.3d.down.right").font(.title2).foregroundStyle(accent)
      Text("PRINTROOM").font(.system(size: 15, weight: .semibold, design: .monospaced))
        .tracking(3)
      AppearanceToggle()
    }.fixedSize()
  }
  private var filmstripRollTitle: some View {
    HStack(spacing: 8) {
      if model.project != nil {
        Text(model.rollName)
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(InterfaceColors.primaryText)
          .lineLimit(1).truncationMode(.middle)
          .help(model.rollName)
        Button { model.renameRollPanel() } label: {
          Image(systemName: "pencil").font(.system(size: 12, weight: .medium))
        }.buttonStyle(.plain).help("命名胶卷").accessibilityLabel("命名胶卷")
        Button { model.openRollFolderInFinder() } label: {
          Image(systemName: "folder").font(.system(size: 12, weight: .medium))
        }.buttonStyle(.plain).help("在 Finder 中打开底片文件夹")
          .accessibilityLabel("在 Finder 中打开底片文件夹")
          .disabled(model.folder == nil)
      }
    }.frame(maxWidth: 320, alignment: .leading)
      .fixedSize(horizontal: true, vertical: false)
  }
  private var toolbarActions: some View {
    HStack(spacing: 10) {
      Button {
        NSApp.keyWindow?.makeFirstResponder(nil)
        model.returnHome()
      } label: {
        Label("回到主页", systemImage: "house")
      }.disabled(model.project == nil || model.isExporting)
      Divider().frame(height: 20)
      Button {
        model.stopTimingKey()
        model.endAdjustment()
        showSprocketWhitening = true
      } label: {
        Label("齿孔置白", systemImage: "film")
      }
      .disabled(model.project == nil || model.isLoading || model.isExporting || model.isCropping || model.isAutoCropping)
      .help("设置整卷齿孔置白")
      .popover(isPresented: $showSprocketWhitening, arrowEdge: .bottom) {
        SprocketWhiteningControlsView(model: model)
      }
      Button { showAutoCropDialog = true } label: {
        Label("自动裁剪", systemImage: "crop")
      }.disabled(!model.canStartAutoCrop)
        .help("设置并分析整卷自动裁剪")
      Button {
        model.stopTimingKey()
        model.endAdjustment()
        if !model.hasFilmBase {
          model.showMissingFilmBaseDialog = true
          return
        }
        model.requestRollTimingConfirmation()
      } label: {
        Label("色罩分析", systemImage: "wand.and.stars")
      }
        .disabled(model.hasFilmBase ? !model.canStartRollTiming : !model.canOpenRollTiming)
        .help("色罩分析")
        .accessibilityLabel("色罩分析")
      Button {
        model.resetAdjustments()
      } label: {
        Label("重置调色", systemImage: "arrow.counterclockwise")
      }.disabled(!model.canAdjustColors)
        .help("重置当前照片的 Timing、Contrast 与 Cineon Log LUT · 可撤销")
      Menu {
        Button("导出选中 \(model.selection.selectedFrameIDs.count) 张…") { model.batchExportPanel(allFrames: false) }
          .disabled(model.selection.selectedFrameIDs.isEmpty)
        Button("导出整卷…") { model.batchExportPanel(allFrames: true) }
      } label: {
        Label("导出", systemImage: "square.and.arrow.up")
      }.menuStyle(.borderlessButton).fixedSize()
        .foregroundStyle(InterfaceColors.primaryText)
        .disabled(model.project == nil || model.isExporting || model.isCropping)

    }
    .labelStyle(.titleAndIcon)
    .fixedSize()
    .buttonStyle(MainToolbarButtonStyle())
    .tint(InterfaceColors.primaryText)
    .disabled(model.isImporting)

  }
  private var previewToolbar: some View {
    HStack {
      Text(model.activeFrame?.filename ?? "预览").font(
        .system(size: 12, weight: .medium, design: .monospaced)
      ).lineLimit(1).truncationMode(.middle).layoutPriority(-1)
        .help(model.sourceWidth > 0
          ? "\(model.activeFrame?.filename ?? "预览") · \(model.displayWidth) × \(model.displayHeight)"
          : model.activeFrame?.filename ?? "预览")
      Spacer()
      HStack(spacing: 4) {
        Button { model.beginCrop() } label: {
          PreviewToolLabel(selected: model.isCropping) {
            Label("裁剪", systemImage: "crop")
          }
        }.buttonStyle(.plain).fixedSize()
          .disabled(!model.hasImage || model.isCropping || model.isAutoCropping)
          .help("裁剪与精细角度 · R")
        HStack(spacing: 0) {
          orientationButton("向左旋转 90°", symbol: "rotate.left", operation: .rotateCounterclockwise)
          orientationButton("向右旋转 90°", symbol: "rotate.right", operation: .rotateClockwise)
          orientationButton("水平翻转", symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", operation: .flipHorizontal)
          orientationButton("垂直翻转", symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", rotation: 90, operation: .flipVertical)
        }.disabled(!model.hasImage || model.isCropping)
      }
      previewToolDivider
      Toggle("裁剪预览", isOn: $model.cropPreviewEnabled)
        .toggleStyle(.checkbox)
        .font(.system(size: 12, weight: .medium))
        .fixedSize()
        .help("仅切换主画面的裁剪效果，直方图仍统计裁剪后的画面")
      PreviewToolMenu(title: "管线预览", value: pipelinePreviewTitle) {
        if model.hasFilmBase {
          ForEach([PipelineStage.l2, .d3, .final], id: \.self) { stage in
            Toggle(pipelinePreviewTitle(for: stage), isOn: Binding(
              get: { model.stage == stage },
              set: { selected in if selected { model.stage = stage } }
            ))
          }
        }
      }.disabled(!model.hasFilmBase).help("管线预览：\(pipelinePreviewTitle)")
    }.padding(.horizontal, 12).frame(height: 38)
      .background(InterfaceColors.panel)
      .tint(InterfaceColors.primaryText)
  }
  private func orientationButton(_ title: String, symbol: String, rotation: Double = 0,
                                 operation: OrientationOperation) -> some View {
    Button { model.changeOrientation(operation) } label: {
      PreviewToolLabel {
        Image(systemName: symbol)
          .rotationEffect(.degrees(rotation))
          .frame(width: 16)
      }
    }
    .buttonStyle(.plain)
    .fixedSize()
    .help(title)
    .accessibilityLabel(title)
  }
  private var previewToolDivider: some View {
    Rectangle().fill(InterfaceColors.separator).frame(width: 1, height: 14)
      .padding(.horizontal, 4)
  }
  private var pipelinePreviewTitle: String { model.hasFilmBase ? pipelinePreviewTitle(for: model.stage) : "原图" }
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
        Button("打开底片") { model.openPanel() }.buttonStyle(.borderedProminent)
        Button { openWindow(id: "cache-manager") } label: {
          Label("管理缓存", systemImage: "internaldrive")
        }.buttonStyle(.bordered)
      }
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
    HStack(spacing: 10) {
      Text(kind.label).font(.caption).foregroundStyle(InterfaceColors.secondaryText)
        .frame(width: 64, alignment: .leading)
      MatrixMenuControl(
        options: model.matrixOptions(kind),
        titles: model.matrixOptions(kind).map {
          $0.label + (model.isMatrixSnapshot($0, kind: kind) ? " · 本卷快照" : "")
        },
        selection: kind == .cmos ? model.cmosMatrix : model.matrix,
        label: kind.label, enabled: model.project != nil,
        onSelect: { model.setMatrixPreset($0, kind: kind) })
        .frame(maxWidth: .infinity).frame(height: 22)
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  private var inspector: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        VStack(alignment: .leading, spacing: 16) {
          HStack {
            heading("01", "矩阵矫正 · 整卷", bottomPadding: 0)
            Button("管理…") {
              model.stopTimingKey()
              model.showMatrixMenu = true
            }
            .buttonStyle(.borderless)
            .controlSize(.small).font(.system(size: 11))
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
          VStack(spacing: 14) {
            matrixPicker(.cmos)
            matrixPicker(.density)
          }
        }
        Divider().overlay(InterfaceColors.subtleSeparator).opacity(0.45)
        VStack(alignment: .leading, spacing: 10) {
          HStack(spacing: 6) {
            heading("02", "FILM BASE 对齐 · 整卷", bottomPadding: 0)
              .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
            Button {
              model.sampling.toggle()
            } label: {
              Label(model.sampling ? "取消框选" : "框选片基", systemImage: "viewfinder")
            }.controlSize(.small).font(.system(size: 11))
              .fixedSize().disabled(!model.hasImage || model.isCropping)
          }
        }.padding(.vertical, 6)
        Divider().overlay(InterfaceColors.subtleSeparator).opacity(0.45)
        VStack(alignment: .leading, spacing: 10) {
          HStack(spacing: 8) {
            Text("03").font(.system(size: 10, design: .monospaced)).foregroundStyle(InterfaceColors.secondaryText)
            Text("Color Timing").font(.system(size: 11, weight: .medium))
            Spacer(minLength: 0)
            Picker("Timing 模式", selection: $model.timingMode) {
              Text("简易").tag(TimingMode.simple)
              Text("RGB").tag(TimingMode.rgb)
            }.pickerStyle(.segmented).labelsHidden()
              .controlSize(.small).font(.system(size: 11)).frame(width: 100)
              .help("切换 Timing 控件与快捷键，保持照片参数")
            Button {
              model.toggleNeutralPicker()
            } label: {
              Image(systemName: "eyedropper")
                .foregroundStyle(model.neutralPicking ? accent : InterfaceColors.secondaryText)
                .opacity(model.isNeutralSampling ? 0.4 : 1)
                .frame(width: 24, height: 20)
            }.buttonStyle(.plain)
              .disabled(!model.canPickNeutral || model.isNeutralSampling)
              .help(model.neutralPicking ? "点击照片，使 Final 取样位置中性并保持亮度 · I / Esc 取消" : "Final 中性点吸管 (I) · 保持亮度")
              .accessibilityLabel(model.neutralPicking ? "取消 Final 中性点吸管" : "标定 Final 中性点，保持亮度")
          }
          VStack(spacing: 9) {
            if model.timingMode == .simple {
              simpleTimingRow(.exposure, color: InterfaceColors.primaryText)
              simpleTimingRow(.temperature, color: InterfaceColors.temperature)
              simpleTimingRow(.tint, color: InterfaceColors.tint)
              Color.clear.frame(height: 24)
            } else {
              timingRow("Master", \.master, color: InterfaceColors.primaryText)
              timingRow("Red", \.red, color: ChannelColors.red)
              timingRow("Green", \.green, color: ChannelColors.green)
              timingRow("Blue", \.blue, color: ChannelColors.blue)
            }
          }
        }.disabled(!model.canAdjustColors)
        Divider().overlay(InterfaceColors.subtleSeparator).opacity(0.45)
        VStack(alignment: .leading, spacing: 9) {
          heading("04", "RGB Contrast")
          contrastRow("Master", \.master, color: InterfaceColors.primaryText)
          contrastRow("Red", \.red, color: ChannelColors.red)
          contrastRow("Green", \.green, color: ChannelColors.green)
          contrastRow("Blue", \.blue, color: ChannelColors.blue)
        }.disabled(!model.canAdjustColors)
        Divider().overlay(InterfaceColors.subtleSeparator).opacity(0.45)
        HStack(spacing: 6) {
          heading("05", "Cineon Log LUT", bottomPadding: 0)
            .fixedSize(horizontal: true, vertical: false)
          Picker("Cineon Log LUT", selection: Binding(
            get: { model.adjustments.cineonLogLUT },
            set: { value in model.edit { $0.cineonLogLUT = value } })) {
              ForEach(CineonLogLUT.allCases, id: \.self) { lut in Text(lut.label).tag(lut) }
            }.labelsHidden().controlSize(.small).font(.system(size: 11))
        }.disabled(!model.canAdjustColors)
      }.padding(16).background(OverlayScrollbars())
    }.background(InterfaceColors.panel)
  }
  private func simpleTimingRow(_ axis: SimpleTimingAxis, color: Color) -> some View {
    AdjustmentRow(title: axis.help,
        value: Binding(get: { axis.value(in: model.adjustments.timing) },
          set: { model.setSimpleTiming(axis, value: $0) }),
        range: axis.range, step: 1, fractionDigits: 0, color: color,
        onEditingChanged: { if $0 { model.beginAdjustment() } else { model.endAdjustment() } },
        resetValue: 0, quantizesValue: false, label: axis.title)
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
      onEditingChanged: { if $0 { model.beginAdjustment() } else { model.endAdjustment() } },
      resetValue: 0, label: title)
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
      onEditingChanged: { if $0 { model.beginAdjustment() } else { model.endAdjustment() } },
      resetValue: 1, label: title)
  }
  private var filmstrip: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        if model.project != nil { filmstripRollTitle }
        Text(
          "\(model.project?.frames.count ?? 0) 张 · 已选 \(model.selection.selectedFrameIDs.count) 张"
        ).font(.caption2).foregroundStyle(InterfaceColors.secondaryText).fixedSize()
        Spacer()
        if let snapshot = model.snapshot, !model.isAutoCropping {
          Text("已复制：\(snapshot.sourceName)").font(.caption2).foregroundStyle(accent)
        }
        Button("同步…") { model.beginSync() }
          .disabled(!model.canSync)
          .help(model.isCropping ? "先完成当前照片裁剪，再同步" : "把当前照片的设置同步到其余所选照片")
          .popover(isPresented: $model.showSync, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 14) {
              Text("同步").font(.headline)
              Text("来源：\(model.activeFrame?.filename ?? "")").lineLimit(2)
              Divider()
              Toggle("Color Timing", isOn: $model.syncTiming).disabled(!model.hasFilmBase)
              Toggle("RGB Contrast", isOn: $model.syncContrast).disabled(!model.hasFilmBase)
              Toggle("Cineon Log LUT", isOn: $model.syncLUT).disabled(!model.hasFilmBase)
              Toggle("裁剪", isOn: $model.syncCrop)
              HStack {
                Button("取消") { model.showSync = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("应用到 \(model.syncTargetIDs.count) 张") { model.syncCurrentSettings() }
                  .buttonStyle(.borderedProminent)
                  .disabled(!model.canSync || !model.hasSyncSelection)
              }
            }.toggleStyle(.checkbox).padding(18).frame(width: 310)
          }
          .onChange(of: model.selection.selectedFrameIDs) { _, _ in model.showSync = false }
          .onChange(of: model.selection.activeFrameID) { _, _ in model.showSync = false }
          .onChange(of: model.isCropping) { _, _ in model.showSync = false }
          .onChange(of: model.hasFilmBase) { _, _ in model.showSync = false }
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
                }.buttonStyle(FilmstripButtonStyle()).id(frame.id)
                  .contextMenu {
                    Button("复制调色（⌘C）") { model.copyParameters() }.disabled(!model.canAdjustColors)
                    Button("粘贴调色（⌘V）") { model.applyParameters() }
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
          }.padding(.vertical, 2).background(OverlayScrollbars())
        }
          .frame(height: 112)
          .onChange(of: model.selection.activeFrameID) { _, id in
            if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
          }
      }
    }.padding(.horizontal, 14).padding(.vertical, 10)
      .background(InterfaceColors.secondaryPanel)
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
            InterfaceColors.tertiaryText)
        }
        VStack {
          HStack {
            Text(String(format: "%02d", index + 1)).font(.system(size: 9, design: .monospaced))
              .foregroundStyle(.white).padding(3).background(.black.opacity(0.65))
            Spacer()
          }
          Spacer()
        }
      }.frame(width: 124, height: 78).clipped()
      Text(frame.filename).font(.system(size: 9, design: .monospaced)).lineLimit(1).frame(
        width: 124)
    }.padding(4).background(selected ? InterfaceColors.selected : Color.clear).overlay(
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
  @State private var preserveExisting = false
  @State private var inwardPercent = 1
  @State private var started = false
  @State private var ratioChoice = "3:2"
  @State private var customWidth = "3"
  @State private var customHeight = "2"
  @State private var portrait = false
  private let ratios = ["3:2", "4:3", "1:1", "5:4", "7:6", "2:1", "3:1", "自定义"]
  private var selectedRatio: Double? {
    let parts = ratioChoice == "自定义" ? [customWidth, customHeight] : ratioChoice.components(separatedBy: ":")
    guard let w = Double(parts[0]), let h = Double(parts[1]),
      w.isFinite, h.isFinite, w > 0, h > 0 else { return nil }
    let ratio = portrait ? h / w : w / h
    return ratio.isFinite && (0.1...10).contains(ratio) ? ratio : nil
  }
  private var invalidRatio: Bool { selectedRatio == nil }

  var body: some View {
    Color.clear.frame(width: 0, height: 0)
      .nativeDialog(isPresented: isPresented, title: "自动裁剪",
        primaryTitle: model.isAutoCropping ? nil : "开始", primaryEnabled: !invalidRatio,
        cancelTitle: model.isAutoCropping ? "取消分析" : "取消",
        primary: {
          guard let selectedRatio else { return }
          started = true
          model.startAutoCrop(preserveExisting: preserveExisting, inwardPercent: Double(inwardPercent), aspectRatio: selectedRatio)
        }, cancel: {
          if model.isAutoCropping { started = false; model.cancelAutoCrop() }
          else { isPresented = false }
        }) {
        VStack(alignment: .leading, spacing: 18) {
          VStack(alignment: .leading, spacing: 10) {
            Picker("画幅比例", selection: $ratioChoice) {
              ForEach(ratios, id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.menu)
            if ratioChoice == "自定义" {
              HStack {
                TextField("宽", text: $customWidth).accessibilityLabel("自定义比例宽")
                Text(":")
                TextField("高", text: $customHeight).accessibilityLabel("自定义比例高")
              }.textFieldStyle(.roundedBorder)
            }
            Toggle("交换宽高", isOn: $portrait).toggleStyle(.checkbox)
            if invalidRatio {
              Text("请输入有效正数，比例范围为 1:10～10:1。")
                .font(.caption).foregroundStyle(.red)
            }
          }.disabled(model.isAutoCropping)

          Toggle("保留已裁剪", isOn: $preserveExisting)
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
                .font(.caption).foregroundStyle(InterfaceColors.secondaryText).lineLimit(1)
            }
          }

        }
      }
    .onChange(of: isPresented) { _, shown in
      if shown {
        preserveExisting = false; inwardPercent = 1; started = false
        ratioChoice = "3:2"; customWidth = "3"; customHeight = "2"; portrait = false
      }
    }
    .onChange(of: model.autoCropCompletedRun) { _, _ in
      guard started else { return }
      started = false
      isPresented = false
      if !model.pendingAutoCropFrameIDs.isEmpty { model.reviewAutoCrops() }
    }
  }
}

/// Native popup sizing follows the shared layout column rather than its selected title.
private struct MatrixMenuControl: NSViewRepresentable {
  let options: [MatrixPreset]
  let titles: [String]
  let selection: MatrixPreset
  let label: String
  let enabled: Bool
  let onSelect: (MatrixPreset) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> NSPopUpButton {
    let button = NSPopUpButton(frame: .zero, pullsDown: false)
    button.controlSize = .small
    button.font = .systemFont(ofSize: 11)
    button.setContentHuggingPriority(.defaultLow, for: .horizontal)
    button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    button.target = context.coordinator
    button.action = #selector(Coordinator.select(_:))
    return button
  }
  func updateNSView(_ button: NSPopUpButton, context: Context) {
    context.coordinator.parent = self
    if button.itemTitles != titles {
      button.removeAllItems()
      for (index, title) in titles.enumerated() {
        button.menu?.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
        button.item(at: index)?.tag = index
      }
    }
    button.selectItem(at: options.firstIndex(of: selection) ?? -1)
    button.isEnabled = enabled
    button.setAccessibilityLabel(label)
  }
  final class Coordinator: NSObject {
    var parent: MatrixMenuControl
    init(_ parent: MatrixMenuControl) { self.parent = parent }
    @objc func select(_ sender: NSPopUpButton) {
      let index = sender.indexOfSelectedItem
      guard parent.options.indices.contains(index) else { return }
      parent.onSelect(parent.options[index])
    }
  }
}

struct SprocketWhiteningControlsView: View {
  @ObservedObject var model: EditorModel
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Toggle("齿孔置白", isOn: Binding(get: { model.sprocketWhitening.enabled }, set: { enabled in
        var settings = model.sprocketWhitening
        settings.enabled = enabled
        model.setSprocketWhitening(settings)
      }))
      .disabled(!model.canAdjustSprocketWhitening && !model.sprocketWhitening.enabled)
      HStack {
        Text("识别阈值")
        Spacer()
        Text("片基 +\(Int(model.sprocketWhitening.thresholdPercent))%")
          .monospacedDigit().foregroundStyle(InterfaceColors.secondaryText)
      }
      Slider(value: Binding(get: { model.sprocketWhitening.thresholdPercent }, set: { threshold in
        var settings = model.sprocketWhitening
        settings.thresholdPercent = threshold.rounded()
        model.setSprocketWhitening(settings)
      }), in: 5...200, onEditingChanged: { editing in
        if editing { model.beginAdjustment() } else { model.endAdjustment() }
      })
      .disabled(!model.sprocketWhitening.enabled || !model.canAdjustSprocketWhitening)
      .accessibilityLabel("齿孔识别阈值")
      if !model.canAdjustSprocketWhitening {
        Text("请先完成片基校准，并为照片设置裁剪。")
          .font(.caption).foregroundStyle(InterfaceColors.secondaryText)
      }
    }
    .padding(18).frame(width: 290)
    .onDisappear { model.endAdjustment() }
  }
}
