import Foundation
import CRawBridge

public struct RawDecodedMetadata: Sendable {
  public let width: Int
  public let height: Int
  /// TIFF orientation of the source; decoded pixels deliberately remain unrotated.
  public let sourceOrientation: Int
}

private final class RawCancellationContext {
  let cancelled: @Sendable () -> Bool
  init(_ cancelled: @escaping @Sendable () -> Bool) { self.cancelled = cancelled }
}

/// Adobe alone performs demosaicing. This bridge rejects CFA and interprets
/// validated Linear DNG with the fixed open-make-tiff-compatible LibRaw recipe.
public enum RawDecoder {
  public static var version: String { String(cString: pr_raw_version()) }

  public static func metadata(linearDNG url: URL) throws -> RawDecodedMetadata {
    guard url.isFileURL else { throw PrintroomError.invalid("RAW 中间文件必须是本地文件。") }
    var info = PRRawMetadata()
    var error = [CChar](repeating: 0, count: 1024)
    let status = url.path.withCString { pr_raw_metadata($0, &info, &error, error.count) }
    try requireSuccess(status, error: error)
    return RawDecodedMetadata(width: Int(info.width), height: Int(info.height), sourceOrientation: Int(info.source_orientation))
  }

  public static func decode(
    linearDNG url: URL, cancelled: @escaping @Sendable () -> Bool = { false }
  ) throws -> LinearImage {
    if cancelled() { throw CancellationError() }
    let metadata = try metadata(linearDNG: url)
    let context = RawCancellationContext(cancelled)
    let pointer = Unmanaged.passUnretained(context).toOpaque()
    var info = PRRawMetadata()
    var error = [CChar](repeating: 0, count: 1024)
    var samples = [UInt16](repeating: 0, count: metadata.width * metadata.height * 3)
    let status = withExtendedLifetime(context) {
      samples.withUnsafeMutableBufferPointer { buffer in
        url.path.withCString { path in
          pr_raw_decode(path, buffer.baseAddress, buffer.count, &info, { opaque in
            guard let opaque else { return 0 }
            return Unmanaged<RawCancellationContext>.fromOpaque(opaque).takeUnretainedValue().cancelled() ? 1 : 0
          }, pointer, &error, error.count)
        }
      }
    }
    try requireSuccess(status, error: error)
    return LinearImage(width: Int(info.width), height: Int(info.height), samples: samples, embeddedProfileName: "Adobe 线性相机 RGB")
  }

  private static func requireSuccess(_ status: Int32, error: [CChar]) throws {
    if status == -2 { throw CancellationError() }
    if status != 0 {
      let text = error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
      throw PrintroomError.invalid("Adobe 线性 RAW 读取失败：\(text)")
    }
  }
}
