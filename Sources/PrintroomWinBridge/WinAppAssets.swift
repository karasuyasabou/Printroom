import Foundation
import PrintroomCore

public struct WinAppAssets: Sendable {
  public let lut: CubeLUT
  public let fujifilmLUT: CubeLUT
  public let profile: Data
  public let gpu: MetalPipeline
  public let displayColor: WinDisplayColor
  public let rootDirectory: URL

  public func lut(for selection: CineonLogLUT) -> CubeLUT {
    selection == .kodak2383 ? lut : fujifilmLUT
  }

  public init(explicitRoot: String? = nil) throws {
    let exeURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments.first ?? "")
    let exeDir = exeURL.deletingLastPathComponent()
    let candidates = [
      explicitRoot.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) },
      exeDir.appendingPathComponent("Assets", isDirectory: true),
      exeDir,
      URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
    ].compactMap { $0 }

    guard let root = candidates.first(where: {
      FileManager.default.fileExists(atPath: $0.appendingPathComponent("ICC/DCIP3_D65.icc").path)
    }) else {
      throw PrintroomError.invalid("缺少随应用提供的 ICC 和 LUT 资源")
    }
    self.rootDirectory = root

    let profileData = try Data(contentsOf: root.appendingPathComponent("ICC/DCIP3_D65.icc"))
    guard Self.sha256Hex(profileData) == ProjectAssetIdentity.expectedICCSHA256 else {
      throw PrintroomError.invalid("ICC 与已登记资产不一致，请重新构建应用")
    }
    self.profile = profileData

    let kodakURL = root.appendingPathComponent(CineonLogLUT.kodak2383.path)
    let kodakData = try Data(contentsOf: kodakURL)
    guard Self.sha256Hex(kodakData) == CineonLogLUT.kodak2383.sha256 else {
      throw PrintroomError.invalid("Kodak 2383 LUT 与已登记资产不一致，请重新构建应用")
    }
    self.lut = try CubeLUT(url: kodakURL)

    let fujiURL = root.appendingPathComponent(CineonLogLUT.fujifilm3513DI.path)
    let fujiData = try Data(contentsOf: fujiURL)
    guard Self.sha256Hex(fujiData) == CineonLogLUT.fujifilm3513DI.sha256 else {
      throw PrintroomError.invalid("Fujifilm LUT 与已登记资产不一致，请重新构建应用")
    }
    self.fujifilmLUT = try CubeLUT(url: fujiURL)

    // Verify all 5 OutputColorProfile resources are present & hash-valid
    for outputProfile in OutputColorProfile.allCases {
      _ = try outputProfile.profileData(p3: profileData)
    }

    self.gpu = try MetalPipeline()
    self.displayColor = try WinDisplayColor(p3Profile: profileData)
  }

  public static func verifyResources(explicitRoot: String? = nil) throws -> String {
    let assets = try WinAppAssets(explicitRoot: explicitRoot)
    // Smoke-test Direct3D 11 GPU render and monitor ICC transform on 2x2 patch
    let pixels = [SIMD4<Float>(0.2, 0.25, 0.3, 1), SIMD4<Float>(0.4, 0.5, 0.6, 1),
                  SIMD4<Float>(0.7, 0.6, 0.5, 1), SIMD4<Float>(0.9, 0.85, 0.8, 1)]
    let buf = PixelBuffer(width: 2, height: 2, pixels: pixels)
    let out = try assets.gpu.render(buf, calibration: .init(), adjustments: .init(), lut: assets.lut)
    let bmp = try assets.displayColor.makeDisplayBitmap(out)
    guard bmp.bgra8.count == 16 else {
      throw PrintroomError.invalid("显示色彩转换自检失败")
    }
    let iccDesc = assets.displayColor.activeMonitorProfilePath ?? "sRGB fallback"
    return "OK: GPU=\(assets.gpu.deviceName); MonitorICC=\(iccDesc); LibRaw=\(RawDecoder.version)"
  }

  private static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
