#if canImport(CoreGraphics) && canImport(ImageIO) && canImport(UniformTypeIdentifiers) && canImport(Darwin)
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Encodes already converted RGB samples; the ICC describes those exact samples.
public enum JPEGCodec {
  public static func write(
    url: URL, width: Int, height: Int, profile: Data, dates: ExportDates = .init(),
    rows: (Range<Int>) throws -> [UInt8]
  ) throws {
    guard url.isFileURL, width > 0, height > 0, width <= 65500, height <= 65500,
      let space = CGColorSpace(iccData: profile as CFData), space.model == .rgb
    else { throw PrintroomError.invalid("JPG 尺寸或 ICC 无效（每边最多 65500 像素）。") }
    let staging = url.deletingLastPathComponent().appendingPathComponent(".printroom-\(UUID()).jpg.tmp")
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: staging) }
    let temporary = staging.appendingPathComponent("image.jpg")
    var data = Data()
    data.reserveCapacity(width * height * 3)
    for start in stride(from: 0, to: height, by: 32) {
      try Task.checkCancellation()
      let range = start..<min(height, start + 32)
      let samples = try rows(range)
      guard samples.count == range.count * width * 3 else {
        throw PrintroomError.invalid("JPG 行回调样本数量不正确。")
      }
      data.append(contentsOf: samples)
    }
    try Task.checkCancellation()
    guard let provider = CGDataProvider(data: data as CFData),
      let image = CGImage(width: width, height: height, bitsPerComponent: 8,
        bitsPerPixel: 24, bytesPerRow: width * 3, space: space,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .relativeColorimetric),
      let destination = CGImageDestinationCreateWithURL(temporary as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
    else { throw PrintroomError.invalid("无法创建 JPG 编码器。") }
    let encodeTrace = PerformanceTrace.begin()
    var properties = dates.imageProperties
    properties[kCGImageDestinationLossyCompressionQuality as String] = 1.0
    properties[kCGImagePropertyOrientation as String] = 1
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw PrintroomError.invalid("JPG 编码失败。") }
    PerformanceTrace.end("jpeg.encode_write", encodeTrace)
    try Task.checkCancellation()
    try dates.apply(to: temporary)
    let publishTrace = PerformanceTrace.begin()
    let result = temporary.withUnsafeFileSystemRepresentation { source in
      url.withUnsafeFileSystemRepresentation { target in
        renamex_np(source!, target!, UInt32(RENAME_EXCL))
      }
    }
    PerformanceTrace.end("jpeg.publish", publishTrace)
    guard result == 0 else {
      if errno == EEXIST { throw TIFFWriteError.destinationExists(url.lastPathComponent) }
      throw PrintroomError.invalid("无法发布 JPG：\(String(cString: strerror(errno)))")
    }
  }
}
#elseif os(Windows)
import CWinPlatform
import Foundation

/// Encodes already converted RGB samples using Windows WIC and injects lossless APP1 Exif + APP2 ICC segments.
public enum JPEGCodec {
  public static func write(
    url: URL, width: Int, height: Int, profile: Data, dates: ExportDates = .init(),
    rows: (Range<Int>) throws -> [UInt8]
  ) throws {
    guard url.isFileURL, width > 0, height > 0, width <= 65500, height <= 65500,
      isValidRGBICCProfile(profile)
    else { throw PrintroomError.invalid("JPG 尺寸或 ICC 无效（每边最多 65500 像素）。") }

    let staging = url.deletingLastPathComponent().appendingPathComponent(".printroom-\(UUID()).jpg.tmp", isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: staging) }
    let temporary = staging.appendingPathComponent("image.jpg")

    var rgb = [UInt8]()
    rgb.reserveCapacity(width * height * 3)
    for start in stride(from: 0, to: height, by: 32) {
      try Task.checkCancellation()
      let range = start..<min(height, start + 32)
      let samples = try rows(range)
      guard samples.count == range.count * width * 3 else {
        throw PrintroomError.invalid("JPG 行回调样本数量不正确。")
      }
      rgb.append(contentsOf: samples)
    }
    try Task.checkCancellation()

    let encodeTrace = PerformanceTrace.begin()
    var rawOut: UnsafeMutablePointer<UInt8>?
    var rawLen: Int = 0
    var winErr: UInt32 = 0
    let encRc = rgb.withUnsafeBufferPointer { buf in
      pr_win_wic_encode_jpeg_rgb8(buf.baseAddress, UInt32(width), UInt32(height), &rawOut, &rawLen, &winErr)
    }
    guard encRc == 0, let rawOut, rawLen >= 4 else {
      if let rawOut { pr_win_free_buffer(rawOut) }
      throw PrintroomError.invalid("JPG 编码失败（0x\(String(winErr, radix: 16))）。")
    }
    let encodedJPEG = Data(bytes: rawOut, count: rawLen)
    pr_win_free_buffer(rawOut)
    PerformanceTrace.end("jpeg.encode_write", encodeTrace)

