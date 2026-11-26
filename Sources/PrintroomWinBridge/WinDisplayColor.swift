import CWinPlatform
import Foundation
import PrintroomCore

public struct WinDisplayBitmap: Sendable {
  public let width: Int
  public let height: Int
  public let bgra8: [UInt8]

  public var byteCount: Int { bgra8.count }
}

/// Manages Windows monitor ICC color transforms using WCS/ICM (`mscms.dll`)
/// with a deterministic double-precision `OutputColorConverter` sRGB fallback.
public final class WinDisplayColor: @unchecked Sendable {
  private struct TransformKey: Hashable {
    let monitorPath: String
    let isSRGBSource: Bool
  }

  private let p3Profile: Data
  private let srgbProfile: Data
  private let linearP3EncodeTable: [Double]
  private let p3ToSRGB: OutputColorConverter
  private let lock = NSLock()
  private var hwnd: Int = 0
  private var currentMonitorPath: String?
  private var transforms: [TransformKey: OpaquePointer] = [:]

  public init(p3Profile: Data) throws {
    self.p3Profile = p3Profile
    self.srgbProfile = try OutputColorProfile.sRGB.profileData(p3: p3Profile)
    self.p3ToSRGB = try OutputColorConverter(p3Profile: p3Profile, output: .sRGB)
    self.currentMonitorPath = Self.queryMonitorICCPath(hwnd: 0)

    // Precompute DCIP3_D65 linear -> gamma encode table (pure gamma ~2.6 from DCIP3_D65.icc)
    let gamma = Self.extractPrimaryGamma(from: p3Profile) ?? 2.600006103515625
    let invGamma = 1.0 / gamma
    var table = [Double](repeating: 0, count: 4097)
    for i in 0...4096 {
      let x = Double(i) / 4096.0
      table[i] = pow(x, invGamma)
    }
    self.linearP3EncodeTable = table
  }

  deinit {
    for (_, ptr) in transforms {
      pr_win_color_transform_destroy(ptr)
    }
  }

  /// Updates the active HWND and returns `true` if the effective monitor ICC profile changed.
  @discardableResult
  public func updateHWND(_ newHWND: Int) -> Bool {
    let nextPath = Self.queryMonitorICCPath(hwnd: newHWND)
    return lock.withLock {
      self.hwnd = newHWND
      let changed = (nextPath != currentMonitorPath)
      self.currentMonitorPath = nextPath
      return changed
    }
  }

  @discardableResult
  public func refreshMonitorProfile() -> Bool {
    let currentHWND = lock.withLock { self.hwnd }
    let nextPath = Self.queryMonitorICCPath(hwnd: currentHWND)
    return lock.withLock {
      let changed = (nextPath != currentMonitorPath)
      self.currentMonitorPath = nextPath
      return changed
    }
  }

  public var activeMonitorProfilePath: String? {
    lock.withLock { currentMonitorPath }
  }

  /// Renders pipeline output pixels directly into monitor-color-managed BGRA8.
  public func makeDisplayBitmap(
    _ buffer: PixelBuffer,
    diagnostic: Bool = false,
    original: Bool = false
  ) throws -> WinDisplayBitmap {
    let (count, overflow) = buffer.width.multipliedReportingOverflow(by: buffer.height)
    guard buffer.width > 0, buffer.height > 0, !overflow, count == buffer.pixels.count else {
      throw PrintroomError.invalid("预览像素尺寸不匹配")
    }

    // Encode linear P3 uncalibrated scan samples into DCIP3_D65 gamma domain first
    let workingBuffer: PixelBuffer
    if original {
      var encoded = [SIMD4<Float>]()
      encoded.reserveCapacity(count)
      for p in buffer.pixels {
        guard p.x.isFinite && p.y.isFinite && p.z.isFinite else {
          throw PrintroomError.invalid("预览包含非有限 RGB 数值")
        }
        encoded.append(SIMD4(
          encodeLinearP3(p.x),
          encodeLinearP3(p.y),
          encodeLinearP3(p.z),
          1
        ))
      }
      workingBuffer = PixelBuffer(width: buffer.width, height: buffer.height, pixels: encoded)
    } else {
      workingBuffer = buffer
    }

    let useSRGBSource = diagnostic && !original
    if let monitorPath = lock.withLock({ currentMonitorPath }),
       let bgra = try convertWithWCS(workingBuffer, monitorPath: monitorPath, useSRGBSource: useSRGBSource) {
      return WinDisplayBitmap(width: buffer.width, height: buffer.height, bgra8: bgra)
    }

    // Fallback: deterministic Double-precision conversion to sRGB BGRA8
    return try convertFallbackSRGB(workingBuffer, isAlreadySRGB: useSRGBSource)
  }

