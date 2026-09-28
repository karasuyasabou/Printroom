import CryptoKit
import Darwin
import Foundation

/// Separate from the density algorithm: identifies the reproducible RAW input samples.
public struct RAWProcessingIdentity: Codable, Hashable, Sendable {
  public let sourceRevision: String
  public let adobeVersion: String
  public let libRawVersion: String
  public let strategyVersion: String
  public let proxySamplingVersion: String
}

/// All source reads pass through this boundary; TIFF sample interpretation is unchanged.
public enum SourceImageIO {
  public static func isRAW(_ url: URL) -> Bool { url.pathExtension.lowercased() == "arw" }
  public static func isSupportedSource(_ url: URL) -> Bool {
    isRAW(url) || ["tif", "tiff"].contains(url.pathExtension.lowercased())
  }
  public static func processingIdentity(url: URL) throws -> RAWProcessingIdentity? {
    isRAW(url) ? try RAWSourceService.shared.identity(url: url) : nil
  }
  public static func metadata(url: URL) throws -> TIFFMetadata {
    if !isRAW(url) { return try TIFFCodec.metadata(url: url) }
    return try RAWSourceService.shared.metadata(url: url)
  }
  public static func readPreview(url: URL, maxDimension: Int,
                                 expectedIdentity: RAWProcessingIdentity? = nil) throws -> LinearImage {
    if !isRAW(url) { return try TIFFCodec.readPreview(url: url, maxDimension: maxDimension) }
    return try RAWSourceService.shared.preview(url: url, maxDimension: maxDimension,
                                              expectedIdentity: expectedIdentity)
  }
  public static func readRegion(url: URL, rect: PixelRect,
                                expectedIdentity: RAWProcessingIdentity? = nil) throws -> LinearImage {
    if !isRAW(url) { return try TIFFCodec.readRegion(url: url, rect: rect) }
    return try RAWSourceService.shared.region(url: url, rect: rect, expectedIdentity: expectedIdentity)
  }
  public static func read(url: URL, expectedIdentity: RAWProcessingIdentity? = nil) throws -> LinearImage {
    if !isRAW(url) { return try TIFFCodec.read(url: url) }
    return try RAWSourceService.shared.read(url: url, expectedIdentity: expectedIdentity)
  }
}

public struct AdobeRAWInstallation: Sendable {
  public let executable: URL
  public let version: String
  public init(executable: URL, version: String) { self.executable = executable; self.version = version }
}

/// Production defaults are immutable; injected functions allow failure tests without invoking Adobe.
struct RAWSourceDependencies: Sendable {
  var installation: @Sendable () throws -> AdobeRAWInstallation = RAWSourceService.adobeInstallation
  var convert: @Sendable (AdobeRAWInstallation, URL, URL, @escaping @Sendable () -> Bool) throws -> Void = RAWSourceService.convert
  var decode: @Sendable (URL, @escaping @Sendable () -> Bool) throws -> LinearImage = {
    try RawDecoder.decode(linearDNG: $0, cancelled: $1)
  }
  var inspect: @Sendable (URL) throws -> (Int, Int) = {
    let info = try RawDecoder.metadata(linearDNG: $0)
    return (info.width, info.height)
  }
  var didMaintain: @Sendable () -> Void = {}
  var didReadDigest: @Sendable (URL, Int) -> Void = { _, _ in }
  var libRawVersion: String = RawDecoder.version
}

/// Four cross-process slots bound Adobe/LibRaw work. Waiting consumers share an operation,
/// and cancellation only stops its producer when the last consumer has gone away.
/// Call synchronous methods off the main thread (as ImageService already does).
public final class RAWSourceService: @unchecked Sendable {
  public static let shared = RAWSourceService()
  public static let strategyVersion = "adobe-linear-camera-rgb-v1"
  public static let proxySamplingVersion = "nearest-original-1600-v1"
  public static let preparationConcurrency = 4
  public static let defaultCacheLimit: Int64 = 8 * 1024 * 1024 * 1024
  private let root: URL
  private let usesManagedPolicy: Bool
  private let limit: Int64
  private let dependencies: RAWSourceDependencies
  private let queue = DispatchQueue(label: "studio.printroom.raw.prepare", qos: .userInitiated, attributes: .concurrent)
  private let maintenanceQueue = DispatchQueue(label: "studio.printroom.raw.maintenance", qos: .utility)
  private let maintenanceLock = NSLock()
  private var maintenanceScheduled = false
  private var maintenanceRequested = false
  private let digestLock = NSLock()
  private let lock = NSLock()
  private var jobs: [String: any RAWJobStatus] = [:]
  // Protected independently from scheduling. Revisions include change time, inode and nanoseconds.
  private var digests: [String: (FileRevision, String)] = [:]

