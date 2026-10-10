import CryptoKit
import Foundation
import simd

/// These profiles are fixed application resources, never a display profile or an
/// OS-dependent substitute. The native LUT ICC is separate from export choices.
public enum OutputColorProfile: String, Codable, CaseIterable, Sendable {
  case sRGB, displayP3, adobeRGB, proPhoto, rec2020

  /// User-facing order matching the export menu.
  public static let selectable: [Self] = allCases

  public var label: String {
    switch self {
    case .sRGB: "sRGB IEC61966-2.1"
    case .displayP3: "Display P3"
    case .rec2020: "Rec. 2020"
    case .adobeRGB: "Adobe RGB (1998)"
    case .proPhoto: "ProPhoto RGB"
    }
  }

  public var profileSHA256: String {
    switch self {
    case .displayP3: "0ff6958f98684c61f6bbdce1368ddeaf3873baf84545baba482e920d92a914c0"
    case .rec2020: "7a7306ed028c8bb967ddcaf9b609fe5ac794120fb24e3d9f6efec67d5ac9a2ab"
    case .sRGB: "2b3aa1645779a9e634744faf9b01e9102b0c9b88fd6deced7934df86b949af7e"
    case .adobeRGB: "304f569a83c1e5eddaddac54e99ed03339333db013738bb499ab64f049887e28"
    case .proPhoto: "182b9b32b503955f137f5a4a9d5dc0ce8d6cc514949a3d88dddb795ec5df08da"
    }
  }

  public func profileData(p3: Data) throws -> Data {
    let data: Data
    do {
      let name: String
      switch self {
      case .sRGB: name = "sRGB"
      case .adobeRGB: name = "AdobeRGB1998"
      case .proPhoto: name = "ProPhotoRGB"
      case .displayP3: name = "DisplayP3"
      case .rec2020: name = "Rec2020"
      }
      let packagedBundle = Bundle.main.resourceURL?
        .appendingPathComponent("Printroom_PrintroomCore.bundle")
      let bundle: Bundle
      if let packaged = packagedBundle.flatMap({ Bundle(url: $0) }) {
        bundle = packaged
      } else if Bundle.main.bundleURL.pathExtension.lowercased() == "app" {
        throw PrintroomError.invalid("应用包缺少输出 ICC 资源包，请重新构建应用。")
      } else {
        bundle = Bundle.module
      }
      guard let url = bundle.url(forResource: name, withExtension: "icc") else {
        throw PrintroomError.invalid("缺少输出 ICC：\(label)")
      }
      data = try Data(contentsOf: url)
    }
    guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == profileSHA256
    else {
      throw PrintroomError.invalid("输出 ICC 指纹不匹配：\(label)")
    }
    return data
  }
}

public enum TIFFCompression: String, Codable, CaseIterable, Sendable {
  case none, deflate
  public var label: String { self == .none ? "无压缩" : "ZIP / Deflate（无损）" }
}

/// A matrix/TRC ICC CMM for the application's SHA-pinned RGB profiles.
/// It consumes the already encoded Final values, decodes the *source ICC* TRC,
/// transforms through D50 PCS colorants, then applies the inverse destination TRC.
/// Profile colorants already contain chromatic adaptation: never apply chad twice.
///
/// Deliberately evaluate the ICC definitions rather than Apple's Float32 CMM:
/// the latter linearizes pure-gamma dark values (P3 .02 becomes .02 in ProPhoto,
/// instead of 16 * .02^2.600006 = .000612051). Double precision avoids reducing
/// Float32 pipeline precision. High-resolution relative-domain TRC interpolation
/// replaces per-pixel powers; boundary/out-of-domain values use the analytic curve.
/// Quantization occurs once, after this conversion.
public final class OutputColorConverter {
  public let outputProfile: Data
  public let profile: OutputColorProfile
  private let source: MatrixICCProfile
  private let destination: MatrixICCProfile
  private let matrix: simd_double3x3
  private let decodeTables: [FastICCCurve]
  private let encodeTables: [FastICCCurve]

