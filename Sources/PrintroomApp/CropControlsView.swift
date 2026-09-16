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
    if draft.portrait && draft.aspect != .square {
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
      }.disabled(model.displayedCropDraft?.aspect == .square)
        .help("交换裁剪比例的横竖方向").accessibilityLabel("交换裁剪横竖方向")
      Button { nudgeAngle(-0.1) } label: { Image(systemName: "minus") }
        .accessibilityLabel("角度减 0.1 度")
      Slider(value: Binding(get: { angle }, set: { setAngle($0) }), in: -10...10)
        .frame(minWidth: 76, idealWidth: 118, maxWidth: 140)
        .accessibilityLabel("裁剪角度")
        .help("−10° 至 +10° · 双击归零")
        .simultaneousGesture(TapGesture(count: 2).onEnded { setAngle(0) })
      Button { nudgeAngle(0.1) } label: { Image(systemName: "plus") }
        .accessibilityLabel("角度加 0.1 度")
      TextField("角度", text: $angleText)
        .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
        .font(.system(size: 11, design: .monospaced)).frame(width: 57)
        .focused($angleFocused).onSubmit { commitAngle(); angleFocused = false }
        .accessibilityLabel("裁剪角度数值，精确到 0.01 度")
      Text("°").font(.caption).foregroundStyle(.secondary)
      Button {
        angleFocused = false
        model.resetCropDraft()
        refreshAngleText()
      } label: {
        Image(systemName: "arrow.counterclockwise")
      }.help("重置裁剪：恢复完整照片与 0° 角度").accessibilityLabel("重置裁剪")
      Spacer(minLength: 4)
      Button("取消") { model.cancelCrop() }.fixedSize().help("取消本次裁剪 · Esc")
      Button("完成") {
        if angleFocused { commitAngle() }
        model.commitCrop()
      }
      .fixedSize().buttonStyle(.borderedProminent).help("保存当前照片裁剪 · Enter")
    }
    .disabled(model.isLoading || model.sourceWidth == 0 || model.sourceHeight == 0)
    .controlSize(.small)
    .padding(.horizontal, 12).frame(height: 38)
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    .onAppear { refreshAngleText() }
    .onChange(of: angle) { _, _ in if !angleFocused { refreshAngleText() } }
    .onChange(of: angleFocused) { old, new in if old && !new { commitAngle() } }
  }

  private func currentDraft() -> FrameCrop {
    model.displayedCropDraft
      ?? FrameCrop(portrait: model.displayHeight > model.displayWidth, geometryVersion: 1)
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
    setAngle(angle + delta)
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
