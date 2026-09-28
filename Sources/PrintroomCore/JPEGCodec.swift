import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Encodes already converted RGB samples; the ICC describes those exact samples.
public enum JPEGCodec {
  public static func write(
    url: URL, width: Int, height: Int, profile: Data,
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
    CGImageDestinationAddImage(destination, image, [
      kCGImageDestinationLossyCompressionQuality: 1.0,
      kCGImagePropertyOrientation: 1,
    ] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw PrintroomError.invalid("JPG 编码失败。") }
    try Task.checkCancellation()
    let result = temporary.withUnsafeFileSystemRepresentation { source in
      url.withUnsafeFileSystemRepresentation { target in
        renamex_np(source!, target!, UInt32(RENAME_EXCL))
      }
    }
    guard result == 0 else {
      if errno == EEXIST { throw TIFFWriteError.destinationExists(url.lastPathComponent) }
      throw PrintroomError.invalid("无法发布 JPG：\(String(cString: strerror(errno)))")
    }
  }
}
