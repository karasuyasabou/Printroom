import Darwin
import Foundation
import zlib

/// Raw sample I/O: ICC metadata never participates in decoding or encoding.
/// Supports classic, stripped RGB UInt16 TIFF (uncompressed or Deflate).
public enum TIFFCodec {
  public static func read(url: URL) throws -> LinearImage {
    guard url.isFileURL else { throw invalid("TIFF 必须是本地文件。") }
    let reader = try TIFFReader(url: url)
    defer { try? reader.handle.close() }
    return try reader.readImage()
  }

  /// Requests bounded, contiguous, top-to-bottom RGB rows. The caller owns
  /// quantization and cancellation; any thrown error aborts and removes the temp.
  /// M1 explicitly uses compression=1 (uncompressed), in place of the planned
  /// Deflate default. No alpha, no color conversion, exact supplied ICC bytes.
  public static func write(
    url: URL, width: Int, height: Int, profile: Data,
    rows: (Range<Int>) throws -> [UInt16]
  ) throws {
    guard url.isFileURL, width > 0, height > 0,
      width <= Int(UInt32.max), height <= Int(UInt32.max),
      !profile.isEmpty, profile.count <= Int(UInt32.max)
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
    let byteCounts = (0..<stripCount).map {
      UInt32(min(rowsPerStrip, height - $0 * rowsPerStrip) * Int(rowBytes))
    }
    var entries: [TIFFWriteEntry] = [
      .long(256, UInt32(width)), .long(257, UInt32(height)),
      .shorts(258, [16, 16, 16]), .shorts(259, [1]),
      .shorts(262, [2]), .longs(273, [UInt32](repeating: 0, count: stripCount)),
      .shorts(274, [1]), .shorts(277, [3]), .long(278, UInt32(rowsPerStrip)),
      .longs(279, byteCounts), .shorts(284, [1]), .shorts(339, [1, 1, 1]),
      TIFFWriteEntry(tag: 34675, type: 7, count: UInt32(profile.count), payload: profile),
    ]
    let metadataSize = try makeHeader(entries).count
    let end = UInt64(metadataSize) + rowBytes * UInt64(height)
    guard end <= UInt64(UInt32.max) else {
      throw invalid("输出超过 classic TIFF 的 4 GiB 限制。")
    }
    var offset = UInt32(metadataSize)
    let offsets = byteCounts.map { count in
      defer { offset += count }
      return offset
    }
    entries[5] = .longs(273, offsets)
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
    for start in stride(from: 0, to: height, by: rowsPerStrip) {
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
      try samples.withUnsafeBytes { try handle.write(contentsOf: $0) }
    }
    try handle.synchronize()
    try handle.close()
    // RENAME_EXCL is an atomic no-replace operation, including a destination
    // created by another process after the initial check (or a dangling link).
    let result = temporary.withUnsafeFileSystemRepresentation { source in
      url.withUnsafeFileSystemRepresentation { destination in
        renamex_np(source!, destination!, UInt32(RENAME_EXCL))
      }
    }
    guard result == 0 else { throw fileError("无法发布 TIFF（目标可能已存在）", code: errno) }
  }

