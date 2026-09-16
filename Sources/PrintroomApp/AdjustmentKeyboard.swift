import Foundation
import PrintroomCore

/// One gesture owns one undo group, regardless of key-repeat preferences.
@MainActor final class AdjustmentKeyboard {
  private var task: Task<Void, Never>?
  private var heldKey: String?

  func stop(model: EditorModel, key: String? = nil) {
    guard let heldKey, key == nil || key?.lowercased() == heldKey else { return }
    task?.cancel()
    task = nil
    self.heldKey = nil
    model.endAdjustment()
  }

  func start(model: EditorModel, key: String, contrast: Bool, shift: Bool,
             isRepeat: Bool, canContinue: @escaping @MainActor () -> Bool) {
    let key = key.lowercased()
    guard !isRepeat, key.count == 1, "qeadzcws".contains(key),
      model.activeFrame != nil, !model.isCropping else { return }
    stop(model: model)
    guard contrast || model.timingMode == .rgb || !["z", "c"].contains(key) else { return }
    model.beginAdjustment()
    heldKey = key
    if contrast { model.handleContrastKey(key) }
    else { model.handleTimingKey(key, step: shift ? 10 : 1) }
    let frameID = model.selection.activeFrameID
    let clock = ContinuousClock()
    let start = clock.now
    task = Task { [weak self, weak model] in
      do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
      var applied = 0
      while !Task.isCancelled {
        guard let self, let model else { return }
        guard model.selection.activeFrameID == frameID, canContinue(),
          model.errorMessage == nil, !model.showExportSummary, !model.isCropping else {
          self.stop(model: model)
          return
        }
        let elapsed = start.duration(to: clock.now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        let total = contrast ? EditorModel.heldContrastSteps(elapsed: seconds)
          : EditorModel.heldTimingCV(elapsed: seconds)
        if total > applied {
          if contrast { model.handleContrastKey(key, steps: total - applied) }
          else { model.handleTimingKey(key, step: total - applied) }
          applied = total
        }
        do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
      }
    }
  }
}

extension EditorModel {
  // Keep the original entry points so every existing lifecycle cancellation
  // ends either kind of adjustment, including frame changes and Undo.
  func stopTimingKey(_ key: String? = nil) {
    adjustmentKeyboard.stop(model: self, key: key)
  }

  func startTimingKey(_ key: String, shift: Bool, isRepeat: Bool,
                      canContinue: @escaping @MainActor () -> Bool) {
    startAdjustmentKey(key, contrast: false, shift: shift, isRepeat: isRepeat,
      canContinue: canContinue)
  }

  func startAdjustmentKey(_ key: String, contrast: Bool, shift: Bool, isRepeat: Bool,
                          canContinue: @escaping @MainActor () -> Bool) {
    adjustmentKeyboard.start(model: self, key: key, contrast: contrast, shift: shift,
      isRepeat: isRepeat, canContinue: canContinue)
  }

  static func heldTimingCV(elapsed: Double) -> Int {
    Int((max(0, elapsed - 0.4) * 25 + 1e-9).rounded(.down))
  }

  static func heldContrastSteps(elapsed: Double) -> Int {
    Int((max(0, elapsed - 0.4) * 10 + 1e-9).rounded(.down))
  }

  func handleTimingKey(_ key: String, step: Int = 1) {
    guard activeFrame != nil else { return }
    let step = max(0, min(TimingParameters.range.count - 1, step))
    if timingMode == .simple {
      let axis: SimpleTimingAxis
      let sign: Int
      switch key.lowercased() {
      case "w": axis = .exposure; sign = 1
      case "s": axis = .exposure; sign = -1
      case "q": axis = .temperature; sign = -1
      case "e": axis = .temperature; sign = 1
      case "a": axis = .tint; sign = -1
      case "d": axis = .tint; sign = 1
      default: return
      }
      edit { $0.timing = axis.moving(sign * step, in: $0.timing) }
      return
    }
    edit { a in
      switch key.lowercased() {
      case "q": a.timing.red = max(TimingParameters.range.lowerBound, a.timing.red - step)
      case "e": a.timing.red = min(TimingParameters.range.upperBound, a.timing.red + step)
      case "a": a.timing.green = max(TimingParameters.range.lowerBound, a.timing.green - step)
      case "d": a.timing.green = min(TimingParameters.range.upperBound, a.timing.green + step)
      case "z": a.timing.blue = max(TimingParameters.range.lowerBound, a.timing.blue - step)
      case "c": a.timing.blue = min(TimingParameters.range.upperBound, a.timing.blue + step)
      case "w": a.timing.master = min(TimingParameters.range.upperBound, a.timing.master + step)
      case "s": a.timing.master = max(TimingParameters.range.lowerBound, a.timing.master - step)
      default: break
      }
    }
  }

  func handleContrastKey(_ key: String, steps: Int = 1) {
    guard activeFrame != nil else { return }
    let step = Float(max(0, min(175, steps))) * 0.01
    func adjusted(_ value: Float, _ direction: Float) -> Float {
      // Integer hundredths prevent accumulated Float drift during long holds.
      min(2, max(0.25, ((value + direction * step) * 100).rounded() / 100))
    }
    edit { a in
      switch key.lowercased() {
      case "q": a.contrast.red = adjusted(a.contrast.red, -1)
      case "e": a.contrast.red = adjusted(a.contrast.red, 1)
      case "a": a.contrast.green = adjusted(a.contrast.green, -1)
      case "d": a.contrast.green = adjusted(a.contrast.green, 1)
      case "z": a.contrast.blue = adjusted(a.contrast.blue, -1)
      case "c": a.contrast.blue = adjusted(a.contrast.blue, 1)
      case "w": a.contrast.master = adjusted(a.contrast.master, 1)
      case "s": a.contrast.master = adjusted(a.contrast.master, -1)
      default: break
      }
    }
  }
}
