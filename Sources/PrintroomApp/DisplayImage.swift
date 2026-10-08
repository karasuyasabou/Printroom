import AppKit
import CryptoKit
import PrintroomCore

struct DisplayImage {
  // Independent of the image algorithm: old thumbnail representations must not be reused.
  static let presentationVersion = "sdr-uint16-v2-original-linear-p3"

  static func make(_ buffer: PixelBuffer, profile: Data?, diagnostic: Bool = false, original: Bool = false) throws
    -> CGImage
  {
    let (count, countOverflow) = buffer.width.multipliedReportingOverflow(by: buffer.height)
    let (bytesPerRow, rowOverflow) = buffer.width.multipliedReportingOverflow(by: 8)
    guard buffer.width > 0, buffer.height > 0, !countOverflow, !rowOverflow,
      count == buffer.pixels.count
    else { throw PrintroomError.invalid("预览像素尺寸不匹配") }
    let space: CGColorSpace
    if original {
      // Source samples stay linear P3; only the display copy is color managed.
      space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
    } else if let profile, !diagnostic, let iccSpace = CGColorSpace(iccData: profile as CFData) {
      space = iccSpace
    } else {
      space = CGColorSpace(name: CGColorSpace.sRGB)!
    }
    // Float32 CGImages darken the actual photo in the current window rendering path.
    // Quantize only the SDR presentation copy; LUT output is already gamma encoded.
    // Pipeline buffers, original-pixel readouts, and export never consume this copy.
    let pixels: [SIMD4<UInt16>] = try buffer.pixels.map { pixel in
      guard pixel.x.isFinite, pixel.y.isFinite, pixel.z.isFinite else {
        throw PrintroomError.invalid("预览包含非有限 RGB 数值")
      }
      func quantize(_ value: Float) -> UInt16 {
        UInt16(floor(Double(min(1, max(0, value))) * 65535 + 0.5)).littleEndian
      }
      return SIMD4(quantize(pixel.x), quantize(pixel.y), quantize(pixel.z), UInt16.max)
    }
    let data = pixels.withUnsafeBytes { Data($0) }
    guard let provider = CGDataProvider(data: data as CFData),
      let image = CGImage(
        width: buffer.width, height: buffer.height, bitsPerComponent: 16, bitsPerPixel: 64,
        bytesPerRow: bytesPerRow, space: space,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue).union(
          .byteOrder16Little
        ), provider: provider, decode: nil, shouldInterpolate: true,
        intent: .relativeColorimetric)
    else { throw PrintroomError.invalid("无法建立带 ICC 的预览图像") }
    return image
  }
}

struct AppAssets: Sendable {
  let lut: CubeLUT
  let fujifilmLUT: CubeLUT
  func lut(for selection: CineonLogLUT) -> CubeLUT { selection == .kodak2383 ? lut : fujifilmLUT }
  let profile: Data
  let gpu: MetalPipeline
  init() throws {
    let candidates = [
      Bundle.main.resourceURL?.appendingPathComponent("Assets"),
      URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
    ].compactMap { $0 }
    guard
      let root = candidates.first(where: {
        FileManager.default.fileExists(atPath: $0.appendingPathComponent("ICC/DCIP3_D65.icc").path)
      })
    else { throw PrintroomError.invalid("缺少随应用提供的 ICC 和 LUT 资源") }
    profile = try Data(contentsOf: root.appendingPathComponent("ICC/DCIP3_D65.icc"))
    let lutURL = root.appendingPathComponent(CineonLogLUT.kodak2383.path)
    let lutData = try Data(contentsOf: lutURL)
    func digest(_ data: Data) -> String {
      SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    guard digest(profile) == ProjectAssetIdentity.expectedICCSHA256,
      digest(lutData) == CineonLogLUT.kodak2383.sha256
    else { throw PrintroomError.invalid("ICC / LUT 与已登记资产不一致，请重新构建应用") }
    lut = try CubeLUT(url: lutURL)
    let fujiURL = root.appendingPathComponent(CineonLogLUT.fujifilm3513DI.path)
    guard try digest(Data(contentsOf: fujiURL)) == CineonLogLUT.fujifilm3513DI.sha256 else {
      throw PrintroomError.invalid("Fujifilm LUT 与已登记资产不一致，请重新构建应用")
    }
    fujifilmLUT = try CubeLUT(url: fujiURL)
    gpu = try MetalPipeline()
  }
}
