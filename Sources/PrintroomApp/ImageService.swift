import Foundation
import PrintroomCore

/// Keeps only bounded, unadjusted preview buffers. Full-resolution reads are transient;
/// preview, thumbnail and viewport callers use separate actors so utility work does
/// not queue ahead of interactive work. Cancellation propagates from the caller into
/// the strip decoder, and canceled requests never enter the cache.
actor ImageService {
  struct CacheStatistics: Sendable {
    let entries: Int
    let bytes: Int
    let limitBytes: Int
    let hits: Int
    let misses: Int
  }
  private struct SourceIdentity: Equatable {
    let url: URL
    let modification: Date?
    let size: Int64
    let inode: UInt64
  }
  private struct Entry {
    let identity: SourceIdentity
    let dimension: Int
    let pixels: PixelBuffer
    let width: Int
    let height: Int
    let profileName: String
    var access: UInt64
    var bytes: Int { pixels.pixels.count * MemoryLayout<SIMD4<Float>>.stride }
  }
  private var entries: [Entry] = []
  private var access: UInt64 = 0
  private var hits = 0
  private var misses = 0
  private let cacheLimitBytes: Int
  private let cacheLimitEntries: Int

  init(cacheLimitBytes: Int = 64 * 1024 * 1024, cacheLimitEntries: Int = 12) {
    self.cacheLimitBytes = max(0, cacheLimitBytes)
    self.cacheLimitEntries = max(0, cacheLimitEntries)
  }

  /// Compatibility/reference path only. No full-resolution image remains cached.
  func load(_ url: URL) throws -> LinearImage {
    try Task.checkCancellation()
    let image = try autoreleasepool { try TIFFCodec.read(url: url) }
    try Task.checkCancellation()
    return image
  }

  func clear() {
    entries.removeAll(keepingCapacity: false)
    hits = 0
    misses = 0
  }

  func invalidate(_ url: URL) {
    let normalized = url.standardizedFileURL
    entries.removeAll { $0.identity.url == normalized }
  }

  func cacheStatistics() -> CacheStatistics {
    CacheStatistics(
      entries: entries.count, bytes: entries.reduce(0) { $0 + $1.bytes },
      limitBytes: cacheLimitBytes, hits: hits, misses: misses)
  }

  /// Width/height stay in TIFF-orientation-corrected source coordinates. User
  /// orientation is applied after the pipeline, independently of the input cache.
  func preview(_ url: URL) throws -> (PixelBuffer, Int, Int, String) {
    let entry = try previewEntry(url, maxDimension: 1600)
    return (entry.pixels, entry.width, entry.height, entry.profileName)
  }

  func thumbnail(_ url: URL, maxDimension: Int = 240) throws -> PixelBuffer {
    try previewEntry(url, maxDimension: maxDimension).pixels
  }
  func thumbnailSource(_ url: URL) throws -> (PixelBuffer, Int, Int) {
    let entry = try previewEntry(url, maxDimension: 240)
    return (entry.pixels, entry.width, entry.height)
  }

  /// Read only the bounding source tile required by the final crop viewport,
  /// including interpolation neighbours. Geometry runs before density processing.
  func transformedRegion(_ url: URL, geometry: CropGeometry, rect: PixelRect) throws -> PixelBuffer {
    guard rect.width > 0, rect.height > 0, rect.width <= 8_388_608 / rect.height else {
      throw PrintroomError.invalid("1:1 检查区域超过 8 百万像素，请缩小检查视口")
    }
    let sourceRect = try geometry.sourceRegion(for: rect)
    let input = try region(url, rect: sourceRect)
    return try geometry.render(input, sourceRegion: sourceRect, outputRegion: rect,
      maxDimension: max(rect.width, rect.height),
      cancelled: { Task.isCancelled })
  }

  /// A native-resolution tile in source coordinates. Regions are transient and
  /// cannot evict the small input previews needed for continuous adjustment.
  func region(_ url: URL, rect: PixelRect) throws -> PixelBuffer {
    try Task.checkCancellation()
    guard rect.width > 0, rect.height > 0,
      rect.width <= 8_388_608 / rect.height
    else { throw PrintroomError.invalid("1:1 检查区域超过 8 百万像素，请缩小检查视口") }
    let identity = try sourceIdentity(url)
    let image = try autoreleasepool { try TIFFCodec.readRegion(url: url, rect: rect) }
    try Task.checkCancellation()
    guard identity == (try sourceIdentity(url)) else {
      throw PrintroomError.invalid("读取期间源 TIFF 已改变，请重新打开照片")
    }
    return try pixelBuffer(image)
  }

  func sample(_ url: URL, rect: PixelRect, matrix: PrintDensityMatrix, frameID: UUID) throws -> (
    FilmCalibration, CalibrationDiagnostics
  ) {
    try Task.checkCancellation()
    let identity = try sourceIdentity(url)
    let metadata = try autoreleasepool { try TIFFCodec.metadata(url: url) }
    let image = try autoreleasepool { try TIFFCodec.readRegion(url: url, rect: rect) }
    let local = PixelRect(x: 0, y: 0, width: image.width, height: image.height)
    try Task.checkCancellation()
    var calibration = try Pipeline.calibrate(
      image: image, rect: local, matrix: matrix, sourceFrameID: frameID)
    calibration.selection = rect
    calibration.sourceWidth = metadata.width
    calibration.sourceHeight = metadata.height
    let diagnostics = try Pipeline.calibrationDiagnostics(image: image, rect: local)
    try Task.checkCancellation()
    guard identity == (try sourceIdentity(url)) else {
      throw PrintroomError.invalid("采样期间源 TIFF 已改变，请重新采样")
    }
    return (calibration, diagnostics)
  }

  func pixel(_ url: URL, x: Int, y: Int) throws -> SIMD3<Float> {
    try Task.checkCancellation()
    let identity = try sourceIdentity(url)
    let metadata = try autoreleasepool { try TIFFCodec.metadata(url: url) }
    let rect = PixelRect(
      x: max(0, min(metadata.width - 1, x)), y: max(0, min(metadata.height - 1, y)),
      width: 1, height: 1)
    let image = try autoreleasepool { try TIFFCodec.readRegion(url: url, rect: rect) }
    try Task.checkCancellation()
    guard identity == (try sourceIdentity(url)) else {
      throw PrintroomError.invalid("读取期间源 TIFF 已改变，请重新取样")
    }
    return image.pixel(x: 0, y: 0)
  }

  private func previewEntry(_ url: URL, maxDimension: Int) throws -> Entry {
    try Task.checkCancellation()
    guard (1...4096).contains(maxDimension) else {
      throw PrintroomError.invalid("预览长边必须在 1–4096 像素之间")
    }
    let identity = try sourceIdentity(url)
    access &+= 1
    entries.removeAll { $0.identity.url == identity.url && $0.identity != identity }
    if let index = entries.firstIndex(where: {
      $0.identity == identity && $0.dimension == maxDimension
    }) {
      hits += 1
      entries[index].access = access
      return entries[index]
    }
    misses += 1
    let metadata = try autoreleasepool { try TIFFCodec.metadata(url: url) }
    let image = try autoreleasepool { try TIFFCodec.readPreview(url: url, maxDimension: maxDimension) }
    let pixels = try pixelBuffer(image)
    try Task.checkCancellation()
    guard identity == (try sourceIdentity(url)) else {
      throw PrintroomError.invalid("读取期间源 TIFF 已改变，请重新打开照片")
    }
    let entry = Entry(
      identity: identity, dimension: maxDimension, pixels: pixels,
      width: metadata.width, height: metadata.height,
      profileName: metadata.embeddedProfileName, access: access)
    if cacheLimitEntries > 0, entry.bytes <= cacheLimitBytes {
      while !entries.isEmpty,
        entries.count >= cacheLimitEntries
          || entries.reduce(0, { $0 + $1.bytes }) + entry.bytes > cacheLimitBytes
      {
        let oldest = entries.indices.min { entries[$0].access < entries[$1].access }!
        entries.remove(at: oldest)
      }
      entries.append(entry)
    }
    return entry
  }

  private func sourceIdentity(_ url: URL) throws -> SourceIdentity {
    // resourceValues can retain stale attributes after same-path replacement.
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return SourceIdentity(
      url: url.standardizedFileURL, modification: attributes[.modificationDate] as? Date,
      size: (attributes[.size] as? NSNumber)?.int64Value ?? -1,
      inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
  }

  private func pixelBuffer(_ image: LinearImage) throws -> PixelBuffer {
    var pixels = [SIMD4<Float>]()
    pixels.reserveCapacity(image.width * image.height)
    for y in 0..<image.height {
      try Task.checkCancellation()
      for x in 0..<image.width { pixels.append(SIMD4(image.pixel(x: x, y: y), 1)) }
    }
    return PixelBuffer(width: image.width, height: image.height, pixels: pixels)
  }

  /// Legacy callers share the same immutable request, color conversion and
  /// publishing implementation as the batch queue.
  func export(
    source: URL, destination: URL, calibration: FilmCalibration, adjustments: FrameAdjustments,
    assets: AppAssets, progress: @Sendable @escaping (Double) -> Void
  ) async throws {
    let request = try ExportRequest(
      source: source, destination: destination, calibration: calibration, adjustments: adjustments)
    let result = try await ExportEngine().run(request, lut: assets.lut, p3Profile: assets.profile) {
      progress($0.fraction)
    }
    if result.wasCancelled { throw CancellationError() }
    guard result.completedCount == 1 else {
      throw PrintroomError.invalid(result.results.first?.error ?? "导出未完成")
    }
  }
}
