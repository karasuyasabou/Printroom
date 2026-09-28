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
  private struct Entry {
    let identity: SourceStamp
    let dimension: Int
    let pixels: PixelBuffer
    let width: Int
    let height: Int
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

  func clear() {
    entries.removeAll(keepingCapacity: false)
    hits = 0
    misses = 0
  }

  func cacheStatistics() -> CacheStatistics {
    CacheStatistics(
      entries: entries.count, bytes: entries.reduce(0) { $0 + $1.bytes },
      limitBytes: cacheLimitBytes, hits: hits, misses: misses)
  }

  /// Width/height stay in TIFF-orientation-corrected source coordinates. User
  /// orientation is applied after the pipeline, independently of the input cache.
  func preview(_ url: URL) throws -> (PixelBuffer, Int, Int) {
    let entry = try previewEntry(url, maxDimension: 1600)
    return (entry.pixels, entry.width, entry.height)
  }

  /// neutral-relative-008-v1: sample 0.8% of the uncropped source long edge
  /// on the shared, unadjusted nearest-sample preview grid (TIFF and RAW).
  func neutralSample(_ url: URL, sourceX: Int, sourceY: Int) throws -> PixelBuffer {
    let entry = try previewEntry(url, maxDimension: 1600)
    return Self.neutralSample(entry.pixels, sourceWidth: entry.width,
      sourceHeight: entry.height, sourceX: sourceX, sourceY: sourceY)
  }

  nonisolated static func neutralSample(_ preview: PixelBuffer, sourceWidth: Int,
    sourceHeight: Int, sourceX: Int, sourceY: Int) -> PixelBuffer {
    let side = max(1, Int((Double(max(preview.width, preview.height)) * 0.008).rounded()))
    let x = max(0, min(preview.width - 1, Int(floor(Double(sourceX) * Double(preview.width) / Double(sourceWidth)))))
    let y = max(0, min(preview.height - 1, Int(floor(Double(sourceY) * Double(preview.height) / Double(sourceHeight)))))
    let left = max(0, x - side / 2), top = max(0, y - side / 2)
    let right = min(preview.width, x - side / 2 + side)
    let bottom = min(preview.height, y - side / 2 + side)
    var pixels: [SIMD4<Float>] = []
    for row in top..<bottom {
      pixels.append(contentsOf: preview.pixels[(row * preview.width + left)..<(row * preview.width + right)])
    }
    return PixelBuffer(width: right - left, height: bottom - top, pixels: pixels)
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
    let identity = try SourceStamp(url: url)
    let image = try autoreleasepool { try SourceImageIO.readRegion(url: url, rect: rect) }
    try Task.checkCancellation()
    guard identity == (try SourceStamp(url: url)) else {
      throw PrintroomError.invalid("读取期间源图像已改变，请重新打开照片")
    }
    return try pixelBuffer(image)
  }

  func sample(_ url: URL, rect: PixelRect, matrix: PrintDensityMatrix, frameID: UUID, cmosMatrix: MatrixPreset = .identity) throws -> FilmCalibration {
    try Task.checkCancellation()
    let identity = try SourceStamp(url: url)
    let metadata = try autoreleasepool { try SourceImageIO.metadata(url: url) }
    let image = try autoreleasepool { try SourceImageIO.readRegion(url: url, rect: rect) }
    let local = PixelRect(x: 0, y: 0, width: image.width, height: image.height)
    try Task.checkCancellation()
    var calibration = try Pipeline.calibrate(
      image: image, rect: local, matrix: matrix, sourceFrameID: frameID, cmosMatrix: cmosMatrix)
    calibration.selection = rect
    calibration.sourceWidth = metadata.width
    calibration.sourceHeight = metadata.height
    try Task.checkCancellation()
    guard identity == (try SourceStamp(url: url)) else {
      throw PrintroomError.invalid("采样期间源图像已改变，请重新采样")
    }
    return calibration
  }

  private func previewEntry(_ url: URL, maxDimension: Int) throws -> Entry {
    try Task.checkCancellation()
    guard (1...4096).contains(maxDimension) else {
      throw PrintroomError.invalid("预览长边必须在 1–4096 像素之间")
    }
    let identity = try SourceStamp(url: url)
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
    let metadata = try autoreleasepool { try SourceImageIO.metadata(url: url) }
    let image = try autoreleasepool { try SourceImageIO.readPreview(url: url, maxDimension: maxDimension) }
    let pixels = try pixelBuffer(image)
    try Task.checkCancellation()
    guard identity == (try SourceStamp(url: url)) else {
      throw PrintroomError.invalid("读取期间源图像已改变，请重新打开照片")
    }
    let entry = Entry(
      identity: identity, dimension: maxDimension, pixels: pixels,
      width: metadata.width, height: metadata.height, access: access)
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

  private func pixelBuffer(_ image: LinearImage) throws -> PixelBuffer {
    var pixels = [SIMD4<Float>]()
    pixels.reserveCapacity(image.width * image.height)
    for y in 0..<image.height {
      try Task.checkCancellation()
      for x in 0..<image.width { pixels.append(SIMD4(image.pixel(x: x, y: y), 1)) }
    }
    return PixelBuffer(width: image.width, height: image.height, pixels: pixels)
  }

}
