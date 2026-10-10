import CLibDeflate
import Darwin
import Foundation
import zlib

public struct TIFFMetadata: Sendable {
  public let width: Int, height: Int
  public let embeddedProfileName: String
}

public enum TIFFWriteError: LocalizedError, Equatable {
  case destinationExists(String)
  public var errorDescription: String? {
    switch self {
    case .destinationExists(let name): "目标已存在，禁止覆盖 TIFF：\(name)"
    }
  }
}

/// Raw sample I/O: ICC metadata never participates in decoding or encoding.
/// Reads classic and BigTIFF stripped RGB UInt16 TIFF (uncompressed, LZW or Deflate).
public enum TIFFCodec {
  public static func read(url: URL) throws -> LinearImage {
    guard url.isFileURL else { throw invalid("TIFF 必须是本地文件。") }
    let reader = try TIFFReader(url: url)
    defer { try? reader.handle.close() }
    return try reader.readImage()
  }

  public static func metadata(url: URL) throws -> TIFFMetadata {
    let reader = try TIFFReader(url: url)
    defer { try? reader.handle.close() }
    return try reader.metadata()
  }

  /// Nearest original samples using the same positions as LinearImage.preview,
  /// decoded a strip at a time without retaining full-resolution UInt16 arrays.
  public static func readPreview(url: URL, maxDimension: Int,
    cancelled: @escaping @Sendable () -> Bool = { false }) throws -> LinearImage {
    guard maxDimension > 0 else { throw invalid("预览尺寸必须大于零。") }
    let reader = try TIFFReader(url: url)
    defer { try? reader.handle.close() }
    return try reader.readImage(maxDimension: maxDimension, cancelled: cancelled)
  }

  /// The rectangle uses TIFF-orientation-corrected coordinates; user direction
  /// changes are separate. Unneeded strips are not decoded.
  public static func readRegion(url: URL, rect: PixelRect) throws -> LinearImage {
    let reader = try TIFFReader(url: url)
    defer { try? reader.handle.close() }
    return try reader.readImage(region: rect)
  }

