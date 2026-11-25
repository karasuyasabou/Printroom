import Foundation
#if canImport(ImageIO)
import ImageIO
#endif

/// Only timestamps are inherited: source color, orientation and geometry metadata
/// must never describe the rendered output. Missing capture times stay missing.
public struct ExportDates: Sendable {
  var creation: Date?
  var modification: Date?
  var tiffDateTime: String?
  var exif: [String: String] = [:]

  public init() {}

  static let exifTags: [(key: String, tag: UInt16)] = [
    ("DateTimeOriginal", 36867), ("DateTimeDigitized", 36868),
    ("OffsetTime", 36880), ("OffsetTimeOriginal", 36881), ("OffsetTimeDigitized", 36882),
    ("SubsecTime", 37520), ("SubsecTimeOriginal", 37521), ("SubsecTimeDigitized", 37522),
  ]

  static func read(from url: URL) throws -> Self {
    var dates = Self()
    #if os(Windows)
    let fsDates = try PlatformFS.getFileDates(url)
    dates.creation = fsDates.creation
    dates.modification = fsDates.modification
    #else
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    dates.creation = attributes[.creationDate] as? Date
    dates.modification = attributes[.modificationDate] as? Date
    #endif
    #if canImport(ImageIO)
    // ImageIO inspects the original file, never an Adobe conversion or proxy.
    // Unsupported RAW metadata does not prevent preserving filesystem dates.
    guard let source = CGImageSourceCreateWithURL(url as CFURL,
      [kCGImageSourceShouldCache: false] as CFDictionary),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
    else { return dates }
    let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
    dates.tiffDateTime = asciiTimestamp(tiff?[kCGImagePropertyTIFFDateTime as String])
    let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
    for (key, _) in exifTags {
      dates.exif[key] = asciiTimestamp(exif?[key])
    }
    #else
    if let parsed = try? parseEmbeddedTimestamps(at: url) {
      dates.tiffDateTime = parsed.tiffDateTime
      dates.exif = parsed.exif
    }
    #endif
    return dates
  }

  private static func asciiTimestamp(_ value: Any?) -> String? {
    guard let text = value as? String, !text.isEmpty, text.utf8.count <= 128,
      text.utf8.allSatisfy({ (32...126).contains($0) }) else { return nil }
    return text
  }

  #if canImport(ImageIO)
  var imageProperties: [String: Any] {
    var properties: [String: Any] = [:]
    if !exif.isEmpty { properties[kCGImagePropertyExifDictionary as String] = exif }
    if let tiffDateTime {
      properties[kCGImagePropertyTIFFDictionary as String] = [kCGImagePropertyTIFFDateTime as String: tiffDateTime]
    }
    return properties
  }
  #else
  private static func parseEmbeddedTimestamps(at url: URL) throws -> (tiffDateTime: String?, exif: [String: String])? {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let head = try handle.read(upToCount: 4) ?? Data()
    guard head.count >= 2 else { return nil }
    if head[0] == 0xFF, head[1] == 0xD8 {
      return try parseJPEGExifTimestamps(handle: handle)
    }
    return try parseTIFFExifTimestamps(handle: handle, baseOffset: 0)
  }

  private static func parseJPEGExifTimestamps(handle: FileHandle) throws -> (tiffDateTime: String?, exif: [String: String])? {
    try handle.seek(toOffset: 2)
    while true {
      guard let marker = try handle.read(upToCount: 2), marker.count == 2 else { return nil }
      if marker[0] != 0xFF { return nil }
      let code = marker[1]
      if code == 0xD9 || code == 0xDA { return nil }
      if code == 0x00 || (0xD0...0xD7).contains(code) { continue }
      guard let lenBytes = try handle.read(upToCount: 2), lenBytes.count == 2 else { return nil }
      let segLen = (Int(lenBytes[0]) << 8) | Int(lenBytes[1])
      guard segLen >= 2 else { return nil }
      if code == 0xE1 {
        let payloadLen = segLen - 2
        if payloadLen >= 14 && payloadLen <= 1_048_576 {
          let payload = try handle.read(upToCount: payloadLen) ?? Data()
          if payload.count >= 6, payload.prefix(6) == Data([0x45, 0x78, 0x69, 0x66, 0x00, 0x00]) {
            let tiffData = Data(payload.dropFirst(6))
            return parseTIFFExifTimestamps(data: tiffData)
          }
          continue
        }
      }
      let offset = try handle.offset()
      try handle.seek(toOffset: offset + UInt64(segLen - 2))
    }
  }

