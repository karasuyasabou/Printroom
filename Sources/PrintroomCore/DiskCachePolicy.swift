import Foundation

public struct DiskCachePolicy: Sendable, Equatable {
  public var limitGB: Double
  public var retentionDays: Int
  public static let root = PerformanceTrace.isolatedCacheRoot ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("studio.printroom.local.v3.3", isDirectory: true)
  public init(limitGB: Double = 8, retentionDays: Int = 30) {
    self.limitGB = limitGB.isFinite && (0.1...100_000).contains(limitGB) ? limitGB : 8
    self.retentionDays = [0, 3, 7, 30].contains(retentionDays) ? retentionDays : 30
  }
  public var limitBytes: Int64 { Int64(limitGB * 1_000_000_000) }
  public static func load(defaults: UserDefaults = .standard) -> Self {
    Self(limitGB: defaults.object(forKey: "diskCacheLimitGB") as? Double ?? 8,
         retentionDays: defaults.object(forKey: "diskCacheRetentionDays") as? Int ?? 30)
  }
  public func save(defaults: UserDefaults = .standard) {
    defaults.set(limitGB, forKey: "diskCacheLimitGB")
    defaults.set(retentionDays, forKey: "diskCacheRetentionDays")
  }
}

/// Enumerates only committed application cache entries, never originals or active staging.
/// Call maintenance under SourceProxyService's exclusive lock.
public enum ManagedDiskCache {
  struct Entry { let url: URL; let bytes: Int64; let date: Date }
  static func isDirectory(_ url: URL) -> Bool {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeDirectory
  }
  static func digest(_ name: String) -> Bool {
    name.utf8.count == 64 && name.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
  static func children(_ url: URL) throws -> [URL] {
    guard isDirectory(url) else { return [] }
    return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
  }
  static func entry(_ url: URL) throws -> Entry? {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
    return Entry(url: url, bytes: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                 date: attributes[.modificationDate] as? Date ?? .distantPast)
  }
  static func entries(root: URL) throws -> [Entry] {
    guard isDirectory(root), isDirectory(root.deletingLastPathComponent()) else { return [] }
    var result: [Entry] = []
    for directory in try children(root.appendingPathComponent("raw-v1"))
      where digest(directory.lastPathComponent) && isDirectory(directory) {
      let files = try children(directory).compactMap { try entry($0) }
      let date = try FileManager.default.attributesOfItem(atPath: directory.path)[.modificationDate] as? Date ?? .distantPast
      result.append(Entry(url: directory, bytes: files.reduce(0) { $0 + $1.bytes }, date: date))
    }
    for namespace in try children(root.appendingPathComponent("thumbnails-v1"))
      where digest(namespace.lastPathComponent) && isDirectory(namespace) {
      for file in try children(namespace.appendingPathComponent(".printroom-cache"))
        where file.pathExtension == "png" && digest(file.deletingPathExtension().lastPathComponent) {
        // Atomic replacement or another cache writer can remove a file during a scan.
        if let item = try? entry(file) { result.append(item) }
      }
    }
    return result
  }
  public static func size(root: URL = DiskCachePolicy.root) throws -> Int64 {
    try entries(root: root).reduce(0) { $0 + $1.bytes }
  }
  @discardableResult
  static func maintain(root: URL, policy: DiskCachePolicy, now: Date = Date()) throws -> Int64 {
    let items = try entries(root: root).sorted { $0.date < $1.date }
    var total = items.reduce(Int64(0)) { $0 + $1.bytes }
    for item in items {
      let expired = policy.retentionDays != 0 && now.timeIntervalSince(item.date) > Double(policy.retentionDays) * 86400
      if expired || total > policy.limitBytes {
        do { try FileManager.default.removeItem(at: item.url); total -= item.bytes }
        catch CocoaError.fileNoSuchFile { total -= item.bytes }
      }
    }
    return total
  }
}
