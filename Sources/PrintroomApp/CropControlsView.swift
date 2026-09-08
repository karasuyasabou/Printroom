import AppKit
import PrintroomCore
import SwiftUI

struct CropControlsView: View {
  @ObservedObject var model: EditorModel
  @State private var angleText = "0.00"
  @FocusState private var angleFocused: Bool

  private var angle: Double { model.cropDraft?.angleDegrees ?? 0 }
  private var ratioLabel: String {
    guard let draft = model.cropDraft else { return "全图" }
    if draft.portrait && draft.aspect != .square {
      return draft.aspect.label.split(separator: ":").reversed().joined(separator: ":")
    }
    return draft.aspect.label
  }

  var body: some View {
    VStack(spacing: 9) {
      HStack(spacing: 12) {
        Menu {
          ForEach(CropAspectRatio.allCases, id: \.self) { aspect in
            Button(aspect.label) {
              var draft = currentDraft()
              draft.aspect = aspect
              model.updateCropDraft(draft)
            }
          }
        } label: {
          Text("比例 · \(ratioLabel)").monospacedDigit().frame(minWidth: 82, alignment: .leading)
        }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("裁剪比例")
        Button {
          var draft = currentDraft()
          draft.portrait.toggle()
          model.updateCropDraft(draft)
        } label: {
          Label("横竖", systemImage: "arrow.triangle.2.circlepath")
        }.disabled(model.cropDraft?.aspect == .square).help("交换裁剪比例的横竖方向")
        Text("拖动边角裁剪，框内移动").font(.caption2).foregroundStyle(.secondary)
        Spacer(minLength: 0)
        if let geometry = model.cropDraftGeometry {
          Text("\(geometry.outputWidth) × \(geometry.outputHeight)")
            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            .accessibilityLabel("裁后 \(geometry.outputWidth) 乘 \(geometry.outputHeight) 像素")
        }
        Button("重置裁剪") {
          angleFocused = false
          model.resetCropDraft()
          refreshAngleText()
        }.help("恢复完整照片与 0° 角度")
      }
      HStack(spacing: 8) {
        Text("角度").font(.caption)
        Button { nudgeAngle(-0.1) } label: { Image(systemName: "minus") }
          .accessibilityLabel("角度减 0.1 度")
        Slider(value: Binding(get: { angle }, set: { setAngle($0) }), in: -10...10)
          .frame(minWidth: 80, maxWidth: 170)
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
        Spacer(minLength: 4)
        Button("取消") { model.cancelCrop() }.help("取消本次裁剪 · Esc")
        Button("同步到所选 \(model.selection.selectedFrameIDs.count) 张") {
          if angleFocused { commitAngle() }
          model.commitCrop(syncSelection: true)
        }.disabled(!model.canSyncCrop).help("保存裁剪并覆盖所选照片的裁剪；一次撤销恢复整组")
        Button("完成") {
          if angleFocused { commitAngle() }
          model.commitCrop()
        }.buttonStyle(.borderedProminent).help("保存当前照片裁剪 · Enter")
      }
    }
    .controlSize(.small)
    .padding(.horizontal, 12).padding(.vertical, 10)
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    .onAppear { refreshAngleText() }
    .onChange(of: angle) { _, _ in if !angleFocused { refreshAngleText() } }
    .onChange(of: angleFocused) { old, new in if old && !new { commitAngle() } }
  }

  private func currentDraft() -> FrameCrop {
    model.cropDraft ?? FrameCrop(portrait: model.displayHeight > model.displayWidth)
  }
  private func setAngle(_ value: Double) {
    guard value.isFinite else { return }
    var draft = currentDraft()
    draft.angleDegrees = (min(10, max(-10, value)) * 100).rounded() / 100
    model.updateCropDraft(draft)
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