  public convenience init(cacheRoot: URL? = nil, byteLimit: Int64 = RAWSourceService.defaultCacheLimit) {
    self.init(cacheRoot: cacheRoot, byteLimit: byteLimit, dependencies: RAWSourceDependencies())
  }
  init(cacheRoot: URL?, byteLimit: Int64, dependencies: RAWSourceDependencies) {
    root = cacheRoot ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("studio.printroom.local.v3.3/raw-v1", isDirectory: true)
    usesManagedPolicy = cacheRoot == nil
    limit = max(0, byteLimit)
    self.dependencies = dependencies
  }

  /// Cheap file-stat + converter-version snapshot; no hashing, conversion or worker wait.
  public func identity(url: URL) throws -> RAWProcessingIdentity {
    let adobe = try dependencies.installation()
    let revision = try FileRevision(url)
    return RAWProcessingIdentity(sourceRevision: revision.key, adobeVersion: adobe.version,
      libRawVersion: dependencies.libRawVersion, strategyVersion: Self.strategyVersion,
      proxySamplingVersion: Self.proxySamplingVersion)
  }
  public func metadata(url: URL) throws -> TIFFMetadata {
    try operation(url: url, key: "metadata") { cancelled in
      let entry = try self.prepare(url: url, cancelled: cancelled)
      return TIFFMetadata(width: entry.manifest.width, height: entry.manifest.height,
                          embeddedProfileName: "Adobe RAW · 线性相机 RGB")
    }
  }
  public func preview(url: URL, maxDimension: Int = 1600,
                      expectedIdentity: RAWProcessingIdentity? = nil) throws -> LinearImage {
    guard maxDimension > 0 else { throw Self.invalid("RAW 代理尺寸必须大于零。") }
    return try operation(url: url, key: "preview-\(maxDimension)-\(String(describing: expectedIdentity))") { cancelled in
      let entry = try self.prepare(url: url, expectedIdentity: expectedIdentity, cancelled: cancelled)
      let image = try TIFFCodec.readPreview(
        url: maxDimension == 240 ? entry.thumbnail : entry.proxy, maxDimension: maxDimension)
      try self.verifySource(url, identity: entry.manifest.identity, cancelled: cancelled)
      return image
    }
  }
  public func read(url: URL, expectedIdentity: RAWProcessingIdentity? = nil) throws -> LinearImage {
    try operation(url: url, key: "read-\(String(describing: expectedIdentity))") { cancelled in
      let identity = try self.identity(url: url)
      guard expectedIdentity == nil || expectedIdentity == identity else {
        throw Self.invalid("RAW 原片或处理版本已改变，请重新提交导出。")
      }
      let image = try self.decodeForExport(identity: identity, url: url, cancelled: cancelled)
      try self.verifySource(url, identity: identity, cancelled: cancelled)
      return image
    }
  }
  public func region(url: URL, rect: PixelRect, expectedIdentity: RAWProcessingIdentity? = nil) throws -> LinearImage {
    try operation(url: url, key: "region-\(rect)-\(String(describing: expectedIdentity))") { cancelled in
      let entry = try self.prepare(url: url, expectedIdentity: expectedIdentity, cancelled: cancelled)
      let proxy = try TIFFCodec.read(url: entry.proxy)
      let image = try Self.proxyRegion(proxy, sourceWidth: entry.manifest.width,
        sourceHeight: entry.manifest.height, rect: rect, cancelled: cancelled)
      try self.verifySource(url, identity: entry.manifest.identity, cancelled: cancelled)
      return image
    }
  }