  public init(p3Profile: Data, output: OutputColorProfile) throws {
    let sourceData = try nativeLUTProfile(p3Profile)
    outputProfile = try output.profileData(p3: p3Profile)
    profile = output
    let from = try MatrixICCProfile(sourceData)
    let to = try MatrixICCProfile(outputProfile)
    source = from
    destination = to
    matrix = to.colorants.inverse * from.colorants
    // Array storage is shared for identical RGB curves; converters remain immutable.
    func tables(_ curves: [ICCToneCurve], inverse: Bool) -> [FastICCCurve] {
      var result: [FastICCCurve] = []
      for i in curves.indices {
        if let previous = (0..<i).first(where: { curves[$0] == curves[i] }) {
          result.append(result[previous])
        } else { result.append(FastICCCurve(curves[i], inverse: inverse)) }
      }
      return result
    }
    #if PRINTROOM_PERFORMANCE_TRACE
    if ProcessInfo.processInfo.environment["PRINTROOM_ICC_REFERENCE"] == "1" {
      decodeTables = []; encodeTables = []
      return
    }
    #endif
    decodeTables = tables(from.curves, inverse: false)
    encodeTables = tables(to.curves, inverse: true)
  }

  public func convert(_ final: PixelBuffer) throws -> PixelBuffer {
    #if PRINTROOM_PERFORMANCE_TRACE
    if ProcessInfo.processInfo.environment["PRINTROOM_ICC_REFERENCE"] == "1" {
      return try convertReference(final)
    }
    #endif
    return try convertImpl(final, accelerated: true)
  }

  /// Analytic oracle retained for numerical verification and opt-in Release A/B.
  func convertReference(_ final: PixelBuffer) throws -> PixelBuffer {
    try convertImpl(final, accelerated: false)
  }

  private func convertImpl(_ final: PixelBuffer, accelerated: Bool) throws -> PixelBuffer {
    guard final.width > 0, final.height > 0,
      final.width <= Int.max / final.height,
      final.pixels.count == final.width * final.height,
      final.pixels.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
    else { throw PrintroomError.invalid("输出转换输入尺寸或数值无效。") }
    var pixels = [SIMD4<Float>]()
    pixels.reserveCapacity(final.pixels.count)
    for (index, pixel) in final.pixels.enumerated() {
      if index % 16384 == 0 { try Task.checkCancellation() }
      let linear = SIMD3(
        accelerated ? decodeTables[0].evaluate(Double(pixel.x)) : source.curves[0].decode(Double(pixel.x)),
        accelerated ? decodeTables[1].evaluate(Double(pixel.y)) : source.curves[1].decode(Double(pixel.y)), accelerated ? decodeTables[2].evaluate(Double(pixel.z)) : source.curves[2].decode(Double(pixel.z)))
      let converted = matrix * linear
      let encoded = SIMD4(
        Float(accelerated ? encodeTables[0].evaluate(converted.x) : destination.curves[0].encode(converted.x)),
        Float(accelerated ? encodeTables[1].evaluate(converted.y) : destination.curves[1].encode(converted.y)),
        Float(accelerated ? encodeTables[2].evaluate(converted.z) : destination.curves[2].encode(converted.z)), 1)
      guard encoded.x.isFinite, encoded.y.isFinite, encoded.z.isFinite else {
        throw PrintroomError.invalid("ICC 输出转换产生非有限数值。")
      }
      pixels.append(encoded)
    }
    return PixelBuffer(width: final.width, height: final.height, pixels: pixels)
  }

  public func quantized8(_ final: PixelBuffer) throws -> [UInt8] {
    try Self.quantize8(convert(final))
  }

  public static func quantize8(_ converted: PixelBuffer) throws -> [UInt8] {
    try validateConverted(converted)
    var samples = [UInt8](repeating: 0, count: converted.pixels.count * 3)
    var offset = 0
    for pixel in converted.pixels {
      for channel in 0..<3 {
        samples[offset] = UInt8(floor(min(1, max(0, pixel[channel])) * 255 + 0.5))
        offset += 1
      }
    }
    return samples
  }

  /// The only output clamp/quantization. No dithering or transfer function here.
  public func quantized(_ final: PixelBuffer) throws -> [UInt16] {
    try Self.quantize16(convert(final))
  }

  public static func quantize16(_ converted: PixelBuffer) throws -> [UInt16] {
    try validateConverted(converted)
    var samples = [UInt16]()
    samples.reserveCapacity(converted.pixels.count * 3)
    for pixel in converted.pixels {
      for channel in 0..<3 {
        samples.append(UInt16(floor(min(1, max(0, pixel[channel])) * 65535 + 0.5)))
      }
    }
    return samples
  }
  private static func validateConverted(_ converted: PixelBuffer) throws {
    guard converted.width > 0, converted.height > 0, converted.width <= Int.max / converted.height,
      converted.pixels.count == converted.width * converted.height,
      converted.pixels.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else {
      throw PrintroomError.invalid("输出量化输入尺寸或数值无效。")
    }
  }
}

/// Read-only Final measurements using the same pinned ICC definitions as export.
/// Decoded values never feed back into the image rendering pipeline.
struct FinalColorimetry {
  private let profile: MatrixICCProfile
  private let white: SIMD3<Double>