  /// Requests bounded, contiguous, top-to-bottom RGB rows. The caller owns
  /// quantization and cancellation; any thrown error aborts and removes the temp.
  /// No alpha, no color conversion, exact supplied ICC bytes. Deflate has one
  /// independent zlib stream per strip; metadata is finalized before publication.
  public static func write(
    url: URL, width: Int, height: Int, profile: Data?, compression: TIFFCompression = .none,
    rows: (Range<Int>) throws -> [UInt16]
  ) throws {
    guard url.isFileURL, width > 0, height > 0,
      width <= Int(UInt32.max), height <= Int(UInt32.max),
      (profile == nil || !profile!.isEmpty), (profile?.count ?? 0) <= Int(UInt32.max)
    else {
      throw invalid("TIFF 尺寸或 ICC 数据无效。")
    }
    let rowBytes = UInt64(width) * 6
    // Divide first, so even hostile Int-sized dimensions cannot overflow.
    guard UInt64(height) <= UInt64(UInt32.max) / rowBytes else {
      throw invalid("输出超过 classic TIFF 的 4 GiB 限制。")
    }
    try requireAbsent(url)
    let rowsPerStrip = max(1, min(32, 2_097_152 / Int(rowBytes)))
    let stripCount = (height - 1) / rowsPerStrip + 1
    var byteCounts = (0..<stripCount).map {
      UInt32(min(rowsPerStrip, height - $0 * rowsPerStrip) * Int(rowBytes))
    }
    var entries: [TIFFWriteEntry] = [
      .long(256, UInt32(width)), .long(257, UInt32(height)),
      .shorts(258, [16, 16, 16]), .shorts(259, [compression == .none ? 1 : 8]),
      .shorts(262, [2]), .longs(273, [UInt32](repeating: 0, count: stripCount)),
      .shorts(274, [1]), .shorts(277, [3]), .long(278, UInt32(rowsPerStrip)),
      .longs(279, byteCounts), .shorts(284, [1]), .shorts(339, [1, 1, 1]),
    ]
    if let profile {
      entries.append(TIFFWriteEntry(tag: 34675, type: 7, count: UInt32(profile.count), payload: profile))
    }
    let metadataSize = try makeHeader(entries).count
    let end = UInt64(metadataSize) + rowBytes * UInt64(height)
    guard end <= UInt64(UInt32.max) else {
      throw invalid("输出超过 classic TIFF 的 4 GiB 限制。")
    }
    // One compressor and bounded output buffer per writer, never shared across exports.
    let deflater = compression == .deflate
      ? try StripDeflater(capacity: rowsPerStrip * Int(rowBytes)) : nil
    defer { withExtendedLifetime(deflater) {} }
    var offsets = [UInt32](repeating: 0, count: stripCount)
    let header = try makeHeader(entries)
    let temporary = url.deletingLastPathComponent()
      .appendingPathComponent(".printroom-\(UUID().uuidString).tiff.tmp")
    let fd = temporary.withUnsafeFileSystemRepresentation { path in
      Darwin.open(path!, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    }
    guard fd >= 0 else { throw fileError("无法创建 TIFF 临时文件", code: errno) }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer {
      try? handle.close()
      try? FileManager.default.removeItem(at: temporary)
    }
    try handle.write(contentsOf: header)
    for (strip, start) in stride(from: 0, to: height, by: rowsPerStrip).enumerated() {
      try autoreleasepool {
        try Task.checkCancellation()
        let range = start..<min(height, start + rowsPerStrip)
        var samples = try rows(range)
        guard samples.count == range.count * width * 3 else {
          throw invalid("TIFF 行回调返回的 RGB 样本数量不正确。")
        }
        // Native Apple Silicon is little endian; keep the file contract
        // explicit for any future big-endian host too.
        if UInt16(littleEndian: 1) != 1 {
          for i in samples.indices { samples[i] = samples[i].littleEndian }
        }
        let encoded: Data
        if let deflater {
          encoded = try PerformanceTrace.measure("tiff.deflate") {
            try samples.withUnsafeBytes { try deflater.compress($0) }
          }
        } else {
          encoded = PerformanceTrace.measure("tiff.pack_bytes") { samples.withUnsafeBytes { Data($0) } }
        }
        let offset = try handle.offset()
        guard offset + UInt64(encoded.count) <= UInt64(UInt32.max) else {
          throw invalid("输出超过 classic TIFF 的 4 GiB 限制。")
        }
        offsets[strip] = UInt32(offset)
        byteCounts[strip] = UInt32(encoded.count)
        try PerformanceTrace.measure("tiff.file_write") { try handle.write(contentsOf: encoded) }
      }
    }
    entries[5] = .longs(273, offsets)
    entries[9] = .longs(279, byteCounts)
    try handle.seek(toOffset: 0)
    try handle.write(contentsOf: makeHeader(entries))
    try Task.checkCancellation()
    let publishTrace = PerformanceTrace.begin()
    try handle.synchronize()
    try handle.close()
    try Task.checkCancellation()
    // RENAME_EXCL is an atomic no-replace operation, including a destination
    // created by another process after the initial check (or a dangling link).
    let result = temporary.withUnsafeFileSystemRepresentation { source in
      url.withUnsafeFileSystemRepresentation { destination in
        renamex_np(source!, destination!, UInt32(RENAME_EXCL))
      }
    }
    PerformanceTrace.end("tiff.sync_publish", publishTrace)
    guard result == 0 else {
      if errno == EEXIST { throw TIFFWriteError.destinationExists(url.lastPathComponent) }
      throw fileError("无法发布 TIFF（目标可能已存在）", code: errno)
    }
  }

  private static func requireAbsent(_ url: URL) throws {
    var status = stat()
    let result = url.withUnsafeFileSystemRepresentation { lstat($0!, &status) }
    if result == 0 { throw TIFFWriteError.destinationExists(url.lastPathComponent) }
    if errno != ENOENT { throw fileError("无法检查 TIFF 目标", code: errno) }
  }

  private final class StripDeflater {
    private let compressor: OpaquePointer
    private let output: UnsafeMutableRawPointer
    private let capacity: Int
    #if PRINTROOM_PERFORMANCE_TRACE
    private let zlibLevel: Int32?
    #endif

    init(capacity inputCapacity: Int) throws {
      var level: Int32 = 1
      #if PRINTROOM_PERFORMANCE_TRACE
      let choice = ProcessInfo.processInfo.environment["PRINTROOM_DEFLATE_BENCH"] ?? "libdeflate1"
      zlibLevel = choice.hasPrefix("zlib") ? Int32(choice.dropFirst(4)) : nil
      if choice.hasPrefix("libdeflate"), let selected = Int32(choice.dropFirst(10)),
        (1...12).contains(selected) { level = selected }
      #endif
      guard let compressor = libdeflate_alloc_compressor(level) else {
        throw invalid("无法创建 TIFF Deflate 压缩器。")
      }
      self.compressor = compressor
      capacity = max(Int(libdeflate_zlib_compress_bound(compressor, inputCapacity)),
        Int(compressBound(uLong(inputCapacity))))
      output = .allocate(byteCount: capacity, alignment: 64)
    }

    deinit {
      output.deallocate()
      libdeflate_free_compressor(compressor)
    }

    func compress(_ bytes: UnsafeRawBufferPointer) throws -> Data {
      let count: Int
      #if PRINTROOM_PERFORMANCE_TRACE
      if let level = zlibLevel {
        var length = uLongf(capacity)
        let status = compress2(output.assumingMemoryBound(to: Bytef.self), &length,
          bytes.bindMemory(to: Bytef.self).baseAddress!, uLong(bytes.count), level)
        guard status == Z_OK else { throw invalid("TIFF Deflate 压缩失败 (zlib \(status))。") }
        count = Int(length)
      } else {
        count = libdeflate_zlib_compress(compressor, bytes.baseAddress!, bytes.count, output, capacity)
      }
      #else
      count = libdeflate_zlib_compress(compressor, bytes.baseAddress!, bytes.count, output, capacity)
      #endif
      guard count > 0 else { throw invalid("TIFF Deflate 压缩缓冲不足。") }
      // FileHandle.write consumes this view synchronously before the next strip.
      // The writer retains this object until all strip views have been consumed.
      return Data(bytesNoCopy: output, count: count, deallocator: .none)
    }
  }

  private static func makeHeader(_ entries: [TIFFWriteEntry]) throws -> Data {
    var directory = Data([0x49, 0x49, 42, 0, 8, 0, 0, 0])
    directory.appendLE(UInt16(entries.count))
    let extraStart = 8 + 2 + entries.count * 12 + 4
    var extra = Data()
    for entry in entries {
      directory.appendLE(entry.tag)
      directory.appendLE(entry.type)
      directory.appendLE(entry.count)
      if entry.payload.count <= 4 {
        directory.append(entry.payload)
        directory.append(Data(repeating: 0, count: 4 - entry.payload.count))
      } else {
        guard
          UInt64(extraStart) + UInt64(extra.count) + UInt64(entry.payload.count) + 1
            <= UInt64(UInt32.max)
        else {
          throw invalid("TIFF 元数据超过 classic TIFF 容量。")
        }
        directory.appendLE(UInt32(extraStart + extra.count))
        extra.append(entry.payload)
        if extra.count % 2 != 0 { extra.append(0) }
      }
    }
    directory.appendLE(UInt32(0))  // One IFD only.
    directory.append(extra)
    return directory
  }
}

private func invalid(_ message: String) -> PrintroomError { .invalid(message) }

private func fileError(_ message: String, code: Int32) -> PrintroomError {
  invalid("\(message)：\(String(cString: strerror(code))) (\(code))")
}

private struct TIFFWriteEntry {
  let tag: UInt16
  let type: UInt16
  let count: UInt32
  let payload: Data