  private static func requireAbsent(_ url: URL) throws {
    var status = stat()
    let result = url.withUnsafeFileSystemRepresentation { lstat($0!, &status) }
    if result == 0 { throw invalid("目标已存在，禁止覆盖 TIFF：\(url.lastPathComponent)") }
    if errno != ENOENT { throw fileError("无法检查 TIFF 目标", code: errno) }
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
      guard header.uint16(2, little: little) == 42 else {
        throw invalid("仅支持 classic TIFF，暂不支持 BigTIFF。")
      }
      handle = file
      let ifd = UInt64(header.uint32(4, little: little))
      guard ifd >= 8 else { throw invalid("TIFF IFD 偏移无效。") }
      let count = Int(try readBytes(at: ifd, count: 2).uint16(0, little: little))
      let directory = try readBytes(at: ifd + 2, count: count * 12 + 4)
      for i in 0..<count {
        let base = i * 12
        let tag = directory.uint16(base, little: little)
        guard entries[tag] == nil else { throw invalid("TIFF 包含重复的标签 \(tag)。") }
        entries[tag] = Entry(
          type: directory.uint16(base + 2, little: little),
          count: Int(directory.uint32(base + 4, little: little)),
          value: directory.subdata(in: (base + 8)..<(base + 12)))
      }
      guard directory.uint32(count * 12, little: little) == 0 else {
        throw invalid("暂不支持多页 TIFF。")
      }
    } catch {
      try? file.close()
      throw error
    }
  }

  func readImage() throws -> LinearImage {
    let width = try scalar(256)
    let height = try scalar(257)
    guard width > 0, height > 0,
      UInt64(height) <= UInt64(UInt32.max) / (UInt64(width) * 6)
    else {
      throw invalid("TIFF 尺寸无效或未压缩样本超过 4 GiB。")
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
    guard [1, 8, 32946].contains(compression) else {
      throw invalid("暂不支持 TIFF 压缩 \(compression)，可读取无压缩和 Deflate。")
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
      guard count > 0, offsets[strip] >= 8,
        UInt64(offsets[strip]) <= fileSize,
        UInt64(count) <= fileSize - UInt64(offsets[strip]),
        compression != 1 || count == expected
      else {
        throw invalid("TIFF strip 范围或样本字节数无效。")
      }
    }
    let profileName = try embeddedProfileName()
    let outputWidth = orientation >= 5 ? height : width
    let outputHeight = orientation >= 5 ? width : height
    var samples = [UInt16](repeating: 0, count: width * height * 3)
    try samples.withUnsafeMutableBufferPointer { output in
      for strip in 0..<stripCount {
        let firstRow = strip * rowsPerStrip
        let rowCount = min(rowsPerStrip, height - firstRow)
        let expected = rowCount * width * 6
        var bytes = try readBytes(at: UInt64(offsets[strip]), count: counts[strip])
        if compression != 1 { bytes = try inflateStrip(bytes, expected: expected) }
        if orientation == 1 && predictor == 1 && little {
          // No CoreGraphics, ICC transform, transfer decode or rounding.
          _ = bytes.copyBytes(
            to: UnsafeMutableRawBufferPointer(
              start: output.baseAddress!.advanced(by: firstRow * width * 3), count: expected))
          continue
        }
        bytes.withUnsafeBytes { raw in
          for localY in 0..<rowCount {
            let y = firstRow + localY
            var previous = SIMD3<UInt16>(repeating: 0)
            for x in 0..<width {
              let destination: (Int, Int)
              switch orientation {
              case 2: destination = (width - 1 - x, y)
              case 3: destination = (width - 1 - x, height - 1 - y)
              case 4: destination = (x, height - 1 - y)
              case 5: destination = (y, x)
              case 6: destination = (height - 1 - y, x)
              case 7: destination = (height - 1 - y, width - 1 - x)
              case 8: destination = (y, width - 1 - x)
              default: destination = (x, y)
              }
              let target = (destination.1 * outputWidth + destination.0) * 3
              let source = (localY * width + x) * 6
              for channel in 0..<3 {
                let value = raw.loadUnaligned(fromByteOffset: source + channel * 2, as: UInt16.self)
                var sample = little ? UInt16(littleEndian: value) : UInt16(bigEndian: value)
                if predictor == 2 { sample = sample &+ previous[channel] }
                previous[channel] = sample
                output[target + channel] = sample
              }
            }
          }
        }
      }
    }
    return LinearImage(
      width: outputWidth, height: outputHeight, samples: samples, embeddedProfileName: profileName)
  }

  private func readBytes(at offset: UInt64, count: Int) throws -> Data {
    guard count >= 0, offset <= fileSize, UInt64(count) <= fileSize - offset else {
      throw invalid("TIFF 数据超出文件边界。")
    }
    try handle.seek(toOffset: offset)
    var result = Data()
    while result.count < count {
      guard let part = try handle.read(upToCount: count - result.count), !part.isEmpty else {
        throw invalid("TIFF 文件意外截断。")
      }
      result.append(part)
    }
    return result
  }

  private func payload(_ entry: Entry, unit: Int) throws -> Data {
    guard entry.count > 0, entry.count <= Int(UInt32.max) / unit else {
      throw invalid("TIFF 标签数量无效。")
    }
    let size = entry.count * unit
    if size <= 4 { return entry.value.prefix(size) }
    return try readBytes(at: UInt64(entry.value.uint32(0, little: little)), count: size)
  }

  private func integers(_ tag: UInt16, expectedCount: Int, defaultValue: [Int]? = nil) throws
    -> [Int]
  {
    guard let entry = entries[tag] else {
      if let defaultValue { return defaultValue }
      throw invalid("TIFF 缺少标签 \(tag)。")
    }
    guard entry.count == expectedCount, entry.type == 3 || entry.type == 4 else {
      throw invalid("TIFF 标签 \(tag) 的类型或数量无效。")
    }
    let unit = entry.type == 3 ? 2 : 4
    let bytes = try payload(entry, unit: unit)
    return (0..<entry.count).map {
      unit == 2
        ? Int(bytes.uint16($0 * unit, little: little))
        : Int(bytes.uint32($0 * unit, little: little))
    }
  }

  private func scalar(_ tag: UInt16, defaultValue: Int? = nil) throws -> Int {
    try integers(tag, expectedCount: 1, defaultValue: defaultValue.map { [$0] })[0]
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
