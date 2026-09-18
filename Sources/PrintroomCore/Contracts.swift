import Foundation

let migratingLegacyMatrices = CodingUserInfoKey(rawValue: "printroom.migratingLegacyMatrices")!

public let algorithmVersion = "printroom-density-v6"
public let contrastPivotCV: Int = 685
public enum PipelineStage: Int, CaseIterable, Codable, Sendable {
  case l0, l1, l2, d0, d1, d2, d3, final
  public var label: String { ["L0", "L1", "L2", "D0", "D1", "D2", "D3", "Final"][rawValue] }
}
public struct TimingParameters: Codable, Equatable, Sendable {
  public static let range = -512...512
  public var master: Int = 0, red: Int = 0, green: Int = 0, blue: Int = 0
  public init(master: Int = 0, red: Int = 0, green: Int = 0, blue: Int = 0) {
    self.master = master
    self.red = red
    self.green = green
    self.blue = blue
  }
}
public struct ContrastParameters: Codable, Equatable, Sendable {
  public var master: Float = 1, red: Float = 1, green: Float = 1, blue: Float = 1
  public init(master: Float = 1, red: Float = 1, green: Float = 1, blue: Float = 1) {
    self.master = master
    self.red = red
    self.green = green
    self.blue = blue
  }
}
public enum CineonLogLUT: String, CaseIterable, Codable, Sendable {
  case fujifilm3513DI, kodak2383
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let raw = try container.decode(String.self)
    if raw == "neutral" { self = .kodak2383 }
    else if let selection = Self(rawValue: raw) { self = selection }
    else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "未知 LUT：\(raw)") }
  }
  public var label: String {
    switch self {
    case .kodak2383: "Kodak 2383"
    case .fujifilm3513DI: "Fujifilm 3513DI"
    }
  }
  public var path: String {
    switch self {
    case .kodak2383: "assets/DerivedLUTs/diffuse-white-v1/Kodak 2383.cube"
    case .fujifilm3513DI: "assets/DerivedLUTs/diffuse-white-v1/Fujifilm 3513DI.cube"
    }
  }
  public var sha256: String {
    switch self {
    case .kodak2383: "652199a63b1d38998dbd70247d6ea13c8c17963cfcdc0fc0508a42056739a207"
    case .fujifilm3513DI: "03839ed74c1d52766d3b1ae200460260cb0a0078e8f666b00c483fc695ee0757"
    }
  }
}
public struct FrameAdjustments: Codable, Equatable, Sendable {
  public var timing = TimingParameters()
  public var contrast = ContrastParameters()
  public var cineonLogLUT: CineonLogLUT = .kodak2383
  public init(timing: TimingParameters = .init(), contrast: ContrastParameters = .init(), cineonLogLUT: CineonLogLUT = .kodak2383) {
    self.timing = timing
    self.contrast = contrast
    self.cineonLogLUT = cineonLogLUT
  }
  private enum CodingKeys: CodingKey { case timing, contrast, cineonLogLUT }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    timing = try c.decode(TimingParameters.self, forKey: .timing)
    contrast = try c.decode(ContrastParameters.self, forKey: .contrast)
    cineonLogLUT = try c.decodeIfPresent(CineonLogLUT.self, forKey: .cineonLogLUT) ?? .kodak2383
  }
}
public struct PixelRect: Codable, Equatable, Sendable {
  public var x: Int, y: Int, width: Int, height: Int
  public init(x: Int, y: Int, width: Int, height: Int) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }
}
public struct FilmCalibration: Codable, Equatable, Sendable {
  public var matrix: PrintDensityMatrix = .identity
  public var cmosMatrix: MatrixPreset = .identity
  /// Provenance of the most recent successful film-base alignment.
  public var sampledDensityMatrix: MatrixPreset = .identity
  public var sampledCMOSMatrix: MatrixPreset = .identity
  public var baseRGB: SIMD3<Float>?
  public var gainRGB = SIMD3<Float>(repeating: 1)
  public var filmBaseOffsetCV = SIMD3<Float>(repeating: 0)
  public var sourceFrameID: UUID?
  public var selection: PixelRect?
  public var sourceWidth: Int?
  public var sourceHeight: Int?
  public var isCalibrated: Bool { baseRGB != nil }
  public init() {}
  private enum CodingKeys: CodingKey {
    case matrix, cmosMatrix, sampledDensityMatrix, sampledCMOSMatrix
    case baseRGB, gainRGB, filmBaseOffsetCV, sourceFrameID, selection, sourceWidth, sourceHeight
  }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let decodedMatrix = try c.decodeIfPresent(MatrixPreset.self, forKey: .matrix)
    let decodedCMOS = try c.decodeIfPresent(MatrixPreset.self, forKey: .cmosMatrix)
    // A partially written project may contain only one side of the pair.
    // Keep that value for both roles; use Identity only when neither exists.
    let present = decodedMatrix ?? decodedCMOS ?? .identity
    matrix = decodedMatrix ?? present
    if decoder.userInfo[migratingLegacyMatrices] as? Bool == true {
      // Legacy projects only stored one matrix (the density matrix). Reuse
      // that value for CMOS as well instead of silently introducing Identity.
      // This keeps a non-Identity legacy selection active after migration.
      guard present.isBuiltIn else {
        throw PrintroomError.invalid("旧项目含有未定义的自定义矩阵设置。")
      }
      matrix = present
      cmosMatrix = present
      sampledCMOSMatrix = present
      sampledDensityMatrix = present
    } else {
      // Matrix files from intermediate builds may contain only one of the
      // paired values. When that happens, use the value that is present on
      // the other side; Identity is only used when neither side has a value.
      cmosMatrix = decodedCMOS ?? matrix
      let decodedSampledDensity = try c.decodeIfPresent(MatrixPreset.self, forKey: .sampledDensityMatrix)
      sampledDensityMatrix = decodedSampledDensity ?? matrix
      let decodedSampledCMOS = try c.decodeIfPresent(MatrixPreset.self, forKey: .sampledCMOSMatrix)
      sampledCMOSMatrix = decodedSampledCMOS ?? cmosMatrix
    }
    baseRGB = try c.decodeIfPresent(SIMD3<Float>.self, forKey: .baseRGB)
    gainRGB = try c.decode(SIMD3<Float>.self, forKey: .gainRGB)
    filmBaseOffsetCV = try c.decode(SIMD3<Float>.self, forKey: .filmBaseOffsetCV)
    sourceFrameID = try c.decodeIfPresent(UUID.self, forKey: .sourceFrameID)
    selection = try c.decodeIfPresent(PixelRect.self, forKey: .selection)
    sourceWidth = try c.decodeIfPresent(Int.self, forKey: .sourceWidth)
    sourceHeight = try c.decodeIfPresent(Int.self, forKey: .sourceHeight)
  }
}
public struct PixelBuffer: Sendable {
  public let width: Int, height: Int
  public var pixels: [SIMD4<Float>]
  public init(width: Int, height: Int, pixels: [SIMD4<Float>]) {
    self.width = width
    self.height = height
    self.pixels = pixels
  }
}
public struct LinearImage: Sendable {
  public let width: Int, height: Int
  public let samples: [UInt16]
  public let embeddedProfileName: String
  public init(width: Int, height: Int, samples: [UInt16], embeddedProfileName: String = "无嵌入 ICC") {
    self.width = width
    self.height = height
    self.samples = samples
    self.embeddedProfileName = embeddedProfileName
  }
  public func pixel(x: Int, y: Int) -> SIMD3<Float> {
    let i = (y * width + x) * 3
    return SIMD3(Float(samples[i]), Float(samples[i + 1]), Float(samples[i + 2])) / 65535
  }
  public func preview(maxDimension: Int = 1500) -> PixelBuffer {
    let scale = min(1, Double(maxDimension) / Double(max(width, height)))
    let w = max(1, Int(Double(width) * scale))
    let h = max(1, Int(Double(height) * scale))
    var out = [SIMD4<Float>]()
    out.reserveCapacity(w * h)
    for y in 0..<h {
      for x in 0..<w {
        let p = pixel(x: min(width - 1, x * width / w), y: min(height - 1, y * height / h))
        out.append(SIMD4(p, 1))
      }
    }
    return PixelBuffer(width: w, height: h, pixels: out)
  }
}
public enum PrintroomError: LocalizedError {
  case invalid(String)
  public var errorDescription: String? {
    switch self {
    case .invalid(let message): message
    }
  }
}