  static func long(_ tag: UInt16, _ value: UInt32) -> Self { longs(tag, [value]) }
  static func longs(_ tag: UInt16, _ values: [UInt32]) -> Self {
    var data = Data()
    for value in values { data.appendLE(value) }
    return Self(tag: tag, type: 4, count: UInt32(values.count), payload: data)
  }
  static func shorts(_ tag: UInt16, _ values: [UInt16]) -> Self {
    var data = Data()
    for value in values { data.appendLE(value) }
    return Self(tag: tag, type: 3, count: UInt32(values.count), payload: data)
  }
}

extension Data {
  fileprivate mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
    var value = value.littleEndian
    Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
  }
  fileprivate func uint16(_ offset: Int, little: Bool) -> UInt16 {
    let value = withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) }
    return little ? UInt16(littleEndian: value) : UInt16(bigEndian: value)
  }
  fileprivate func uint32(_ offset: Int, little: Bool) -> UInt32 {
    let value = withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
    return little ? UInt32(littleEndian: value) : UInt32(bigEndian: value)
  }
  fileprivate func uint64(_ offset: Int, little: Bool) -> UInt64 {
    let value = withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self) }
    return little ? UInt64(littleEndian: value) : UInt64(bigEndian: value)
  }

}

private final class TIFFReader {
  struct Entry {
    let type: UInt16
    let count: Int
    let value: Data
  }
  let handle: FileHandle
  private let fileSize: UInt64
  private let little: Bool
  private let big: Bool
  private var entries: [UInt16: Entry] = [:]

