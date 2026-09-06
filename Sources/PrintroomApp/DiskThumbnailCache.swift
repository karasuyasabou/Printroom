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

  init(
    directory: URL, maximumBytes: Int64 = 512 * 1024 * 1024,
    maximumAge: TimeInterval = 30 * 24 * 60 * 60
  ) {
    self.directory = directory.standardizedFileURL
    self.maximumBytes = max(0, maximumBytes)
    self.maximumAge = max(0, maximumAge)
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

  func store(_ image: CGImage, for key: String) throws {
    try Task.checkCancellation()
    try validateDirectory(create: true)
    let file = try fileURL(key)
    let temporary = directory.appendingPathComponent(
      ".printroom-thumbnail-\(UUID().uuidString).png.tmp")
    defer { try? FileManager.default.removeItem(at: temporary) }
    guard let destination = CGImageDestinationCreateWithURL(
      temporary as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw PrintroomError.invalid("无法创建缩略图缓存") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw PrintroomError.invalid("无法完成缩略图缓存")
    }
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
    _ = try maintain()
  }

  @discardableResult func maintain(now: Date = Date()) throws -> MaintenanceResult {
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
      let ageLimit = temporary ? 24 * 60 * 60 : maximumAge
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
    for entry in retained where bytes > maximumBytes {
      try Task.checkCancellation()
      try FileManager.default.removeItem(at: entry.url)
      bytes -= entry.size
      removed += 1
      evicted += 1
    }
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
      throw PrintroomError.invalid("缩略图缓存只能位于卷的 .printroom-cache 目录")
    }
    let manager = FileManager.default
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