    let finalJPEG = try spliceMetadata(into: encodedJPEG, profile: profile, dates: dates)
    let fd = try PlatformFS.openTempExclusive(temporary)
    do {
      try PlatformFS.writeAll(handle: fd, data: finalJPEG)
      try PlatformFS.flushAndClose(handle: fd)
    } catch {
      PlatformFS.closeLock(handle: fd)
      throw error
    }

    try Task.checkCancellation()
    try dates.apply(to: temporary)
    let publishTrace = PerformanceTrace.begin()
    try PlatformFS.moveExclusive(from: temporary, to: url)
    PerformanceTrace.end("jpeg.publish", publishTrace)
  }

  private static func isValidRGBICCProfile(_ data: Data) -> Bool {
    guard data.count >= 132 else { return false }
    let declared = (Int(data[0]) << 24) | (Int(data[1]) << 16) | (Int(data[2]) << 8) | Int(data[3])
    guard declared >= 128, declared <= data.count else { return false }
    let space = String(bytes: data[16..<20], encoding: .ascii)
    let sig = String(bytes: data[36..<40], encoding: .ascii)
    guard space == "RGB ", sig == "acsp" else { return false }
    let tagCount = (Int(data[128]) << 24) | (Int(data[129]) << 16) | (Int(data[130]) << 8) | Int(data[131])
    return tagCount > 0 && tagCount <= (data.count - 132) / 12
  }

  private static func spliceMetadata(into jpeg: Data, profile: Data, dates: ExportDates) throws -> Data {
    guard jpeg.count >= 2, jpeg[0] == 0xFF, jpeg[1] == 0xD8 else {
      throw PrintroomError.invalid("JPG 编码输出格式无效。")
    }
    var out = Data()
    out.reserveCapacity(jpeg.count + profile.count + 512)
    out.append(contentsOf: [0xFF, 0xD8])

    // APP1 Exif (Orientation=1 + optional TIFF DateTime and EXIF timestamps)
    let app1 = buildExifAPP1(dates: dates)
    out.append(app1)

    // APP2 ICC_PROFILE chunks (verbatim ICC bytes)
    appendICCAPP2(profile, to: &out)

    // Append remaining JPEG markers/entropy stream while stripping any WIC APP1/APP2 segments
    var offset = 2
    while offset + 1 < jpeg.count {
      guard jpeg[offset] == 0xFF else {
        out.append(jpeg[offset...])
        break
      }
      var markerOffset = offset + 1
      while markerOffset < jpeg.count && jpeg[markerOffset] == 0xFF { markerOffset += 1 }
      guard markerOffset < jpeg.count else {
        out.append(jpeg[offset...])
        break
      }
      let marker = jpeg[markerOffset]
      if marker == 0xDA || marker == 0xD9 {
        out.append(jpeg[offset...])
        break
      }
      if marker == 0x00 || (0xD0...0xD7).contains(marker) {
        out.append(jpeg[offset...(markerOffset)])
        offset = markerOffset + 1
        continue
      }
      guard markerOffset + 2 < jpeg.count else {
        out.append(jpeg[offset...])
        break
      }
      let segLen = (Int(jpeg[markerOffset + 1]) << 8) | Int(jpeg[markerOffset + 2])
      let nextOffset = markerOffset + 1 + segLen
      guard segLen >= 2, nextOffset <= jpeg.count else {
        out.append(jpeg[offset...])
        break
      }
      if marker != 0xE1 && marker != 0xE2 {
        out.append(jpeg[offset..<nextOffset])
      }
      offset = nextOffset
    }
    return out
  }

  private static func appendICCAPP2(_ profile: Data, to out: inout Data) {
    let maxPayloadPerChunk = 65519
    let totalChunks = max(1, (profile.count + maxPayloadPerChunk - 1) / maxPayloadPerChunk)
    precondition(totalChunks <= 255)
    for chunkIndex in 0..<totalChunks {
      let start = chunkIndex * maxPayloadPerChunk
      let end = min(profile.count, start + maxPayloadPerChunk)
      let slice = profile[start..<end]
      let segLen = 2 + 12 + 2 + slice.count
      out.append(contentsOf: [0xFF, 0xE2, UInt8(segLen >> 8), UInt8(segLen & 0xFF)])
      out.append(contentsOf: "ICC_PROFILE\0".utf8)
      out.append(UInt8(chunkIndex + 1))
      out.append(UInt8(totalChunks))
      out.append(slice)
    }
  }

  private static func buildExifAPP1(dates: ExportDates) -> Data {
    // Little-endian TIFF inside APP1 Exif\0\0
    var tiff = Data([0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00])
    func appendU16(_ v: UInt16, to d: inout Data) {
      d.append(UInt8(v & 0xFF)); d.append(UInt8((v >> 8) & 0xFF))
    }
    func appendU32(_ v: UInt32, to d: inout Data) {
      d.append(UInt8(v & 0xFF)); d.append(UInt8((v >> 8) & 0xFF))
      d.append(UInt8((v >> 16) & 0xFF)); d.append(UInt8((v >> 24) & 0xFF))
    }

    let exifItems: [(tag: UInt16, bytes: Data)] = ExportDates.exifTags.compactMap { pair in
      guard let text = dates.exif[pair.key] else { return nil }
      var raw = Data(text.utf8)
      raw.append(0)
      return (pair.tag, raw)
    }.sorted { $0.tag < $1.tag }

    let hasExifIFD = !exifItems.isEmpty
    var ifd0Tags: [(tag: UInt16, type: UInt16, count: UInt32, data: Data?)] = [
      (274, 3, 1, nil), // Orientation = 1
    ]
    if let dt = dates.tiffDateTime {
      var raw = Data(dt.utf8)
      raw.append(0)
      ifd0Tags.append((306, 2, UInt32(raw.count), raw))
    }
    if hasExifIFD {
      ifd0Tags.append((34665, 4, 1, nil))
    }
    ifd0Tags.sort { $0.tag < $1.tag }

    let ifd0Offset = 8
    let ifd0Size = 2 + ifd0Tags.count * 12 + 4
    let exifIFDOffset = ifd0Offset + ifd0Size
    let exifIFDSize = hasExifIFD ? (2 + exifItems.count * 12 + 4) : 0
    var dataHeapOffset = UInt32(exifIFDOffset + exifIFDSize)
    var heap = Data()

    // Write IFD0
    appendU16(UInt16(ifd0Tags.count), to: &tiff)
    for item in ifd0Tags {
      appendU16(item.tag, to: &tiff)
      appendU16(item.type, to: &tiff)
      appendU32(item.count, to: &tiff)
      if item.tag == 274 {
        appendU16(1, to: &tiff); appendU16(0, to: &tiff)
      } else if item.tag == 34665 {
        appendU32(UInt32(exifIFDOffset), to: &tiff)
      } else if let raw = item.data {
        if raw.count <= 4 {
          tiff.append(raw)
          if raw.count < 4 { tiff.append(Data(repeating: 0, count: 4 - raw.count)) }
        } else {
          appendU32(dataHeapOffset, to: &tiff)
          heap.append(raw)
          dataHeapOffset += UInt32(raw.count)
          if (raw.count & 1) == 1 { heap.append(0); dataHeapOffset += 1 }
        }
      }
    }
    appendU32(0, to: &tiff) // Next IFD = 0

    // Write ExifIFD
    if hasExifIFD {
      appendU16(UInt16(exifItems.count), to: &tiff)
      for item in exifItems {
        appendU16(item.tag, to: &tiff)
        appendU16(2, to: &tiff)
        appendU32(UInt32(item.bytes.count), to: &tiff)
        if item.bytes.count <= 4 {
          tiff.append(item.bytes)
          if item.bytes.count < 4 { tiff.append(Data(repeating: 0, count: 4 - item.bytes.count)) }
        } else {
          appendU32(dataHeapOffset, to: &tiff)
          heap.append(item.bytes)
          dataHeapOffset += UInt32(item.bytes.count)
          if (item.bytes.count & 1) == 1 { heap.append(0); dataHeapOffset += 1 }
        }
      }
      appendU32(0, to: &tiff)
    }

    tiff.append(heap)
    var payload = Data("Exif\0\0".utf8)
    payload.append(tiff)
    let segLen = 2 + payload.count
    var seg = Data([0xFF, 0xE1, UInt8(segLen >> 8), UInt8(segLen & 0xFF)])
    seg.append(payload)
    return seg
  }
}
#else
import Foundation

/// Encodes already converted RGB samples; the ICC describes those exact samples.
public enum JPEGCodec {
  public static func write(
    url: URL, width: Int, height: Int, profile: Data, dates: ExportDates = .init(),
    rows: (Range<Int>) throws -> [UInt8]
  ) throws {
    throw PrintroomError.invalid("Windows JPG 编码器将在阶段 1 接入。")
  }
}
#endif