  init(url: URL) throws {
    let file = try FileHandle(forReadingFrom: url)
    do {
      fileSize = try file.seekToEnd()
      try file.seek(toOffset: 0)
      guard let header = try file.read(upToCount: 8), header.count == 8 else {
        throw invalid("TIFF 文件头不完整。")
      }
      guard header.prefix(2) == Data([0x49, 0x49]) || header.prefix(2) == Data([0x4d, 0x4d]) else {
        throw invalid("不是 TIFF 文件。")
      }
      little = header[0] == 0x49
      let version = header.uint16(2, little: little)
      guard version == 42 || version == 43 else {
        throw invalid("TIFF 文件头版本无效（\(version)）。")
      }
      big = version == 43
      handle = file
      let ifd: UInt64
      if big {
        guard header.uint16(4, little: little) == 8,
          header.uint16(6, little: little) == 0 else {
          throw invalid("BigTIFF 文件头无效：偏移宽度必须为 8，保留字段必须为 0。")
        }
        ifd = try readBytes(at: 8, count: 8).uint64(0, little: little)
      } else {
        ifd = UInt64(header.uint32(4, little: little))
      }
      let countSize = big ? 8 : 2
      let entrySize = big ? 20 : 12
      let inlineSize = big ? 8 : 4
      guard ifd >= (big ? 16 : 8) else { throw invalid("TIFF IFD 偏移无效。") }
      let countBytes = try readBytes(at: ifd, count: countSize)
      let count64 = big ? countBytes.uint64(0, little: little)
        : UInt64(countBytes.uint16(0, little: little))
      // Tags are UInt16 and duplicates are forbidden. Bound before allocation.
      guard count64 <= 65_536 else { throw invalid("TIFF IFD 标签数量无效。") }
      let count = Int(count64)
      let directory = try readBytes(at: ifd + UInt64(countSize), count: count * entrySize + inlineSize)
      for i in 0..<count {
        let base = i * entrySize
        let tag = directory.uint16(base, little: little)
        guard entries[tag] == nil else { throw invalid("TIFF 包含重复的标签 \(tag)。") }
        let valueCount = big ? directory.uint64(base + 4, little: little)
          : UInt64(directory.uint32(base + 4, little: little))
        guard let valueCount = Int(exactly: valueCount) else {
          throw invalid("TIFF 标签数量超出可寻址范围。")
        }
        let valueStart = base + (big ? 12 : 8)
        entries[tag] = Entry(
          type: directory.uint16(base + 2, little: little), count: valueCount,
          value: directory.subdata(in: valueStart..<(valueStart + inlineSize)))
      }
      let next = big ? directory.uint64(count * entrySize, little: little)
        : UInt64(directory.uint32(count * entrySize, little: little))
      guard next == 0 else { throw invalid("暂不支持多页 TIFF。") }
    } catch {
      try? file.close()
      throw error
    }
  }