  private static func parseTIFFExifTimestamps(handle: FileHandle, baseOffset: UInt64) throws -> (tiffDateTime: String?, exif: [String: String])? {
    try handle.seek(toOffset: baseOffset)
    guard let header = try handle.read(upToCount: 16), header.count >= 8 else { return nil }
    let little = header[0] == 0x49 && header[1] == 0x49
    let big = header[0] == 0x4D && header[1] == 0x4D
    guard little || big else { return nil }
    let magic = uint16(header, at: 2, little: little)
    let isBigTIFF = magic == 43
    guard magic == 42 || (isBigTIFF && header.count >= 16) else { return nil }
    let ifd0Offset = isBigTIFF ? uint64(header, at: 8, little: little) : UInt64(uint32(header, at: 4, little: little))
    guard ifd0Offset > 0 else { return nil }

    func readRange(offset: UInt64, count: Int) -> Data? {
      guard count > 0, count <= 16_777_216 else { return nil }
      guard (try? handle.seek(toOffset: baseOffset + offset)) != nil else { return nil }
      guard let data = try? handle.read(upToCount: count), data.count == count else { return nil }
      return data
    }

    var tiffDateTime: String?
    var exifOffset: UInt64?
    for entry in readIFD(offset: ifd0Offset, isBigTIFF: isBigTIFF, little: little, readRange: readRange) {
      if entry.tag == 306, entry.type == 2, let raw = readTagBytes(entry, isBigTIFF: isBigTIFF, little: little, readRange: readRange) {
        tiffDateTime = asciiFromNullTerminated(raw)
      } else if entry.tag == 34665, entry.count == 1 {
        exifOffset = entry.inlineOffsetOrValue
      }
    }
    var exifDict: [String: String] = [:]
    if let exifOffset, exifOffset > 0 {
      let tagMap = Dictionary(uniqueKeysWithValues: exifTags.map { ($0.tag, $0.key) })
      for entry in readIFD(offset: exifOffset, isBigTIFF: isBigTIFF, little: little, readRange: readRange) {
        if let key = tagMap[entry.tag], entry.type == 2,
           let raw = readTagBytes(entry, isBigTIFF: isBigTIFF, little: little, readRange: readRange),
           let text = asciiFromNullTerminated(raw) {
          exifDict[key] = text
        }
      }
    }
    return (tiffDateTime, exifDict)
  }

  private static func parseTIFFExifTimestamps(data: Data) -> (tiffDateTime: String?, exif: [String: String])? {
    guard data.count >= 8 else { return nil }
    let little = data[0] == 0x49 && data[1] == 0x49
    let big = data[0] == 0x4D && data[1] == 0x4D
    guard little || big else { return nil }
    let magic = uint16(data, at: 2, little: little)
    let isBigTIFF = magic == 43
    guard magic == 42 || (isBigTIFF && data.count >= 16) else { return nil }
    let ifd0Offset = isBigTIFF ? uint64(data, at: 8, little: little) : UInt64(uint32(data, at: 4, little: little))
    func readRange(offset: UInt64, count: Int) -> Data? {
      guard count > 0, offset <= UInt64(data.count), UInt64(count) <= UInt64(data.count) - offset else { return nil }
      let start = Int(offset)
      return data.subdata(in: start..<(start + count))
    }
    var tiffDateTime: String?
    var exifOffset: UInt64?
    for entry in readIFD(offset: ifd0Offset, isBigTIFF: isBigTIFF, little: little, readRange: readRange) {
      if entry.tag == 306, entry.type == 2, let raw = readTagBytes(entry, isBigTIFF: isBigTIFF, little: little, readRange: readRange) {
        tiffDateTime = asciiFromNullTerminated(raw)
      } else if entry.tag == 34665, entry.count == 1 {
        exifOffset = entry.inlineOffsetOrValue
      }
    }
    var exifDict: [String: String] = [:]
    if let exifOffset, exifOffset > 0 {
      let tagMap = Dictionary(uniqueKeysWithValues: exifTags.map { ($0.tag, $0.key) })
      for entry in readIFD(offset: exifOffset, isBigTIFF: isBigTIFF, little: little, readRange: readRange) {
        if let key = tagMap[entry.tag], entry.type == 2,
           let raw = readTagBytes(entry, isBigTIFF: isBigTIFF, little: little, readRange: readRange),
           let text = asciiFromNullTerminated(raw) {
          exifDict[key] = text
        }
      }
    }
    return (tiffDateTime, exifDict)
  }

