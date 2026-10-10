import CryptoKit
import Darwin
import CoreGraphics
import Foundation
import ImageIO
import PrintroomCore
import UniformTypeIdentifiers

/// Rebuildable, profile-tagged PNGs, never device-converted pixels. Only owned
/// SHA-256 filenames inside a real .printroom-cache directory are removed.
actor DiskThumbnailCache {
  struct MaintenanceResult: Sendable {
    let removedFiles: Int
    let remainingFiles: Int
    let remainingBytes: Int64
  }
  private struct Entry {
    let url: URL
    let size: Int64
    let modified: Date
  }
  let directory: URL
  let maximumBytes: Int64
  let maximumAge: TimeInterval
  private let managedRoot: URL?
  private var maintenanceBatchDepth = 0
  private var deferredWrites = 0
  private var urgentMaintenanceScheduled = false
  private var maintenanceFallback: Task<Void, Never>?
  private var usesManagedPolicy: Bool { managedRoot == DiskCachePolicy.root.appendingPathComponent("thumbnails-v1", isDirectory: true).standardizedFileURL }

  init(
    directory: URL, maximumBytes: Int64 = 512 * 1024 * 1024,
    maximumAge: TimeInterval = 30 * 24 * 60 * 60, managedRoot: URL? = nil
  ) {
    self.managedRoot = managedRoot?.standardizedFileURL
    self.directory = directory.standardizedFileURL
    self.maximumBytes = max(0, maximumBytes)
    self.maximumAge = max(0, maximumAge)
  }

  /// Path and project identity isolate copied rolls, including equal inode numbers on different volumes.
  static func forRoll(folder: URL, projectID: UUID, cacheRoot: URL? = nil) -> DiskThumbnailCache {
    let root = (cacheRoot ?? DiskCachePolicy.root.appendingPathComponent("thumbnails-v1", isDirectory: true)).standardizedFileURL
    let identity = projectID.uuidString + "\n" + folder.standardizedFileURL.path
    let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    return DiskThumbnailCache(directory: root.appendingPathComponent(key, isDirectory: true)
      .appendingPathComponent(".printroom-cache", isDirectory: true), managedRoot: root)
  }

  /// Transfer only owned PNGs. Any failed transfer retains its source for the next open.
  func migrateLegacy(from folder: URL) async throws {
    let legacy = DiskThumbnailCache(directory: folder.appendingPathComponent(".printroom-cache", isDirectory: true))
    try await legacy.transferOwnedImages(to: self)
  }

  private func transferOwnedImages(to destination: DiskThumbnailCache) async throws {
    try validateDirectory(create: false)
    guard FileManager.default.fileExists(atPath: directory.path) else { return }
    for entry in try ownedFiles() {
      try Task.checkCancellation()
      if entry.url.pathExtension == "png" {
        let key = entry.url.deletingPathExtension().lastPathComponent
        guard let image = try image(for: key) else { continue }
        try await destination.store(image, for: key)
        try Task.checkCancellation()
        // unlink never recursively removes a directory substituted by another process.
        guard entry.url.withUnsafeFileSystemRepresentation({ Darwin.unlink($0!) }) == 0 else {
          throw PrintroomError.invalid("缩略图已迁入系统缓存，旧缓存暂时无法删除；下次打开重试。")
        }
      } else if Date().timeIntervalSince(entry.modified) > 24 * 60 * 60 {
        _ = entry.url.withUnsafeFileSystemRepresentation { Darwin.unlink($0!) }
      }
    }
    // Remove only an empty directory; retain unknown files and active temporaries.
    _ = directory.withUnsafeFileSystemRepresentation { Darwin.rmdir($0!) }
  }

  func image(for key: String) throws -> CGImage? {
    try Task.checkCancellation()
    try validateDirectory(create: false)
    let file = try fileURL(key)
    guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
      values.isRegularFile == true, values.isSymbolicLink != true,
      let source = CGImageSourceCreateWithURL(file as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(
        source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    else { return nil }
    try Task.checkCancellation()
    // Modification time is the cache's last-use clock, not source metadata.
    try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
    return image
  }

  func beginMaintenanceBatch() { maintenanceBatchDepth += 1 }

  /// Unstructured, uncancelled cleanup also runs when the refresh exits early.
  @discardableResult nonisolated func endMaintenanceBatch() -> Task<Void, Never> {
    Task.detached(priority: .utility) { await self.completeMaintenanceBatch() }
  }

  private func completeMaintenanceBatch() {
    maintenanceBatchDepth = max(0, maintenanceBatchDepth - 1)
    if maintenanceBatchDepth == 0 { flushDeferredMaintenance() }
  }

  private func deferMaintenanceAfterWrite() {
    deferredWrites += 1
    if maintenanceFallback == nil {
      // Fixed deadline, never reset by later writes or a replacement refresh.
      maintenanceFallback = Task.detached(priority: .utility) {
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
        await self.flushDeferredMaintenance()
      }
    }
    if deferredWrites >= 64 && !urgentMaintenanceScheduled {
      urgentMaintenanceScheduled = true
      Task.detached(priority: .utility) { await self.flushDeferredMaintenance() }
    }
  }

  private func flushDeferredMaintenance() {
    guard deferredWrites > 0 else { return }
    deferredWrites = 0
    urgentMaintenanceScheduled = false
    let fallback = maintenanceFallback
    maintenanceFallback = nil
    // The deadline task may be the caller; don't cancel it before maintain's checkpoints.
    defer { fallback?.cancel() }
    do { _ = try maintain() } catch {
      // Local enumeration failure must not suppress the managed policy's opportunity.
      if usesManagedPolicy { SourceProxyService.shared.scheduleMaintenance() }
    }
  }

  func store(_ image: CGImage, for key: String) throws {
    let trace = PerformanceTrace.begin(); defer { PerformanceTrace.end("thumbnail.store_inclusive", trace) }
    try Task.checkCancellation()
    try validateDirectory(create: true)
    let file = try fileURL(key)
    let temporary = directory.appendingPathComponent(
      ".printroom-thumbnail-\(UUID().uuidString).png.tmp")
    defer { try? FileManager.default.removeItem(at: temporary) }
    guard let destination = CGImageDestinationCreateWithURL(
      temporary as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw PrintroomError.invalid("无法创建缩略图缓存") }
    let encodeTrace = PerformanceTrace.begin()
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw PrintroomError.invalid("无法完成缩略图缓存")
    }
    PerformanceTrace.end("thumbnail.png_encode_write", encodeTrace)
    let publishTrace = PerformanceTrace.begin()
    try Task.checkCancellation()
    if FileManager.default.fileExists(atPath: file.path) {
      // Cache is disposable, but never follow a substituted symbolic link.
      let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true else {
        throw PrintroomError.invalid("缩略图缓存目标不是普通文件")
      }
      _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary)
    } else {
      try FileManager.default.moveItem(at: temporary, to: file)
    }
    PerformanceTrace.end("thumbnail.publish", publishTrace)
    if maintenanceBatchDepth > 0 { deferMaintenanceAfterWrite() }
    else { _ = try maintain() }
  }

  @discardableResult func maintain(now: Date = Date()) throws -> MaintenanceResult {
    let trace = PerformanceTrace.begin(); defer { PerformanceTrace.end("thumbnail.maintenance", trace) }
    try Task.checkCancellation()
    try validateDirectory(create: false)
    guard FileManager.default.fileExists(atPath: directory.path) else {
      return MaintenanceResult(removedFiles: 0, remainingFiles: 0, remainingBytes: 0)
    }
    let entries = try ownedFiles()
    var retained: [Entry] = []
    var removed = 0
    for entry in entries {
      try Task.checkCancellation()
      let temporary = entry.url.lastPathComponent.hasSuffix(".png.tmp")
      // A second app may be publishing a temporary now; reap only abandoned ones.
      let ageLimit = temporary ? 24 * 60 * 60 : (usesManagedPolicy ? .infinity : maximumAge)
      if now.timeIntervalSince(entry.modified) > ageLimit {
        try FileManager.default.removeItem(at: entry.url)
        removed += 1
      } else if !temporary {
        retained.append(entry)
      }
    }
    retained.sort { $0.modified < $1.modified }
    var bytes = retained.reduce(Int64(0)) { $0 + $1.size }
    var evicted = 0
    for entry in retained where !usesManagedPolicy && bytes > maximumBytes {
      try Task.checkCancellation()
      try FileManager.default.removeItem(at: entry.url)
      bytes -= entry.size
      removed += 1
      evicted += 1
    }
    if usesManagedPolicy { SourceProxyService.shared.scheduleMaintenance() }
    return MaintenanceResult(
      removedFiles: removed, remainingFiles: retained.count - evicted, remainingBytes: bytes)
  }

  @discardableResult func clear() throws -> MaintenanceResult {
    try Task.checkCancellation()
    try validateDirectory(create: false)
    guard FileManager.default.fileExists(atPath: directory.path) else {
      return MaintenanceResult(removedFiles: 0, remainingFiles: 0, remainingBytes: 0)
    }
    var removed = 0
    for entry in try ownedFiles() where entry.url.pathExtension == "png" {
      try Task.checkCancellation()
      try FileManager.default.removeItem(at: entry.url)
      removed += 1
    }
    // Recent temporaries may belong to another running application. They are
    // not committed cache entries; maintain() reaps abandoned ones after a day.
    return MaintenanceResult(removedFiles: removed, remainingFiles: 0, remainingBytes: 0)
  }

  private func fileURL(_ key: String) throws -> URL {
    guard Self.isDigest(key) else { throw PrintroomError.invalid("缩略图缓存键必须是 SHA-256") }
    return directory.appendingPathComponent(key + ".png")
  }

  private func validateDirectory(create: Bool) throws {
    guard directory.isFileURL, directory.lastPathComponent == ".printroom-cache" else {
      throw PrintroomError.invalid("缩略图缓存目录名称无效")
    }
    let manager = FileManager.default
    if let managedRoot {
      for ancestor in [managedRoot.deletingLastPathComponent(), managedRoot, directory.deletingLastPathComponent()] {
        if let values = try? ancestor.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
          guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw PrintroomError.invalid("系统缩略图缓存路径不能是符号链接或普通文件")
          }
        }
      }
    }
    if let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
      guard values.isDirectory == true, values.isSymbolicLink != true else {
        throw PrintroomError.invalid("缩略图缓存目录不能是符号链接或普通文件")
      }
    } else if create {
      try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    }
  }

  private func ownedFiles() throws -> [Entry] {
    try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
      ]
    ).compactMap { url in
      let name = url.lastPathComponent
      let png = url.pathExtension == "png" && Self.isDigest(url.deletingPathExtension().lastPathComponent)
      let temporary = name.hasPrefix(".printroom-thumbnail-") && name.hasSuffix(".png.tmp")
        && UUID(uuidString: String(name.dropFirst(21).dropLast(8))) != nil
      guard png || temporary else { return nil }
      let values = try url.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
      ])
      guard values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
      return Entry(
        url: url, size: Int64(values.fileSize ?? 0),
        modified: values.contentModificationDate ?? .distantPast)
    }
  }

  private static func isDigest(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
}