  /// Converts a 16-bit RGBA PNG buffer tagged as `sourceIsSRGB ? sRGB : DCIP3_D65` to monitor BGRA8.
  public func makeDisplayBitmapFromRGB16(
    width: Int,
    height: Int,
    rgba16: [UInt16],
    sourceIsSRGB: Bool
  ) throws -> WinDisplayBitmap {
    let (count, overflow) = width.multipliedReportingOverflow(by: height)
    guard width > 0, height > 0, !overflow, rgba16.count == count * 4 else {
      throw PrintroomError.invalid("缓存缩略图尺寸不匹配")
    }
    if let monitorPath = lock.withLock({ currentMonitorPath }),
       let transform = transformHandle(monitorPath: monitorPath, useSRGBSource: sourceIsSRGB) {
      var rgb16 = [UInt16](repeating: 0, count: count * 3)
      for i in 0..<count {
        rgb16[i * 3 + 0] = rgba16[i * 4 + 0]
        rgb16[i * 3 + 1] = rgba16[i * 4 + 1]
        rgb16[i * 3 + 2] = rgba16[i * 4 + 2]
      }
      var bgra = [UInt8](repeating: 255, count: count * 4)
      var winErr: UInt32 = 0
      let rc = rgb16.withUnsafeBufferPointer { inBuf in
        bgra.withUnsafeMutableBufferPointer { outBuf in
          pr_win_color_transform_apply_bgra8(
            transform, inBuf.baseAddress, outBuf.baseAddress,
            UInt32(width), UInt32(height), &winErr)
        }
      }
      if rc == 0 {
        return WinDisplayBitmap(width: width, height: height, bgra8: bgra)
      }
    }

    // Software fallback
    var pixels = [SIMD4<Float>]()
    pixels.reserveCapacity(count)
    let inv = Float(1.0 / 65535.0)
    for i in 0..<count {
      pixels.append(SIMD4(
        Float(rgba16[i * 4 + 0]) * inv,
        Float(rgba16[i * 4 + 1]) * inv,
        Float(rgba16[i * 4 + 2]) * inv,
        1
      ))
    }
    return try convertFallbackSRGB(PixelBuffer(width: width, height: height, pixels: pixels), isAlreadySRGB: sourceIsSRGB)
  }

  /// Prepares 16-bit RGBA pixels and matching ICC profile bytes for disk thumbnail cache storage.
  public func makeCachePNGPayload(
    _ buffer: PixelBuffer,
    diagnostic: Bool = false,
    original: Bool = false
  ) throws -> (rgba16: [UInt16], iccProfile: Data) {
    let count = buffer.width * buffer.height
    var rgba16 = [UInt16](repeating: 65535, count: count * 4)
    for i in 0..<count {
      let p = buffer.pixels[i]
      guard p.x.isFinite && p.y.isFinite && p.z.isFinite else {
        throw PrintroomError.invalid("缩略图包含非有限 RGB 数值")
      }
      let r = original ? encodeLinearP3(p.x) : p.x
      let g = original ? encodeLinearP3(p.y) : p.y
      let b = original ? encodeLinearP3(p.z) : p.z
      rgba16[i * 4 + 0] = UInt16(floor(Double(min(1, max(0, r))) * 65535.0 + 0.5))
      rgba16[i * 4 + 1] = UInt16(floor(Double(min(1, max(0, g))) * 65535.0 + 0.5))
      rgba16[i * 4 + 2] = UInt16(floor(Double(min(1, max(0, b))) * 65535.0 + 0.5))
    }
    let icc = (diagnostic && !original) ? srgbProfile : p3Profile
    return (rgba16, icc)
  }

  private func convertWithWCS(_ buffer: PixelBuffer, monitorPath: String, useSRGBSource: Bool) throws -> [UInt8]? {
    guard let transform = transformHandle(monitorPath: monitorPath, useSRGBSource: useSRGBSource) else {
      return nil
    }
    let count = buffer.pixels.count
    var rgb16 = [UInt16](repeating: 0, count: count * 3)
    for i in 0..<count {
      let p = buffer.pixels[i]
      guard p.x.isFinite && p.y.isFinite && p.z.isFinite else {
        throw PrintroomError.invalid("预览包含非有限 RGB 数值")
      }
      rgb16[i * 3 + 0] = UInt16(floor(Double(min(1, max(0, p.x))) * 65535.0 + 0.5))
      rgb16[i * 3 + 1] = UInt16(floor(Double(min(1, max(0, p.y))) * 65535.0 + 0.5))
      rgb16[i * 3 + 2] = UInt16(floor(Double(min(1, max(0, p.z))) * 65535.0 + 0.5))
    }
    var bgra = [UInt8](repeating: 255, count: count * 4)
    var winErr: UInt32 = 0
    let rc = rgb16.withUnsafeBufferPointer { inBuf in
      bgra.withUnsafeMutableBufferPointer { outBuf in
        pr_win_color_transform_apply_bgra8(
          transform, inBuf.baseAddress, outBuf.baseAddress,
          UInt32(buffer.width), UInt32(buffer.height), &winErr)
      }
    }
    return rc == 0 ? bgra : nil
  }