  private func layout() throws -> Layout {
    let width = try scalar(256)
    let height = try scalar(257)
    guard width > 0, height > 0,
      width <= Int(UInt32.max), height <= Int(UInt32.max),
      width <= Int.max / 6, height <= Int.max / (width * 6)
    else {
      throw invalid("TIFF 尺寸无效或样本超过可寻址范围。")
    }
    guard try scalar(262) == 2, try scalar(277) == 3,
      try integers(258, expectedCount: 3) == [16, 16, 16],
      try integers(339, expectedCount: 3, defaultValue: [1, 1, 1]) == [1, 1, 1],
      try scalar(284, defaultValue: 1) == 1, entries[338] == nil
    else {
      throw invalid("仅支持无 alpha、chunky、3 通道无符号 16-bit RGB TIFF。")
    }
    guard entries[322] == nil, entries[323] == nil, entries[324] == nil, entries[325] == nil else {
      throw invalid("暂不支持 tiled TIFF。")
    }
    let compression = try scalar(259, defaultValue: 1)
    let predictor = try scalar(317, defaultValue: 1)
    let orientation = try scalar(274, defaultValue: 1)
    guard [1, 5, 8, 32946].contains(compression) else {
      throw invalid("暂不支持 TIFF 压缩 \(compression)，可读取无压缩、LZW 和 Deflate。")
    }
    guard (1...2).contains(predictor), (1...8).contains(orientation),
      try scalar(266, defaultValue: 1) == 1
    else {
      throw invalid("不支持的 TIFF predictor、orientation 或 FillOrder。")
    }
    let rowsPerStrip = try scalar(278, defaultValue: Int(UInt32.max))
    guard rowsPerStrip > 0 else { throw invalid("TIFF RowsPerStrip 必须大于零。") }
    let stripCount = (height - 1) / rowsPerStrip + 1
    let offsets = try integers(273, expectedCount: stripCount)
    let counts = try integers(279, expectedCount: stripCount)
    // Validate every range before allocating the full image.
    for strip in 0..<stripCount {
      let count = counts[strip]
      let expected = min(rowsPerStrip, height - strip * rowsPerStrip) * width * 6
      guard count > 0, offsets[strip] >= (big ? 16 : 8),
        UInt64(offsets[strip]) <= fileSize,
        UInt64(count) <= fileSize - UInt64(offsets[strip]),
        compression != 1 || count == expected
      else {
        throw invalid("TIFF strip 范围或样本字节数无效。")
      }
    }
    return Layout(
      width: width, height: height, compression: compression,
      predictor: predictor, orientation: orientation, rowsPerStrip: rowsPerStrip,
      offsets: offsets, counts: counts)
  }

  private struct Layout {
    let width: Int, height: Int, compression: Int, predictor: Int, orientation: Int
    let rowsPerStrip: Int, offsets: [Int], counts: [Int]
    var outputWidth: Int { orientation >= 5 ? height : width }
    var outputHeight: Int { orientation >= 5 ? width : height }
    func source(x: Int, y: Int) -> (x: Int, y: Int) {
      switch orientation {
      case 2: (width - 1 - x, y)
      case 3: (width - 1 - x, height - 1 - y)
      case 4: (x, height - 1 - y)
      case 5: (y, x)
      case 6: (y, height - 1 - x)
      case 7: (width - 1 - y, height - 1 - x)
      case 8: (width - 1 - y, x)
      default: (x, y)
      }
    }
  }

  func metadata() throws -> TIFFMetadata {
    let info = try layout()
    return TIFFMetadata(
      width: info.outputWidth, height: info.outputHeight,
      embeddedProfileName: try embeddedProfileName())
  }

