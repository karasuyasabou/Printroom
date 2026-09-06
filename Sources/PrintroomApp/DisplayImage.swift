import AppKit
import CryptoKit
import PrintroomCore

struct DisplayImage {
  static func make(_ buffer: PixelBuffer, profile: Data?, diagnostic: Bool = false) throws
    -> CGImage
  {
    let space: CGColorSpace
    if let profile, !diagnostic, let iccSpace = CGColorSpace(iccData: profile as CFData) {
      space = iccSpace
    } else {
      space = CGColorSpace(name: CGColorSpace.sRGB)!
    }
    let pixels =
      diagnostic
      ? buffer.pixels.map {
        SIMD4<Float>(min(1, max(0, $0.x)), min(1, max(0, $0.y)), min(1, max(0, $0.z)), 1)
      } : buffer.pixels
    let data = pixels.withUnsafeBytes { Data($0) }
    guard let provider = CGDataProvider(data: data as CFData),
      let image = CGImage(
        width: buffer.width, height: buffer.height, bitsPerComponent: 32, bitsPerPixel: 128,
        bytesPerRow: buffer.width * 16, space: space,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue).union(
          .byteOrder32Little
        ).union(.floatComponents), provider: provider, decode: nil, shouldInterpolate: true,
        intent: .relativeColorimetric)
    else { throw PrintroomError.invalid("无法建立带 ICC 的预览图像") }
    return image
  }
}

struct AppAssets: Sendable {
  let lut: CubeLUT
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
    let lutURL = root.appendingPathComponent("LUT/DCI-P3 Kodak 2383 D65.cube")
    let lutData = try Data(contentsOf: lutURL)
    func digest(_ data: Data) -> String {
      SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    guard digest(profile) == ProjectAssetIdentity.expectedICCSHA256,
      digest(lutData) == ProjectAssetIdentity.expectedLUTSHA256
    else { throw PrintroomError.invalid("ICC / LUT 与已登记资产不一致，请重新构建应用") }
    lut = try CubeLUT(url: lutURL)
    gpu = try MetalPipeline()
  }
}
