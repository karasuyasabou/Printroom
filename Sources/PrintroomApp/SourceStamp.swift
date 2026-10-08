import Foundation
import PrintroomCore

/// Shared source revision for preview caches, thumbnails and roll analyses.
/// Read fresh attributes to detect same-path replacements. RAW uses size/mtime plus its
/// processing identity; this in-memory type does not change any project/cache format.
struct SourceStamp: Equatable, Sendable {
  let url: URL
  let size: Int64
  let modified: Date?
  let inode: UInt64
  let rawProcessing: RAWProcessingIdentity?

  init(url: URL) throws {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    rawProcessing = try SourceImageIO.processingIdentity(url: url)
    self.url = url.standardizedFileURL
    size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
    modified = attributes[.modificationDate] as? Date
    inode = rawProcessing == nil ? (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0 : 0
  }
}