  func readImage(region: PixelRect? = nil, maxDimension: Int? = nil,
    cancelled: @escaping @Sendable () -> Bool = { false }) throws -> LinearImage {
    try Task.checkCancellation()
    if cancelled() { throw CancellationError() }
    let info = try layout()
    let region = region ?? PixelRect(x: 0, y: 0, width: info.outputWidth, height: info.outputHeight)
    guard region.x >= 0, region.y >= 0, region.width > 0, region.height > 0,
      region.width <= info.outputWidth, region.height <= info.outputHeight,
      region.x <= info.outputWidth - region.width, region.y <= info.outputHeight - region.height
    else { throw invalid("TIFF 读取选区超出原图边界。") }
    let scale = min(
      1,
      Double(maxDimension ?? max(region.width, region.height))
        / Double(max(region.width, region.height)))
    let outputWidth = max(1, Int(Double(region.width) * scale))
    let outputHeight = max(1, Int(Double(region.height) * scale))
    let profileName = try embeddedProfileName()
    // A strip intersects either output rows (orientations 1–4) or columns (5–8).
    // Index it before decoding so a small source region never decodes unrelated strips.
    let transposed = info.orientation >= 5
    var stripIndices = [[Int]](repeating: [], count: info.offsets.count)
    for index in 0..<(transposed ? outputWidth : outputHeight) {
      let x = region.x + (transposed ? Int(UInt64(index) * UInt64(region.width) / UInt64(outputWidth)) : 0)
      let y = region.y + (transposed ? 0 : Int(UInt64(index) * UInt64(region.height) / UInt64(outputHeight)))
      let raw = info.source(x: x, y: y)
      stripIndices[raw.y / info.rowsPerStrip].append(index)
    }
    var samples = [UInt16](repeating: 0, count: outputWidth * outputHeight * 3)
    try samples.withUnsafeMutableBufferPointer { output in
      for strip in info.offsets.indices where !stripIndices[strip].isEmpty {
        try autoreleasepool {
          try Task.checkCancellation()
          if cancelled() { throw CancellationError() }
          let firstRow = strip * info.rowsPerStrip
          let rowCount = min(info.rowsPerStrip, info.height - firstRow)
          let expected = rowCount * info.width * 6
          var bytes = try PerformanceTrace.measure("tiff.strip_read") { try readBytes(at: UInt64(info.offsets[strip]), count: info.counts[strip]) }
          switch info.compression {
          case 5: bytes = try PerformanceTrace.measure("tiff.lzw_decode") { try decodeLZWStrip(bytes, expected: expected, cancelled: cancelled) }
          case 8, 32946: bytes = try PerformanceTrace.measure("tiff.inflate") { try inflateStrip(bytes, expected: expected) }
          default: break
          }
          let samplingTrace = PerformanceTrace.begin()
          defer { PerformanceTrace.end("tiff.sample_copy_predictor", samplingTrace) }
          if info.orientation == 1, info.predictor == 1, little,
            region.x == 0, region.y == 0, outputWidth == info.width,
            outputHeight == info.height
          {
            _ = bytes.copyBytes(
              to: UnsafeMutableRawBufferPointer(
                start: output.baseAddress!.advanced(by: firstRow * info.width * 3), count: expected)
            )
            return
          }
          // Horizontal prediction is reconstructed in the original raw row order,
          // before selecting/resizing/orienting pixels; UInt16 overflow is specified.
          if info.predictor == 2 {
            bytes.withUnsafeMutableBytes { raw in
              for row in 0..<rowCount {
                var previous = SIMD3<UInt16>(repeating: 0)
                for x in 0..<info.width {
                  for channel in 0..<3 {
                    let offset = (row * info.width + x) * 6 + channel * 2
                    let stored = raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
                    let value =
                      (little ? UInt16(littleEndian: stored) : UInt16(bigEndian: stored))
                      &+ previous[channel]
                    previous[channel] = value
                    raw.storeBytes(
                      of: little ? value.littleEndian : value.bigEndian,
                      toByteOffset: offset, as: UInt16.self)
                  }
                }
              }
            }
          }
          bytes.withUnsafeBytes { raw in
            for index in stripIndices[strip] {
              for other in 0..<(transposed ? outputHeight : outputWidth) {
                let x = transposed ? index : other
                let y = transposed ? other : index
                let normalizedX = region.x + Int(UInt64(x) * UInt64(region.width) / UInt64(outputWidth))
                let normalizedY = region.y + Int(UInt64(y) * UInt64(region.height) / UInt64(outputHeight))
                let source = info.source(x: normalizedX, y: normalizedY)
                let offset = ((source.y - firstRow) * info.width + source.x) * 6
                let target = (y * outputWidth + x) * 3
                for channel in 0..<3 {
                  let value = raw.loadUnaligned(
                    fromByteOffset: offset + channel * 2, as: UInt16.self)
                  output[target + channel] =
                    little ? UInt16(littleEndian: value) : UInt16(bigEndian: value)
                }
              }
            }
          }
        }
      }
    }
    try Task.checkCancellation()
    return LinearImage(
      width: outputWidth, height: outputHeight, samples: samples,
      embeddedProfileName: profileName)
  }