  private func convertFallbackSRGB(_ buffer: PixelBuffer, isAlreadySRGB: Bool) throws -> WinDisplayBitmap {
    let source = isAlreadySRGB ? buffer : try p3ToSRGB.convert(buffer)
    let rgb8 = try OutputColorConverter.quantize8(source)
    let count = buffer.width * buffer.height
    var bgra = [UInt8](repeating: 255, count: count * 4)
    for i in 0..<count {
      bgra[i * 4 + 0] = rgb8[i * 3 + 2]
      bgra[i * 4 + 1] = rgb8[i * 3 + 1]
      bgra[i * 4 + 2] = rgb8[i * 3 + 0]
      bgra[i * 4 + 3] = 255
    }
    return WinDisplayBitmap(width: buffer.width, height: buffer.height, bgra8: bgra)
  }

  private func transformHandle(monitorPath: String, useSRGBSource: Bool) -> OpaquePointer? {
    let key = TransformKey(monitorPath: monitorPath, isSRGBSource: useSRGBSource)
    if let existing = lock.withLock({ transforms[key] }) {
      return existing
    }
    let srcData = useSRGBSource ? srgbProfile : p3Profile
    var winErr: UInt32 = 0
    let created: OpaquePointer? = srcData.withUnsafeBytes { srcRaw in
      let ptr = srcRaw.baseAddress?.assumingMemoryBound(to: UInt8.self)
      return monitorPath.withCString { dstC in
        pr_win_color_transform_create(ptr, srcData.count, dstC, &winErr)
      }
    }
    guard let created else { return nil }
    return lock.withLock {
      if let already = transforms[key] {
        pr_win_color_transform_destroy(created)
        return already
      }
      transforms[key] = created
      return created
    }
  }

  private func encodeLinearP3(_ v: Float) -> Float {
    let c = min(1.0, max(0.0, Double(v)))
    let pos = c * 4096.0
    let idx = min(4095, Int(pos))
    let frac = pos - Double(idx)
    return Float(linearP3EncodeTable[idx] + (linearP3EncodeTable[idx + 1] - linearP3EncodeTable[idx]) * frac)
  }

  private static func queryMonitorICCPath(hwnd: Int) -> String? {
    var buf = [CChar](repeating: 0, count: 4096)
    let rc = pr_win_get_monitor_icc_path(hwnd, &buf, buf.count)
    guard rc == 0 else { return nil }
    let s = String(cString: &buf)
    return s.isEmpty ? nil : s
  }

  private static func extractPrimaryGamma(from data: Data) -> Double? {
    guard data.count >= 132 else { return nil }
    let count = (Int(data[128]) << 24) | (Int(data[129]) << 16) | (Int(data[130]) << 8) | Int(data[131])
    guard count <= (data.count - 132) / 12 else { return nil }
    for i in 0..<count {
      let rec = 132 + i * 12
      let name = String(bytes: data[rec..<(rec + 4)], encoding: .ascii)
      if name == "rTRC" {
        let offset = (Int(data[rec + 4]) << 24) | (Int(data[rec + 5]) << 16) | (Int(data[rec + 6]) << 8) | Int(data[rec + 7])
        let len = (Int(data[rec + 8]) << 24) | (Int(data[rec + 9]) << 16) | (Int(data[rec + 10]) << 8) | Int(data[rec + 11])
        guard offset + len <= data.count, len >= 14 else { return nil }
        if data[offset..<(offset + 4)] == Data("curv".utf8) {
          let n = (Int(data[offset + 8]) << 24) | (Int(data[offset + 9]) << 16) | (Int(data[offset + 10]) << 8) | Int(data[offset + 11])
          if n == 1 {
            return Double((Int(data[offset + 12]) << 8) | Int(data[offset + 13])) / 256.0
          }
        } else if data[offset..<(offset + 4)] == Data("para".utf8), len >= 16 {
          let raw = (Int(data[offset + 12]) << 24) | (Int(data[offset + 13]) << 16) | (Int(data[offset + 14]) << 8) | Int(data[offset + 15])
          let signed = Int32(bitPattern: UInt32(raw))
          return Double(signed) / 65536.0
        }
      }
    }
    return nil
  }
}
