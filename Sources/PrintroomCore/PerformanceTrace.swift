import Foundation

/// Opt-in diagnostic build: no clocks, locks or environment overrides in normal builds.
/// Durations are inclusive wall time. Nested spans and concurrent workers must not be added.
public enum PerformanceTrace {
  public struct Stat: Codable, Sendable {
    public var count: Int = 0
    public var seconds: Double = 0
    public var maximum: Double = 0
  }
  #if PRINTROOM_PERFORMANCE_TRACE
  private final class Storage: @unchecked Sendable {
    let lock = NSLock()
    var stats: [String: Stat] = [:]
  }
  private static let storage = Storage()
  public static let enabled = ProcessInfo.processInfo.environment["PRINTROOM_TRACE"] == "1"
  public static var isolatedCacheRoot: URL? {
    guard let path = ProcessInfo.processInfo.environment["PRINTROOM_TRACE_CACHE_ROOT"],
      path.hasPrefix("/"), path.contains("/scratch/performance/") else { return nil }
    return URL(fileURLWithPath: path, isDirectory: true)
  }
  @inline(__always) public static func begin() -> UInt64 {
    enabled ? DispatchTime.now().uptimeNanoseconds : 0
  }
  public static func end(_ name: String, _ start: UInt64) {
    guard start != 0 else { return }
    let duration = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    observe(name, seconds: duration)
  }
  public static func observe(_ name: String, seconds duration: Double) {
    guard enabled else { return }
    storage.lock.withLock {
      var stat = storage.stats[name, default: Stat()]
      stat.count += 1; stat.seconds += duration; stat.maximum = max(stat.maximum, duration)
      storage.stats[name] = stat
    }
  }
  public static func reset() { storage.lock.withLock { storage.stats = [:] } }
  public static func snapshot() -> [String: Stat] { storage.lock.withLock { storage.stats } }
  #else
  public static let enabled = false
  public static var isolatedCacheRoot: URL? { nil }
  @inline(__always) public static func begin() -> UInt64 { 0 }
  @inline(__always) public static func end(_ name: String, _ start: UInt64) {}
  @inline(__always) public static func observe(_ name: String, seconds: Double) {}
  public static func reset() {}
  public static func snapshot() -> [String: Stat] { [:] }
  #endif
  @inline(__always) public static func measure<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
    let start = begin(); defer { end(name, start) }; return try body()
  }
}
