import Foundation

/// Alternate coordinates for the existing integer Timing parameters; no new pipeline stage.
public enum SimpleTimingAxis: CaseIterable, Sendable {
  case exposure, temperature, tint

  public var range: ClosedRange<Double> {
    switch self {
    case .exposure: return -1024...1024
    case .temperature: return -512...512
    case .tint: return (-1024.0 / 3)...(1024.0 / 3)
    }
  }
  private var direction: [Int] {
    switch self {
    case .exposure: return [1, 1, 1]
    case .temperature: return [1, 0, -1]
    case .tint: return [1, -2, 1]
    }
  }
  public func value(in timing: TimingParameters) -> Double {
    let r = Double(timing.red), g = Double(timing.green), b = Double(timing.blue)
    switch self {
    case .exposure: return Double(timing.master) + (r + g + b) / 3
    case .temperature: return (r - b) / 2
    case .tint: return (r + b - 2 * g) / 6
    }
  }
  public func setting(_ value: Double, in timing: TimingParameters) -> TimingParameters {
    guard value.isFinite else { return timing }
    let requested = min(range.upperBound, max(range.lowerBound, value))
    return moving(Int((requested - self.value(in: timing)).rounded()), in: timing)
  }
  public func moving(_ steps: Int, in timing: TimingParameters) -> TimingParameters {
    let effective = [timing.red, timing.green, timing.blue].map { $0 + timing.master }
    let direction = self.direction
    // A legal Master exists iff effective channels are within ±1024 and their
    // spread is at most 1024. Intersect those inequalities along the requested axis.
    var lower = -4096.0, upper = 4096.0
    func constrain(_ base: Int, _ slope: Int, limit: Int) {
      guard slope != 0 else { return }
      let a = Double(-limit - base) / Double(slope)
      let b = Double(limit - base) / Double(slope)
      lower = max(lower, min(a, b)); upper = min(upper, max(a, b))
    }
    for i in 0..<3 {
      constrain(effective[i], direction[i], limit: 1024)
      for j in 0..<i {
        constrain(effective[i] - effective[j], direction[i] - direction[j], limit: 1024)
      }
    }
    let delta = min(Int(floor(upper)), max(Int(ceil(lower)), steps))
    guard delta != 0 else { return timing }
    let result = zip(effective, direction).map { $0 + delta * $1 }
    let minimumMaster = max(-512, result.max()! - 512)
    let maximumMaster = min(512, result.min()! + 512)
    // Exposure uses Master first; chromatic edits retain Master when possible.
    let preferred = timing.master + (self == .exposure ? delta : 0)
    let master = min(maximumMaster, max(minimumMaster, preferred))
    return TimingParameters(master: master, red: result[0] - master,
      green: result[1] - master, blue: result[2] - master)
  }
}
