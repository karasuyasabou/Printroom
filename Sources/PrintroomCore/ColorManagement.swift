import CryptoKit
import Foundation
import simd

/// These profiles are fixed application resources, never a display profile or an
/// OS-dependent substitute. P3 retains the user's original ICC byte for byte.
public enum OutputColorProfile: String, Codable, CaseIterable, Sendable {
  case p3, sRGB, adobeRGB, proPhoto

  public var label: String {
    switch self {
    case .p3: "P3-D65 Gamma 2.6"
    case .sRGB: "sRGB"
    case .adobeRGB: "Adobe RGB (1998)"
    case .proPhoto: "ProPhoto RGB · D50"
    }
  }

  public var profileSHA256: String {
    switch self {
    case .p3: "eafc15fd36e56bc496b084d3aaacbdca419e65e03fac9a1930d024b1e8d9b32b"
    case .sRGB: "2b3aa1645779a9e634744faf9b01e9102b0c9b88fd6deced7934df86b949af7e"
    case .adobeRGB: "304f569a83c1e5eddaddac54e99ed03339333db013738bb499ab64f049887e28"
    case .proPhoto: "182b9b32b503955f137f5a4a9d5dc0ce8d6cc514949a3d88dddb795ec5df08da"
    }
  }

  public func profileData(p3: Data) throws -> Data {
    let data: Data
    if self == .p3 {
      data = p3
    } else {
      let name: String
      switch self {
      case .sRGB: name = "sRGB"
      case .adobeRGB: name = "AdobeRGB1998"
      case .proPhoto: name = "ProPhotoRGB"
      case .p3: name = ""
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

/// A matrix/TRC ICC CMM for the application's four SHA-pinned RGB profiles.
/// It consumes the already encoded Final values, decodes the *source ICC* TRC,
/// transforms through D50 PCS colorants, then applies the inverse destination TRC.
/// Profile colorants already contain chromatic adaptation: never apply chad twice.
///
/// Deliberately evaluate the ICC definitions rather than Apple's Float32 CMM:
/// the latter linearizes pure-gamma dark values (P3 .02 becomes .02 in ProPhoto,
/// instead of 16 * .02^2.600006 = .000612051). Double precision avoids reducing
/// Float32 pipeline precision; quantization occurs once, after this conversion.
public final class OutputColorConverter {
  public let outputProfile: Data
  public let profile: OutputColorProfile
  private let source: MatrixICCProfile?
  private let destination: MatrixICCProfile?
  private let matrix: simd_double3x3?

  public init(p3Profile: Data, output: OutputColorProfile) throws {
    let sourceData = try OutputColorProfile.p3.profileData(p3: p3Profile)
    outputProfile = try output.profileData(p3: p3Profile)
    profile = output
    if output == .p3 {
      source = nil
      destination = nil
      matrix = nil
    } else {
      let from = try MatrixICCProfile(sourceData)
      let to = try MatrixICCProfile(outputProfile)
      source = from
      destination = to
      matrix = to.colorants.inverse * from.colorants
    }
  }

  public func convert(_ final: PixelBuffer) throws -> PixelBuffer {
    guard final.width > 0, final.height > 0,
      final.width <= Int.max / final.height,
      final.pixels.count == final.width * final.height,
      final.pixels.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
    else { throw PrintroomError.invalid("输出转换输入尺寸或数值无效。") }
    guard let source, let destination, let matrix else { return final }
    var pixels = [SIMD4<Float>]()
    pixels.reserveCapacity(final.pixels.count)
    for (index, pixel) in final.pixels.enumerated() {
      if index % 16384 == 0 { try Task.checkCancellation() }
      let linear = SIMD3(
        source.curves[0].decode(Double(pixel.x)),
        source.curves[1].decode(Double(pixel.y)), source.curves[2].decode(Double(pixel.z)))
      let converted = matrix * linear
      let encoded = SIMD4(
        Float(destination.curves[0].encode(converted.x)),
        Float(destination.curves[1].encode(converted.y)),
        Float(destination.curves[2].encode(converted.z)), 1)
      guard encoded.x.isFinite, encoded.y.isFinite, encoded.z.isFinite else {
        throw PrintroomError.invalid("ICC 输出转换产生非有限数值。")
      }
      pixels.append(encoded)
    }
    return PixelBuffer(width: final.width, height: final.height, pixels: pixels)
  }

  /// The only output clamp/quantization. No dithering or transfer function here.
  public func quantized(_ final: PixelBuffer) throws -> [UInt16] {
    let converted = try convert(final)
    var samples = [UInt16]()
    samples.reserveCapacity(converted.pixels.count * 3)
    for pixel in converted.pixels {
      for channel in 0..<3 {
        samples.append(UInt16(floor(min(1, max(0, pixel[channel])) * 65535 + 0.5)))
      }
    }
    return samples
  }
}

private struct MatrixICCProfile {
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

private enum ICCToneCurve {
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

extension Data {
  fileprivate func big32(_ offset: Int) -> UInt32 {
    UInt32(self[offset]) << 24 | UInt32(self[offset + 1]) << 16
      | UInt32(self[offset + 2]) << 8 | UInt32(self[offset + 3])
  }
  fileprivate func fixed(_ offset: Int) -> Double {
    Double(Int32(bitPattern: big32(offset))) / 65536
  }
}
