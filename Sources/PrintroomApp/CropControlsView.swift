import AppKit
import PrintroomCore
import SwiftUI

struct CropControlsView: View {
  @ObservedObject var model: EditorModel
  @State private var angleText = "0.00"
  @FocusState private var angleFocused: Bool

  private var angle: Double { model.displayedCropDraft?.angleDegrees ?? 0 }
  private var ratioLabel: String {
    guard let draft = model.displayedCropDraft else { return "全图" }
    if draft.portrait && draft.aspect != .square && draft.aspect != .free {
      return draft.aspect.label.split(separator: ":").reversed().joined(separator: ":")
    }
    return draft.aspect.label
  }

  var body: some View {
    HStack(spacing: 8) {
      Menu {
        ForEach(CropAspectRatio.allCases, id: \.self) { aspect in
          Button(aspect.label) {
            var draft = currentDraft()
            if aspect == .free {
              // Changing to free keeps the visible rectangle, including full-image reset.
              let ratio = model.displayedCropDraft?.ratio
                ?? Double(max(1, model.displayWidth)) / Double(max(1, model.displayHeight))
              draft.freeRatio = ratio
              draft.portrait = false
            } else {
              if draft.aspect == .free { draft.portrait = draft.ratio < 1 }
              draft.freeRatio = nil
            }
            draft.aspect = aspect
            model.updateDisplayedCropDraft(draft)
          }
        }
      } label: {
        Text(ratioLabel).monospacedDigit().frame(minWidth: 28, alignment: .leading)
      }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("裁剪比例")
      Button {
        var draft = currentDraft()
        draft.portrait.toggle()
        model.updateDisplayedCropDraft(draft)
      } label: {
        Image(systemName: "arrow.triangle.2.circlepath")
      }.disabled(model.displayedCropDraft?.aspect == .square || model.displayedCropDraft?.aspect == .free)
        .help("交换裁剪比例的横竖方向").accessibilityLabel("交换裁剪横竖方向")
      Button { nudgeAngle(-0.1) } label: { Image(systemName: "minus") }
        .help("角度减 0.1° · Q")
        .accessibilityLabel("角度减 0.1 度")
      Slider(value: Binding(get: { angle }, set: { setAngle($0) }), in: -10...10)
        .frame(minWidth: 76, idealWidth: 118, maxWidth: 140)
        .accessibilityLabel("裁剪角度")
        .help("−10° 至 +10° · 双击归零")
        .simultaneousGesture(TapGesture(count: 2).onEnded { setAngle(0) })
      Button { nudgeAngle(0.1) } label: { Image(systemName: "plus") }
        .help("角度加 0.1° · E")
        .accessibilityLabel("角度加 0.1 度")
      TextField("角度", text: $angleText)
        .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
        .font(.system(size: 11, design: .monospaced)).frame(width: 57)
        .focused($angleFocused).onSubmit { commitAngle(); angleFocused = false }
        .accessibilityLabel("裁剪角度数值，精确到 0.01 度")
      Text("°").font(.caption).foregroundStyle(InterfaceColors.secondaryText)
      Button {
        angleFocused = false
        model.resetCropDraft()
        refreshAngleText()
      } label: {
        Image(systemName: "arrow.counterclockwise")
      }.help("重置裁剪：恢复完整照片与 0° 角度").accessibilityLabel("重置裁剪")
      Spacer(minLength: 4)
      if model.cropReviewAvailable && !model.pendingAutoCropFrameIDs.isEmpty {
        Text("待检查 \(model.pendingAutoCropFrameIDs.count) 张")
          .font(.caption).foregroundStyle(InterfaceColors.secondaryText).fixedSize()
        Toggle("仅看待检查", isOn: $model.reviewOnlyPendingCrops)
          .toggleStyle(.checkbox).fixedSize()
          .help("缩略图和左右方向键只显示待检查照片")
      }
      Button("取消") { model.cancelCrop() }.fixedSize().help("取消本次裁剪 · Esc")
      Button(model.cropReviewAvailable && !model.pendingAutoCropFrameIDs.isEmpty ? "确认并下一张" : "完成") {
        if angleFocused { commitAngle() }
        model.performCropPrimaryAction()
      }
      .fixedSize().buttonStyle(.borderedProminent)
      .help(model.cropReviewAvailable && !model.pendingAutoCropFrameIDs.isEmpty
        ? "保存当前裁剪、清除待检查标记并前往下一张 · Enter"
        : "保存当前照片裁剪 · Enter")
    }
    .disabled(model.isLoading || model.sourceWidth == 0 || model.sourceHeight == 0)
    .controlSize(.small)
    .padding(.horizontal, 12).frame(height: 38)
    .background(InterfaceColors.panel)
    .onAppear { refreshAngleText() }
    .onChange(of: angle) { _, _ in if !angleFocused { refreshAngleText() } }
    .onChange(of: angleFocused) { old, new in if old && !new { commitAngle() } }
  }

  private func currentDraft() -> FrameCrop {
    model.displayedCropDraft
      ?? FrameCrop(aspect: .free, geometryVersion: 1,
        freeRatio: Double(max(1, model.displayWidth)) / Double(max(1, model.displayHeight)))
  }
  private func setAngle(_ value: Double) {
    guard value.isFinite else { return }
    var draft = currentDraft()
    draft.angleDegrees = (min(10, max(-10, value)) * 100).rounded() / 100
    model.updateDisplayedCropDraft(draft)
    refreshAngleText()
  }
  private func nudgeAngle(_ delta: Double) {
    if angleFocused { commitAngle() }
    angleFocused = false
    model.nudgeCropAngle(delta)
    refreshAngleText()
  }
  private func commitAngle() {
    guard model.isCropping else { return }
    let normalized = angleText.replacingOccurrences(of: "，", with: ".")
      .replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespacesAndNewlines)
    if let value = Double(normalized), value.isFinite, abs(value - angle) > 0.00001 { setAngle(value) }
    refreshAngleText()
  }
  private func refreshAngleText() { angleText = String(format: "%.2f", angle) }
}