  private struct RawIFDEntry {
    let tag: UInt16
    let type: UInt16
    let count: UInt64
    let valueBytes: Data
    let inlineOffsetOrValue: UInt64
  }

  private static func readIFD(
    offset: UInt64, isBigTIFF: Bool, little: Bool, readRange: (UInt64, Int) -> Data?
  ) -> [RawIFDEntry] {
    let countSize = isBigTIFF ? 8 : 2
    let entrySize = isBigTIFF ? 20 : 12
    guard let countData = readRange(offset, countSize) else { return [] }
    let count = isBigTIFF ? uint64(countData, at: 0, little: little) : UInt64(uint16(countData, at: 0, little: little))
    guard count > 0, count <= 4096, let table = readRange(offset + UInt64(countSize), Int(count) * entrySize) else { return [] }
    var result: [RawIFDEntry] = []
    for i in 0..<Int(count) {
      let base = i * entrySize
      let tag = uint16(table, at: base, little: little)
      let type = uint16(table, at: base + 2, little: little)
      let valCount = isBigTIFF ? uint64(table, at: base + 4, little: little) : UInt64(uint32(table, at: base + 4, little: little))
      let valSlice = table.subdata(in: (base + (isBigTIFF ? 12 : 8))..<(base + entrySize))
      let inlineVal: UInt64
      if isBigTIFF {
        inlineVal = (type == 3 && valCount == 1) ? UInt64(uint16(valSlice, at: 0, little: little))
          : (type == 4 && valCount == 1) ? UInt64(uint32(valSlice, at: 0, little: little))
          : uint64(valSlice, at: 0, little: little)
      } else {
        inlineVal = (type == 3 && valCount == 1) ? UInt64(uint16(valSlice, at: 0, little: little))
          : UInt64(uint32(valSlice, at: 0, little: little))
      }
      result.append(RawIFDEntry(tag: tag, type: type, count: valCount, valueBytes: valSlice, inlineOffsetOrValue: inlineVal))
    }
    return result
  }

  private static func readTagBytes(
    _ entry: RawIFDEntry, isBigTIFF: Bool, little: Bool, readRange: (UInt64, Int) -> Data?
  ) -> Data? {
    guard entry.count > 0, entry.count <= 256 else { return nil }
    let inlineLimit = isBigTIFF ? 8 : 4
    if Int(entry.count) <= inlineLimit {
      return entry.valueBytes.prefix(Int(entry.count))
    }
    return readRange(entry.inlineOffsetOrValue, Int(entry.count))
  }

  private static func asciiFromNullTerminated(_ data: Data) -> String? {
    let trimmed = data.prefix { $0 != 0 }
    guard let str = String(bytes: trimmed, encoding: .ascii) else { return nil }
    return asciiTimestamp(str)
  }

  private static func uint16(_ data: Data, at offset: Int, little: Bool) -> UInt16 {
    let b0 = UInt16(data[offset]), b1 = UInt16(data[offset + 1])
    return little ? (b0 | (b1 << 8)) : ((b0 << 8) | b1)
  }

  private static func uint32(_ data: Data, at offset: Int, little: Bool) -> UInt32 {
    let b0 = UInt32(data[offset]), b1 = UInt32(data[offset + 1]), b2 = UInt32(data[offset + 2]), b3 = UInt32(data[offset + 3])
    return little ? (b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)) : ((b0 << 24) | (b1 << 16) | (b2 << 8) | b3)
  }

  private static func uint64(_ data: Data, at offset: Int, little: Bool) -> UInt64 {
    var value: UInt64 = 0
    for i in 0..<8 {
      let shift = UInt64((little ? i : (7 - i)) * 8)
      value |= UInt64(data[offset + i]) << shift
    }
    return value
  }
  #endif

  /// Apply after all writes, but before atomic publication. Failure keeps the
  /// old destination intact instead of reporting an incompletely dated export.
  func apply(to url: URL) throws {
    #if os(Windows)
    try PlatformFS.setFileDates(url, creation: creation, modification: modification)
    #else
    var attributes: [FileAttributeKey: Any] = [:]
    if let creation { attributes[.creationDate] = creation }
    if let modification { attributes[.modificationDate] = modification }
    if !attributes.isEmpty {
      try FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
    }
    #endif
  }
}