  init(p3Profile: Data) throws {
    profile = try MatrixICCProfile(nativeLUTProfile(p3Profile))
    white = profile.colorants * SIMD3<Double>(repeating: 1)
  }

  func linearRGB(_ encoded: SIMD3<Double>) -> SIMD3<Double> {
    SIMD3(
      profile.curves[0].decode(encoded.x), profile.curves[1].decode(encoded.y),
      profile.curves[2].decode(encoded.z))
  }

  func neutralMatchingLuminance(_ encoded: SIMD3<Double>) -> SIMD3<Double> {
    let y = (profile.colorants * linearRGB(encoded)).y / white.y
    // The SHA-pinned working profile has identical pure-gamma RGB curves.
    return SIMD3(repeating: profile.curves[0].encode(y))
  }

  func lab(_ encoded: SIMD3<Double>) -> SIMD3<Double> {
    labFromLinear(linearRGB(encoded))
  }

  func labFromLinear(_ linear: SIMD3<Double>) -> SIMD3<Double> {
    let relative = (profile.colorants * linear) / white
    func f(_ t: Double) -> Double {
      t > pow(6.0 / 29, 3) ? cbrt(t) : t / (3 * pow(6.0 / 29, 2)) + 4.0 / 29
    }
    let x = f(relative.x), y = f(relative.y), z = f(relative.z)
    return SIMD3(116 * y - 16, 500 * (x - y), 200 * (y - z))
  }
}

struct MatrixICCProfile {
  let colorants: simd_double3x3
  let curves: [ICCToneCurve]

  init(_ data: Data) throws {
    guard data.count >= 132, String(data: data[16..<20], encoding: .ascii) == "RGB ",
      String(data: data[20..<24], encoding: .ascii) == "XYZ "
    else {
      throw PrintroomError.invalid("输出只支持已验证的 RGB/XYZ matrix/TRC ICC。")
    }
    var tags: [String: Data] = [:]
    let count = Int(data.big32(128))
    guard count <= (data.count - 132) / 12 else { throw PrintroomError.invalid("ICC 标签目录无效。") }
    for index in 0..<count {
      let record = 132 + index * 12
      let name = String(data: data[record..<(record + 4)], encoding: .ascii) ?? ""
      let offset = Int(data.big32(record + 4))
      let length = Int(data.big32(record + 8))
      guard offset <= data.count, length <= data.count - offset else {
        throw PrintroomError.invalid("ICC 标签越界。")
      }
      tags[name] = data.subdata(in: offset..<(offset + length))
    }
    func xyz(_ name: String) throws -> SIMD3<Double> {
      guard let tag = tags[name], tag.count >= 20, tag.prefix(4) == Data("XYZ ".utf8) else {
        throw PrintroomError.invalid("ICC 缺少 XYZ colorant：\(name)")
      }
      return SIMD3(tag.fixed(8), tag.fixed(12), tag.fixed(16))
    }
    colorants = try simd_double3x3(columns: (xyz("rXYZ"), xyz("gXYZ"), xyz("bXYZ")))
    guard abs(colorants.determinant) > 1e-12 else {
      throw PrintroomError.invalid("ICC colorants 不可逆。")
    }
    curves = try ["rTRC", "gTRC", "bTRC"].map { name in
      guard let tag = tags[name] else { throw PrintroomError.invalid("ICC 缺少 TRC：\(name)") }
      return try ICCToneCurve(tag)
    }
  }
}

enum ICCToneCurve: Equatable {
  case gamma(Double)
  case piecewise(gamma: Double, a: Double, b: Double, c: Double, d: Double)
  case table([Double])

  init(_ data: Data) throws {
    guard data.count >= 12 else { throw PrintroomError.invalid("ICC TRC 不完整。") }
    if data.prefix(4) == Data("para".utf8) {
      let function = Int(data[8]) * 256 + Int(data[9])
      if function == 0, data.count >= 16 {
        self = .gamma(data.fixed(12))
        return
      }
      if function == 3, data.count >= 32 {
        self = .piecewise(
          gamma: data.fixed(12), a: data.fixed(16), b: data.fixed(20),
          c: data.fixed(24), d: data.fixed(28))
        return
      }
    } else if data.prefix(4) == Data("curv".utf8) {
      let count = Int(data.big32(8))
      if count == 0 {
        self = .gamma(1)
        return
      }
      if count == 1, data.count >= 14 {
        self = .gamma(Double(Int(data[12]) * 256 + Int(data[13])) / 256)
        return
      }
      if count >= 2, count <= (data.count - 12) / 2 {
        let entries = (0..<count).map { index in
          Double(Int(data[12 + index * 2]) * 256 + Int(data[13 + index * 2])) / 65535
        }
        guard zip(entries, entries.dropFirst()).allSatisfy({ $0 <= $1 }) else {
          throw PrintroomError.invalid("ICC TRC 表不是单调递增。")
        }
        self = .table(entries)
        return
      }
    }
    throw PrintroomError.invalid("输出 ICC 含未验证的 TRC 类型。")
  }