  /// Waits for active reads/preparation, then removes only this service's owned
  /// entries under the cross-process lock. Projects and original sources are untouched.
  public func clearCache() throws {
    try operation(url: root, key: "clear-cache") { cancelled in
      let fm = FileManager.default
      for entry in try fm.contentsOfDirectory(at: self.root, includingPropertiesForKeys: nil) {
        try self.check(cancelled)
        if entry.lastPathComponent.count == 64, entry.lastPathComponent.allSatisfy({ $0.isHexDigit }),
           Self.isDirectory(entry) {
          try fm.removeItem(at: entry)
        }
      }
      self.digestLock.withLock { self.digests.removeAll(keepingCapacity: true) }
    }
  }

  private struct Manifest: Codable {
    var identity: RAWProcessingIdentity
    var sourceSHA256: String
    var width: Int
    var height: Int
    var proxySHA256: String
    var thumbnailSHA256: String
  }
  private struct Entry {
    var directory: URL
    var manifest: Manifest
    var proxy: URL { directory.appendingPathComponent("proxy.tiff") }
    var thumbnail: URL { directory.appendingPathComponent("thumbnail.tiff") }
  }

  private func prepare(url: URL, expectedIdentity: RAWProcessingIdentity? = nil,
                       cancelled: @escaping @Sendable () -> Bool) throws -> Entry {
    try check(cancelled)
    guard SourceImageIO.isRAW(url), url.isFileURL else { throw Self.invalid("首版 RAW 输入只支持本地 ARW 文件。") }
    // Always detect the actual dependency, including on a cache hit. Never silently
    // combine samples made by an unavailable/changed converter with a new full image.
    let adobe = try dependencies.installation()
    let before = try FileRevision(url)
    let identity = RAWProcessingIdentity(sourceRevision: before.key, adobeVersion: adobe.version,
      libRawVersion: dependencies.libRawVersion, strategyVersion: Self.strategyVersion,
      proxySamplingVersion: Self.proxySamplingVersion)
    let key = Self.hash(Data(["stat-cache-v1", before.key, adobe.version, dependencies.libRawVersion,
                             Self.strategyVersion, Self.proxySamplingVersion].joined(separator: "\n").utf8))
    if let expectedIdentity {
      guard expectedIdentity.sourceRevision == before.key,
        expectedIdentity.adobeVersion == adobe.version,
        expectedIdentity.libRawVersion == dependencies.libRawVersion,
        expectedIdentity.strategyVersion == Self.strategyVersion,
        expectedIdentity.proxySamplingVersion == Self.proxySamplingVersion
      else { throw Self.invalid("RAW 原片或处理版本已改变，请重新提交操作。") }
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let destination = root.appendingPathComponent(key, isDirectory: true)
    if let entry = try cachedEntry(at: destination, identity: identity, cancelled: cancelled) {
      try verifySource(url, identity: identity, cancelled: cancelled)
      try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
      return entry
    }
    // Old content-addressed entries already persist the complete stat identity.
    // Discover them without reading the RAW; migrate under the existing same-source
    // lock so subsequent launches use one direct lookup. Never follow cache symlinks.
    if !FileManager.default.fileExists(atPath: destination.path) {
      for candidate in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
        try check(cancelled)
        let name = candidate.lastPathComponent
        guard name.count == 64, name.allSatisfy({ $0.isHexDigit }),
              let entry = try cachedEntry(at: candidate, identity: identity, cancelled: cancelled,
                                          legacy: true) else { continue }
        try verifySource(url, identity: identity, cancelled: cancelled)
        try FileManager.default.moveItem(at: candidate, to: destination)
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
        scheduleMaintenance()
        return Entry(directory: destination, manifest: entry.manifest)
      }
    }
    let sourceHash = try digest(url, cancelled: cancelled)
    try check(cancelled)
    // Only this worker uses the owned directory; stale/corrupt entries are rebuilt.
    if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
    let temporary = root.appendingPathComponent(".preparing-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let dng = temporary.appendingPathComponent("source.dng")
    try dependencies.convert(adobe, url, dng, cancelled)
    try check(cancelled)
    let size = try dependencies.inspect(dng) // Reject CFA before calling LibRaw's processing stage.
    guard expectedIdentity == nil || expectedIdentity == identity else {
      throw Self.invalid("RAW 有效画面与提交操作时不同，请重试。")
    }
    let image = try dependencies.decode(dng, cancelled)
    guard image.width == size.0, image.height == size.1,
      image.samples.count == image.width * image.height * 3 else {
      throw Self.invalid("RAW 解码尺寸与有效主图不一致。")
    }
    let proxy = temporary.appendingPathComponent("proxy.tiff")
    try writeProxy(image, to: proxy, maxDimension: 1600, cancelled: cancelled)
    let thumbnail = temporary.appendingPathComponent("thumbnail.tiff")
    try writeProxy(image, to: thumbnail, maxDimension: 240, cancelled: cancelled)
    guard before == (try FileRevision(url)) else { throw Self.invalid("转换期间原始 RAW 已改变，请重试。") }
    let manifest = Manifest(identity: identity, sourceSHA256: sourceHash, width: size.0, height: size.1,
      proxySHA256: try digest(proxy, cancelled: cancelled),
      thumbnailSHA256: try digest(thumbnail, cancelled: cancelled))
    try JSONEncoder().encode(manifest).write(to: temporary.appendingPathComponent("manifest.json"), options: .atomic)
    try check(cancelled)
    try FileManager.default.removeItem(at: dng)
    try FileManager.default.moveItem(at: temporary, to: destination)
    scheduleMaintenance()
    return Entry(directory: destination, manifest: manifest)
  }

  private func cachedEntry(at directory: URL, identity: RAWProcessingIdentity,
                           cancelled: @escaping @Sendable () -> Bool, legacy: Bool = false) throws -> Entry? {
    try check(cancelled)
    let manifestURL = directory.appendingPathComponent("manifest.json")
    guard Self.isDirectory(directory), (try? FileRevision(manifestURL)) != nil,
          let data = try? Data(contentsOf: manifestURL),
          let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
          manifest.identity == identity, manifest.width > 0, manifest.height > 0,
          manifest.sourceSHA256.count == 64,
          manifest.sourceSHA256.allSatisfy({ $0.isHexDigit }) else { return nil }
    if legacy {
      let key = Self.hash(Data([identity.sourceRevision, manifest.sourceSHA256,
        identity.adobeVersion, identity.libRawVersion, identity.strategyVersion,
        identity.proxySamplingVersion].joined(separator: "\n").utf8))
      guard directory.lastPathComponent == key else { return nil }
    }
    let entry = Entry(directory: directory, manifest: manifest)
    let valid = (try? digest(entry.proxy, cancelled: cancelled)) == manifest.proxySHA256
      && (try? digest(entry.thumbnail, cancelled: cancelled)) == manifest.thumbnailSHA256
    try check(cancelled)
    return valid ? entry : nil
  }

  /// Export-only full resolution. Never publishes a full TIFF or retains the DNG.
  private func decodeForExport(identity: RAWProcessingIdentity, url: URL,
                               cancelled: @escaping @Sendable () -> Bool) throws -> LinearImage {
    let temporary = root.appendingPathComponent(".preparing-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let dng = temporary.appendingPathComponent("source.dng")
    let adobe = try dependencies.installation()
    guard adobe.version == identity.adobeVersion else {
      throw Self.invalid("Adobe 版本已改变，请重新提交导出。")
    }
    try dependencies.convert(adobe, url, dng, cancelled)
    try check(cancelled)
    let size = try dependencies.inspect(dng)
    let image = try dependencies.decode(dng, cancelled)
    guard image.width == size.0, image.height == size.1,
          image.samples.count == image.width * image.height * 3 else {
      throw Self.invalid("RAW 全尺寸结果与代理尺寸不一致。")
    }
    try verifySource(url, identity: identity, cancelled: cancelled)
    return image
  }

  /// Keeps the original coordinate grid for saved selections/crops and viewport geometry.
  /// Values come exclusively from the proxy, expanded with nearest-neighbour sampling.
  static func proxyRegion(_ proxy: LinearImage, sourceWidth: Int, sourceHeight: Int,
                          rect: PixelRect, cancelled: @Sendable () -> Bool) throws -> LinearImage {
    guard rect.x >= 0, rect.y >= 0, rect.width > 0, rect.height > 0,
          rect.x < sourceWidth, rect.y < sourceHeight,
          rect.width <= sourceWidth - rect.x, rect.height <= sourceHeight - rect.y else {
      throw Self.invalid("RAW 代理取样区域超出原片范围。")
    }
    var samples = [UInt16]()
    samples.reserveCapacity(rect.width * rect.height * 3)
    for y in rect.y..<(rect.y + rect.height) {
      if cancelled() { throw CancellationError() }
      let py = min(proxy.height - 1, y * proxy.height / sourceHeight)
      for x in rect.x..<(rect.x + rect.width) {
        let px = min(proxy.width - 1, x * proxy.width / sourceWidth)
        let offset = (py * proxy.width + px) * 3
        samples.append(contentsOf: proxy.samples[offset..<(offset + 3)])
      }
    }
    return LinearImage(width: rect.width, height: rect.height, samples: samples,
      embeddedProfileName: "Adobe RAW · 代理取样")
  }

  private func writeProxy(_ image: LinearImage, to url: URL, maxDimension: Int, cancelled: @escaping @Sendable () -> Bool) throws {
    let scale = min(1, Double(maxDimension) / Double(max(image.width, image.height)))
    let width = max(1, Int(Double(image.width) * scale))
    let height = max(1, Int(Double(image.height) * scale))
    try TIFFCodec.write(url: url, width: width, height: height, profile: nil, compression: .deflate) { rows in
      try self.check(cancelled)
      var result = [UInt16]()
      result.reserveCapacity(rows.count * width * 3)
      for y in rows {
        let sy = min(image.height - 1, y * image.height / height)
        for x in 0..<width {
          let sx = min(image.width - 1, x * image.width / width)
          let offset = (sy * image.width + sx) * 3
          result.append(contentsOf: image.samples[offset..<(offset + 3)])
        }
      }
      return result
    }
  }

  private func verifySource(_ url: URL, identity: RAWProcessingIdentity,
                            cancelled: @escaping @Sendable () -> Bool) throws {
    try check(cancelled)
    guard try FileRevision(url).key == identity.sourceRevision,
          try dependencies.installation().version == identity.adobeVersion else {
      throw Self.invalid("RAW 原片或 Adobe 版本在准备期间改变，请重试。")
    }
  }

  private func operation<T: Sendable>(url: URL, key: String,
    body: @escaping @Sendable (@escaping @Sendable () -> Bool) throws -> T) throws -> T {
    try Task.checkCancellation()
    let startingRevision = SourceImageIO.isRAW(url) ? try FileRevision(url) : nil
    let jobKey = url.standardizedFileURL.path + "|" + key + "|" + (startingRevision?.key ?? "")
    lock.lock()
    let job: RAWJob<T>
    if let existing = jobs[jobKey] as? RAWJob<T>, existing.attach() {
      job = existing
    } else {
      job = RAWJob<T>()
      jobs[jobKey] = job
      queue.async {
        let result = Result {
          let cancelled: @Sendable () -> Bool = {
          guard job.isAbandoned else { return false }
          self.lock.lock(); defer { self.lock.unlock() }
          let prefix = url.standardizedFileURL.path + "|"
          return !self.jobs.contains { $0.key.hasPrefix(prefix) && !$0.value.isAbandoned }
          }
          if startingRevision == nil {
            let fd = try self.acquireCacheLock(shared: false, cancelled: cancelled)
            defer { Self.release(fd) }
            return try body(cancelled)
          }
          try self.ensureCacheRoot()
          // Serialize every operation for the same source revision before taking a
          // slot, so queued metadata/preview/full reads cannot occupy all four slots.
          let entryName = ".entry-" + Self.hash(Data(startingRevision!.key.utf8)) + ".lock"
          let entryFD = try self.acquireNamedLock(entryName, mode: LOCK_EX, cancelled: cancelled)
          defer { Self.release(entryFD) }
          let slotFD = try self.acquirePreparationSlot(cancelled: cancelled)
          defer { Self.release(slotFD) }
          let sharedFD = try self.acquireCacheLock(shared: true, cancelled: cancelled)
          let produced = Result { try body(cancelled) }
          Self.release(sharedFD)
          return try produced.get()
        }
        // Result owns its pixels/metadata; all source and slot locks have been released.
        // Cache hits only refresh access time. Maintenance is requested by writes,
        // explicit policy changes, startup and the hourly timer, not every read.
        job.finish(result)
        self.lock.lock()
        if self.jobs[jobKey] as? RAWJob<T> === job { self.jobs.removeValue(forKey: jobKey) }
        self.lock.unlock()
      }
    }
    lock.unlock()
    defer { job.detach() }
    let value = try job.wait()
    if let startingRevision, startingRevision != (try FileRevision(url)) {
      throw Self.invalid("RAW 原片在读取期间改变，请重试。")
    }
    return value
  }
  public func scheduleMaintenance() {
    maintenanceLock.lock()
    maintenanceRequested = true
    guard !maintenanceScheduled else { maintenanceLock.unlock(); return }
    maintenanceScheduled = true
    maintenanceQueue.async {
      while true {
        self.maintenanceLock.lock()
        guard self.maintenanceRequested else {
          self.maintenanceScheduled = false
          self.maintenanceLock.unlock()
          return
        }
        self.maintenanceRequested = false
        self.maintenanceLock.unlock()
        // Wait only on the utility queue, never while occupying a preparation slot.
        // The exclusive cross-process lock protects active readers and staging files.
        if let fd = try? self.acquireCacheLock(shared: false, cancelled: { false }) {
          self.trimCache()
          Self.release(fd)
        }
      }
    }
    maintenanceLock.unlock()
  }

  /// Internal synchronization for deterministic maintenance tests, not an editing barrier.
  func waitForMaintenance() { maintenanceQueue.sync {} }

  private func check(_ cancelled: @Sendable () -> Bool) throws {
    if cancelled() { throw CancellationError() }
  }

  private struct FileRevision: Equatable {
    let size: Int64, inode: UInt64, device: Int32
    let mtime: timespec, ctime: timespec
    init(_ url: URL) throws {
      var s = stat()
      guard url.withUnsafeFileSystemRepresentation({ Darwin.lstat($0!, &s) }) == 0,
            s.st_mode & S_IFMT == S_IFREG else { throw RAWSourceService.invalid("无法读取 RAW 或缓存文件：\(url.lastPathComponent)") }
      size = s.st_size; inode = s.st_ino; device = s.st_dev; mtime = s.st_mtimespec; ctime = s.st_ctimespec
    }
    var key: String { "\(size):\(inode):\(device):\(mtime.tv_sec):\(mtime.tv_nsec):\(ctime.tv_sec):\(ctime.tv_nsec)" }
    static func == (a: Self, b: Self) -> Bool {
      a.size == b.size && a.inode == b.inode && a.device == b.device && a.mtime.tv_sec == b.mtime.tv_sec
        && a.mtime.tv_nsec == b.mtime.tv_nsec && a.ctime.tv_sec == b.ctime.tv_sec && a.ctime.tv_nsec == b.ctime.tv_nsec
    }
  }
  private func digest(_ url: URL, cancelled: @Sendable () -> Bool) throws -> String {
    try check(cancelled)
    let before = try FileRevision(url)
    if let value = digestLock.withLock({ digests[url.path] }), value.0 == before { return value.1 }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
      try check(cancelled)
      dependencies.didReadDigest(url, data.count)
      hash.update(data: data)
    }
    guard before == (try FileRevision(url)) else { throw Self.invalid("读取期间文件已改变，请重试。") }
    let result = hash.finalize().map { String(format: "%02x", $0) }.joined()
    digestLock.withLock {
      if digests.count > 512 { digests.removeAll(keepingCapacity: true) }
      digests[url.path] = (before, result)
    }
    return result
  }
  private static func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  /// Called under the exclusive cache lock, after all shared readers have drained.
  /// This process owns only 64-hex entry directories; arbitrary files are untouched.
  private func trimCache() {
    dependencies.didMaintain()
    let fm = FileManager.default
    guard let urls = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
    var entries: [(URL, Date, Int64)] = []
    for url in urls where Self.isDirectory(url) && url.lastPathComponent.count == 64 && url.lastPathComponent.allSatisfy({ $0.isHexDigit }) {
      if let data = try? Data(contentsOf: url.appendingPathComponent("manifest.json")),
         (try? JSONDecoder().decode(Manifest.self, from: data)) != nil {
        for name in ["source.dng", "full.tiff"] {
          let file = url.appendingPathComponent(name)
          if (try? FileRevision(file)) != nil { try? fm.removeItem(at: file) }
        }
      }
      // ManagedDiskCache alone collects sizes for the shared production budget.
      guard !usesManagedPolicy,
        let children = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
      let bytes = children.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
      let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
      entries.append((url, date, bytes))
    }
    if usesManagedPolicy {
      try? ManagedDiskCache.maintain(root: root.deletingLastPathComponent(), policy: .load())
      return
    }
    var total = entries.reduce(Int64(0)) { $0 + $1.2 }
    for entry in entries.sorted(by: { $0.1 < $1.1 }) where total > limit {
      if (try? fm.removeItem(at: entry.0)) != nil { total -= entry.2 }
    }
  }

  private static func isDirectory(_ url: URL) -> Bool {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeDirectory
  }
  private func ensureCacheRoot() throws {
    let fm = FileManager.default
    for directory in [root.deletingLastPathComponent(), root] {
      if (try? fm.attributesOfItem(atPath: directory.path)) != nil, !Self.isDirectory(directory) {
        throw Self.invalid("RAW 缓存目录不是安全的普通目录，请检查缓存路径。")
      }
    }
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
  }

  private static func release(_ fd: Int32) { flock(fd, LOCK_UN); Darwin.close(fd) }

  private func openLockFile(_ name: String) throws -> Int32 {
    let path = root.appendingPathComponent(name)
    let fd = path.withUnsafeFileSystemRepresentation {
      Darwin.open($0!, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
    }
    guard fd >= 0 else { throw Self.invalid("无法锁定 RAW 缓存目录。") }
    return fd
  }

  private func acquireNamedLock(_ name: String, mode: Int32,
                                cancelled: @escaping @Sendable () -> Bool) throws -> Int32 {
    let fd = try openLockFile(name)
    do {
      while flock(fd, mode | LOCK_NB) != 0 {
        guard errno == EWOULDBLOCK || errno == EAGAIN else { throw Self.invalid("RAW 缓存锁定失败。") }
        try check(cancelled)
        Thread.sleep(forTimeInterval: 0.025)
      }
      try check(cancelled)
      return fd
    } catch { Darwin.close(fd); throw error }
  }

  private func acquirePreparationSlot(cancelled: @escaping @Sendable () -> Bool) throws -> Int32 {
    var descriptors: [Int32] = []
    do {
      for slot in 0..<Self.preparationConcurrency { descriptors.append(try openLockFile(".slot-\(slot).lock")) }
      while true {
        try check(cancelled)
        for (index, fd) in descriptors.enumerated() {
          if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            for (other, descriptor) in descriptors.enumerated() where other != index { Darwin.close(descriptor) }
            return fd
          }
          guard errno == EWOULDBLOCK || errno == EAGAIN else { throw Self.invalid("RAW 并行准备槽锁定失败。") }
        }
        Thread.sleep(forTimeInterval: 0.025)
      }
    } catch { for fd in descriptors { Darwin.close(fd) }; throw error }
  }

  private func acquireCacheLock(shared: Bool, cancelled: @escaping @Sendable () -> Bool) throws -> Int32 {
    try ensureCacheRoot()
    let fd = try acquireNamedLock(".lock", mode: shared ? LOCK_SH : LOCK_EX, cancelled: cancelled)
    do {
      if !shared {
        // Exclusive maintenance excludes every source reader/converter across all
        // instances, including staging publication. All UUID stages are now stale.
        let fm = FileManager.default
        for candidate in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
          if candidate.lastPathComponent.hasPrefix(".preparing-"),
             UUID(uuidString: String(candidate.lastPathComponent.dropFirst(".preparing-".count))) != nil,
             Self.isDirectory(candidate) {
            try fm.removeItem(at: candidate)
          }
        }
      }
      return fd
    } catch { Self.release(fd); throw error }
  }