  private func readBytes(at offset: UInt64, count: Int) throws -> Data {
    guard count >= 0, offset <= UInt64(Int64.max), offset <= fileSize,
      UInt64(count) <= UInt64(Int64.max) - offset, UInt64(count) <= fileSize - offset else {
      throw invalid("TIFF 数据超出文件边界。")
    }
    // pread fills Swift-owned storage directly. FileHandle.read creates
    // autoreleased NSData objects that otherwise accumulate on long-lived actor
    // executors while loading a roll or exporting it.
    var result = Data(count: count)
    try result.withUnsafeMutableBytes { buffer in
      var completed = 0
      while completed < count {
        try Task.checkCancellation()
        let n = Darwin.pread(
          handle.fileDescriptor, buffer.baseAddress!.advanced(by: completed),
          count - completed, off_t(offset) + off_t(completed))
        if n < 0 && errno == EINTR { continue }
        guard n > 0 else {
          if n < 0 { throw fileError("无法读取 TIFF", code: errno) }
          throw invalid("TIFF 文件意外截断。")
        }
        completed += n
      }
    }
    return result
  }

  private func payload(_ entry: Entry, unit: Int) throws -> Data {
    guard entry.count > 0, entry.count <= Int.max / unit else {
      throw invalid("TIFF 标签数量无效。")
    }
    let size = entry.count * unit
    if size <= entry.value.count { return entry.value.prefix(size) }
    let offset = big ? entry.value.uint64(0, little: little)
      : UInt64(entry.value.uint32(0, little: little))
    return try readBytes(at: offset, count: size)
  }

  private func integers(_ tag: UInt16, expectedCount: Int, defaultValue: [Int]? = nil) throws
    -> [Int]
  {
    guard let entry = entries[tag] else {
      if let defaultValue { return defaultValue }
      throw invalid("TIFF 缺少标签 \(tag)。")
    }
    guard entry.count == expectedCount, (entry.type == 3 || entry.type == 4 || (big && entry.type == 16)) else {
      throw invalid("TIFF 标签 \(tag) 的类型或数量无效。")
    }
    let unit = entry.type == 3 ? 2 : entry.type == 4 ? 4 : 8
    let bytes = try payload(entry, unit: unit)
    return try (0..<entry.count).map {
      let value = unit == 2 ? UInt64(bytes.uint16($0 * unit, little: little))
        : unit == 4 ? UInt64(bytes.uint32($0 * unit, little: little))
        : bytes.uint64($0 * unit, little: little)
      guard let result = Int(exactly: value) else {
        throw invalid("TIFF 标签 \(tag) 超出可寻址范围。")
      }
      return result
    }
  }

  private func scalar(_ tag: UInt16, defaultValue: Int? = nil) throws -> Int {
    try integers(tag, expectedCount: 1, defaultValue: defaultValue.map { [$0] })[0]
  }

  /// TIFF 6.0 LZW: MSB-first codes, 9–12 bits, early width changes and a
  /// fresh dictionary per strip. Prefix chains keep dictionary storage bounded;
  /// decoded bytes can never exceed the strip's declared RGB sample count.
  private func decodeLZWStrip(_ source: Data, expected: Int,
    cancelled: @escaping @Sendable () -> Bool) throws -> Data {
    var result = Data(count: expected)
    var prefixes = [Int](repeating: 0, count: 4096)
    var suffixes = [UInt8](repeating: 0, count: 4096)
    var stack = [UInt8](repeating: 0, count: 4096)
    try result.withUnsafeMutableBytes { output in
      try source.withUnsafeBytes { input in
        let bytes = input.bindMemory(to: UInt8.self)
        let target = output.bindMemory(to: UInt8.self)
        var offset = 0, bufferedBits = 0, bits: UInt32 = 0
        var width = 9, next = 258, previous: Int?
        var started = false, written = 0, codeCount = 0
        while true {
          if codeCount % 4096 == 0 {
            try Task.checkCancellation()
            if cancelled() { throw CancellationError() }
          }
          codeCount += 1
          while bufferedBits < width {
            guard offset < bytes.count else { throw invalid("TIFF LZW 数据截断或缺少结束码。") }
            bits = (bits << 8) | UInt32(bytes[offset])
            offset += 1
            bufferedBits += 8
          }
          bufferedBits -= width
          let code = Int((bits >> bufferedBits) & UInt32((1 << width) - 1))
          bits &= (1 << bufferedBits) - 1
          guard started || code == 256 else { throw invalid("TIFF LZW 缺少初始清除码。") }
          if code == 256 {
            started = true
            width = 9
            next = 258
            previous = nil
            continue
          }
          if code == 257 {
            guard written == expected else { throw invalid("TIFF LZW 解压样本数量不符。") }
            return
          }
          let repeated = code == next && previous != nil
          guard (code < next && (code < 256 || previous != nil)) || repeated else {
            throw invalid("TIFF LZW 字典码无效。")
          }
          var cursor = repeated ? previous! : code
          var length = 0
          while cursor >= 258 {
            guard length < stack.count else { throw invalid("TIFF LZW 字典链无效。") }
            stack[length] = suffixes[cursor]
            length += 1
            cursor = prefixes[cursor]
          }
          guard cursor < 256, length < stack.count else { throw invalid("TIFF LZW 字典码无效。") }
          let first = UInt8(cursor)
          stack[length] = first
          length += 1
          let count = length + (repeated ? 1 : 0)
          guard count <= expected - written else { throw invalid("TIFF LZW 解压样本数量超出条带范围。") }
          for i in stride(from: length - 1, through: 0, by: -1) {
            target[written] = stack[i]
            written += 1
          }
          if repeated {
            target[written] = first
            written += 1
          }
          if let previous, next < 4096 {
            prefixes[next] = previous
            suffixes[next] = first
            next += 1
            // TIFF changes one code earlier than GIF's LZW variant.
            if width < 12, next == (1 << width) - 1 { width += 1 }
          }
          previous = code
        }
      }
    }
    return result
  }