  private func signedPower(_ value: Double, _ exponent: Double) -> Double {
    value < 0 ? -pow(-value, exponent) : pow(value, exponent)
  }

  func decode(_ encoded: Double) -> Double {
    switch self {
    case .gamma(let gamma): return signedPower(encoded, gamma)
    case .piecewise(let gamma, let a, let b, let c, let d):
      return encoded < d ? c * encoded : pow(a * encoded + b, gamma)
    case .table(let entries):
      let scaled = encoded * Double(entries.count - 1)
      let lower = max(0, min(entries.count - 2, Int(floor(scaled))))
      return entries[lower] + (entries[lower + 1] - entries[lower]) * (scaled - Double(lower))
    }
  }

  func encode(_ linear: Double) -> Double {
    switch self {
    case .gamma(let gamma): return signedPower(linear, 1 / gamma)
    case .piecewise(let gamma, let a, let b, let c, let d):
      return linear < c * d ? linear / c : (pow(linear, 1 / gamma) - b) / a
    case .table(let entries):
      // Invert the exact ICC sampled curve using a binary search, with no new
      // resampling table or hidden 8/16-bit intermediate quantization.
      var lower = 0
      var upper = entries.count - 1
      while upper - lower > 1 {
        let middle = (lower + upper) / 2
        if entries[middle] <= linear { lower = middle } else { upper = middle }
      }
      let delta = entries[upper] - entries[lower]
      let fraction = delta > 0 ? (linear - entries[lower]) / delta : 0
      return (Double(lower) + fraction) / Double(entries.count - 1)
    }
  }
}

/// 4096 linear intervals per binary octave, covering 2^-32 ... 2.
/// Bit indexing is exact for Double and needs neither log nor pow in the hot path.
/// Unlike a uniform linear-light table, relative resolution remains dense at black.
private struct FastICCCurve {
  private static let firstBits = Double(0x1p-32).bitPattern
  private static let shift: UInt64 = 40
  private let values: [Double]
  private let curve: ICCToneCurve
  private let inverse: Bool
  private let boundary: Double?

  init(_ curve: ICCToneCurve, inverse: Bool) {
    self.curve = curve
    self.inverse = inverse
    if case .piecewise(_, _, _, let c, let d) = curve {
      boundary = inverse ? c * d : d
    } else { boundary = nil }
    let count = Int((Double(2).bitPattern - Self.firstBits) >> Self.shift)
    values = (0...count).map { index in
      let x = Double(bitPattern: Self.firstBits + (UInt64(index) << Self.shift))
      return inverse ? curve.encode(x) : curve.decode(x)
    }
  }

  @inline(__always) func evaluate(_ x: Double) -> Double {
    guard x >= 0x1p-32, x < 2 else {
      return inverse ? curve.encode(x) : curve.decode(x)
    }
    let bits = x.bitPattern
    let index = Int((bits - Self.firstBits) >> Self.shift)
    let lowerBits = bits & ~((1 << Self.shift) - 1)
    let lower = Double(bitPattern: lowerBits)
    let upper = Double(bitPattern: lowerBits + (1 << Self.shift))
    // Never interpolate across a parametric TRC discontinuity.
    if let boundary, lower < boundary, upper >= boundary {
      return inverse ? curve.encode(x) : curve.decode(x)
    }
    let fraction = (x - lower) / (upper - lower)
    return values[index] + (values[index + 1] - values[index]) * fraction
  }
}

extension Data {
  fileprivate func big32(_ offset: Int) -> UInt32 {
    UInt32(self[offset]) << 24 | UInt32(self[offset + 1]) << 16
      | UInt32(self[offset + 2]) << 8 | UInt32(self[offset + 3])
  }
  fileprivate func fixed(_ offset: Int) -> Double {
    Double(Int32(bitPattern: big32(offset))) / 65536
  }
}

/// The LUT's immutable source interpretation is not an export option.
private func nativeLUTProfile(_ data: Data) throws -> Data {
  guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined()
    == ProjectAssetIdentity.expectedICCSHA256 else {
    throw PrintroomError.invalid("LUT 源 ICC 指纹不匹配。")
  }
  return data
}