  public static func adobeInstallation() throws -> AdobeRAWInstallation {
    let bundleURL = URL(fileURLWithPath: "/Applications/Adobe DNG Converter.app", isDirectory: true)
    let executable = bundleURL.appendingPathComponent("Contents/MacOS/Adobe DNG Converter")
    guard FileManager.default.isExecutableFile(atPath: executable.path),
      let data = try? Data(contentsOf: bundleURL.appendingPathComponent("Contents/Info.plist")),
      let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
      let version = info["CFBundleShortVersionString"] as? String,
      let build = info["CFBundleVersion"] as? String else {
      throw invalid("需要安装 Adobe DNG Converter 到“应用程序”后重试。RAW 去马赛克仅使用 Adobe。")
    }
    return AdobeRAWInstallation(executable: executable, version: "\(version) (\(build))")
  }

  static func convert(_ installation: AdobeRAWInstallation, source: URL, destination: URL,
                      cancelled: @escaping @Sendable () -> Bool) throws {
    let process = Process()
    process.executableURL = try AdobeShadowBundle.executable(for: installation)
    process.arguments = ["-u", "-l", "-p0", "-dng1.1", "-d", destination.deletingLastPathComponent().path,
                         "-o", destination.lastPathComponent, source.path]
    // File-backed diagnostics avoid pipe backpressure deadlocks on verbose failures.
    let log = destination.deletingLastPathComponent().appendingPathComponent("adobe.log")
    FileManager.default.createFile(atPath: log.path, contents: nil)
    let output = try FileHandle(forWritingTo: log)
    defer { try? output.close(); try? FileManager.default.removeItem(at: log) }
    process.standardOutput = output
    process.standardError = output
    if cancelled() { throw CancellationError() }
    try process.run()
    let deadline = Date().addingTimeInterval(120)
    while process.isRunning {
      if cancelled() || Date() >= deadline {
        process.terminate()
        let killDeadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < killDeadline { Thread.sleep(forTimeInterval: 0.025) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        if cancelled() { throw CancellationError() }
        throw invalid("Adobe RAW 转换超过 120 秒，请检查原片后重试。")
      }
      Thread.sleep(forTimeInterval: 0.025)
    }
    process.waitUntilExit()
    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
      let logInput = try? FileHandle(forReadingFrom: log)
      let data = try? logInput?.read(upToCount: 4096)
      try? logInput?.close()
      let detail = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
      throw invalid("Adobe RAW 转换失败（\(process.terminationStatus)）。请检查转换器是否支持该原片后重试。\n\(detail)")
    }
    guard FileManager.default.fileExists(atPath: destination.path) else {
      throw invalid("Adobe 未生成有效 DNG，请检查原片后重试。")
    }
  }
  private static func invalid(_ message: String) -> PrintroomError { .invalid(message) }
}

private protocol RAWJobStatus: AnyObject { var isAbandoned: Bool { get } }

private final class RAWJob<T: Sendable>: RAWJobStatus, @unchecked Sendable {
  private let condition = NSCondition()
  private var consumers = 1
  private var result: Result<T, Error>?
  var isAbandoned: Bool {
    condition.lock(); defer { condition.unlock() }
    return consumers == 0
  }
  func attach() -> Bool {
    condition.lock(); defer { condition.unlock() }
    guard consumers > 0 else { return false }
    consumers += 1
    return true
  }
  func detach() { condition.lock(); consumers -= 1; condition.unlock() }
  func finish(_ value: Result<T, Error>) {
    condition.lock(); result = value; condition.broadcast(); condition.unlock()
  }
  func wait() throws -> T {
    condition.lock(); defer { condition.unlock() }
    while result == nil {
      try Task.checkCancellation()
      _ = condition.wait(until: Date().addingTimeInterval(0.025))
    }
    try Task.checkCancellation()
    return try result!.get()
  }
}