  private func inflateStrip(_ source: Data, expected: Int) throws -> Data {
    var result = Data(count: expected)
    var destinationLength = uLongf(expected)
    var sourceLength = uLong(source.count)
    let code = result.withUnsafeMutableBytes { destination in
      source.withUnsafeBytes { input in
        uncompress2(
          destination.bindMemory(to: Bytef.self).baseAddress!, &destinationLength,
          input.bindMemory(to: Bytef.self).baseAddress!, &sourceLength)
      }
    }
    guard code == Z_OK, destinationLength == expected, sourceLength == source.count else {
      throw invalid("TIFF Deflate 数据损坏或解压样本数量不符 (zlib \(code))。")
    }
    return result
  }

  private func embeddedProfileName() throws -> String {
    guard let entry = entries[34675] else { return "无嵌入 ICC" }
    guard entry.type == 1 || entry.type == 7 else { throw invalid("TIFF ICC 标签类型无效。") }
    let profile = try payload(entry, unit: 1)
    return profileDescription(profile) ?? "嵌入 ICC（描述不可用）"
  }
}

/// ICC v2 'desc' and v4 'mluc' descriptions, read as metadata only.
private func profileDescription(_ data: Data) -> String? {
  guard data.count >= 132 else { return nil }
  let count = Int(data.uint32(128, little: false))
  guard count <= (data.count - 132) / 12 else { return nil }
  for i in 0..<count {
    let record = 132 + i * 12
    guard data.uint32(record, little: false) == 0x6465_7363 else { continue }
    let offset = Int(data.uint32(record + 4, little: false))
    let size = Int(data.uint32(record + 8, little: false))
    guard offset <= data.count, size <= data.count - offset, size >= 12 else { return nil }
    let tag = data.subdata(in: offset..<(offset + size))
    let type = tag.uint32(0, little: false)
    if type == 0x6465_7363 {
      let length = Int(tag.uint32(8, little: false))
      guard length > 0, length <= tag.count - 12 else { return nil }
      let bytes = tag[12..<(12 + length)].prefix { $0 != 0 }
      return String(bytes: bytes, encoding: .ascii).flatMap { $0.isEmpty ? nil : $0 }
    }
    if type == 0x6d6c_7563, tag.count >= 16 {
      let records = Int(tag.uint32(8, little: false))
      let recordSize = Int(tag.uint32(12, little: false))
      guard recordSize >= 12, records <= (tag.count - 16) / recordSize else { return nil }
      var fallback: String?
      for n in 0..<records {
        let base = 16 + n * recordSize
        let length = Int(tag.uint32(base + 4, little: false))
        let start = Int(tag.uint32(base + 8, little: false))
        guard length % 2 == 0, start <= tag.count, length <= tag.count - start else { continue }
        if let name = String(
          data: tag.subdata(in: start..<(start + length)), encoding: .utf16BigEndian), !name.isEmpty
        {
          if tag.uint16(base, little: false) == 0x656e { return name }
          if fallback == nil { fallback = name }
        }
      }
      return fallback
    }
  }
  return nil
}
