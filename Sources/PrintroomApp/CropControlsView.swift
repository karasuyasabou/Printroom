import AppKit
import PrintroomCore
import SwiftUI

struct CropControlsView: View {
  @ObservedObject var model: EditorModel
  @State private var showingCustomRatio = false
  @State private var customWidth = "3"
  @State private var customHeight = "2"

  private var angle: Double { model.displayedCropDraft?.angleDegrees ?? 0 }
  private var originalRatio: Double { Double(max(1, model.displayWidth)) / Double(max(1, model.displayHeight)) }
  private var ratioLabel: String {
    let draft = model.currentDisplayedCrop
    if abs(draft.ratio - originalRatio) < 0.00001 { return "原始图像" }
    if draft.aspect != .free {
      return draft.portrait ? draft.aspect.label.split(separator: ":").reversed().joined(separator: ":") : draft.aspect.label
    }
    return String(format: "%.3g : 1", draft.ratio)
  }
  private var customRatio: Double? {
    func number(_ text: String) -> Double? {
      Double(text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "."))
    }
    guard let width = number(customWidth), let height = number(customHeight),
      width.isFinite, height.isFinite, width > 0, height > 0,
      (0.1...10).contains(width / height) else { return nil }
    return width / height
  }

  var body: some View {
    HStack(spacing: 6) {
      Text("长宽比：").fixedSize()
      Menu {
        Button("原始图像") { model.selectCropRatio(originalRatio) }
        Divider()
        ForEach(CropAspectRatio.allCases.filter { $0 != .free }, id: \.self) { aspect in
          Button(aspect.label) { model.selectCropRatio(aspect.ratio, aspect: aspect) }
        }
        Divider()
        Button("输入自定值…") {
          customWidth = String(format: "%.6g", model.currentDisplayedCrop.ratio)
          customHeight = "1"
          showingCustomRatio = true
        }
      } label: {
        Text(ratioLabel).monospacedDigit().frame(minWidth: 48, alignment: .leading)
      }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("长宽比")
      Button { model.setCropRatioLocked(!model.cropRatioLocked) } label: {
        Image(systemName: model.cropRatioLocked ? "lock.fill" : "lock.open")
      }
      .help(model.cropRatioLocked ? "解锁长宽比" : "锁定当前长宽比")
      .accessibilityLabel(model.cropRatioLocked ? "解锁长宽比" : "锁定当前长宽比")
      Button("交换宽高") { model.swapCropRatio() }.fixedSize()
      Divider().frame(height: 20).padding(.horizontal, 4)
      Text("角度").fixedSize()
      Slider(value: Binding(get: { angle }, set: { setAngle($0) }), in: -10...10)
        .frame(minWidth: 54, idealWidth: 86, maxWidth: 110)
        .accessibilityLabel("裁剪角度")
        .help("−10° 至 +10° · 双击归零 · Q/E 微调")
        .simultaneousGesture(TapGesture(count: 2).onEnded { setAngle(0) })
      Text(String(format: "%.2f°", angle)).monospacedDigit().frame(width: 42, alignment: .trailing)
      Divider().frame(height: 20).padding(.horizontal, 4)
      Button("重置") { model.resetCropDraft() }.fixedSize()
        .help("重置裁剪范围与角度")
      Spacer(minLength: 4)
      if model.cropReviewAvailable && !model.pendingAutoCropFrameIDs.isEmpty {
        Menu("待检查 \(model.pendingAutoCropFrameIDs.count)") {
          Toggle("仅看待检查", isOn: $model.reviewOnlyPendingCrops)
        }.menuStyle(.borderlessButton).fixedSize()
          .help("筛选待检查照片")
      }
      Button("取消") { model.cancelCrop() }.fixedSize().help("取消本次裁剪 · Esc")
      Button(model.cropReviewAvailable && !model.pendingAutoCropFrameIDs.isEmpty ? "确认并下一张" : "完成") {
        model.performCropPrimaryAction()
      }
      .fixedSize().buttonStyle(.borderedProminent)
      .help(model.cropReviewAvailable && !model.pendingAutoCropFrameIDs.isEmpty
        ? "保存当前裁剪、清除待检查标记并前往下一张 · Enter"
        : "保存当前照片裁剪 · Enter")
    }
    .disabled(!model.canEditCrop)
    .font(.system(size: 11))
    .controlSize(.small)
    .padding(.horizontal, 8).frame(height: 38)
    .background(InterfaceColors.panel)
    .nativeDialog(isPresented: showingCustomRatio, title: "自定长宽比",
      primaryTitle: "确定", primaryEnabled: customRatio != nil,
      primary: {
        if let ratio = customRatio { model.selectCropRatio(ratio) }
        showingCustomRatio = false
      }, cancel: { showingCustomRatio = false }) {
      VStack(alignment: .leading, spacing: 18) {
        HStack {
          Text("宽")
          TextField("宽", text: $customWidth).textFieldStyle(.roundedBorder)
          Text(":")
          Text("高")
          TextField("高", text: $customHeight).textFieldStyle(.roundedBorder)
        }
        if customRatio == nil {
          Text("请输入正数，比例范围为 1:10 至 10:1。")
            .font(.caption).foregroundStyle(.red)
        }
      }

    }
  }
  private func setAngle(_ value: Double) {
    guard value.isFinite else { return }
    var draft = model.currentDisplayedCrop
    draft.angleDegrees = (min(10, max(-10, value)) * 100).rounded() / 100
    model.updateDisplayedCropDraft(draft)
  }
}
