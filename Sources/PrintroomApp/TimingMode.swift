import Foundation
import PrintroomCore

enum TimingMode: String, CaseIterable {
  case simple, rgb
  static let preferenceKey = "timingMode"
}

extension SimpleTimingAxis {
  var title: String {
    switch self {
    case .exposure: return "曝光"
    case .temperature: return "色温"
    case .tint: return "色调"
    }
  }
  var help: String {
    switch self {
    case .exposure: return "曝光 · 暗 ↔ 亮 · W / S"
    case .temperature: return "色温 · 冷 ↔ 暖 · Q / E"
    case .tint: return "色调 · 绿 ↔ 洋红 · A / D"
    }
  }
}

extension EditorModel {
  func setSimpleTiming(_ axis: SimpleTimingAxis, value: Double) {
    edit { $0.timing = axis.setting(value, in: $0.timing) }
  }
}
