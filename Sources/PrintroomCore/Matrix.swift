import Foundation
import simd

/// Rows are output R/G/B; columns are input R/G/B. No implicit normalization.
public struct RGBMatrix: Codable, Hashable, Sendable {
  public let values: [Float]
  public init(_ values: [Float]) throws {
    guard values.count == 9, values.allSatisfy(\.isFinite) else {
      throw PrintroomError.invalid("矩阵需要九个有限数值。")
    }
    self.values = values
  }
  public static let identity = try! RGBMatrix([1,0,0, 0,1,0, 0,0,1])
  public static let led = try! RGBMatrix([1.0584,-0.0204,0.0023, 0.0753,1.0120,-0.0693, -0.0147,0.1420,0.7774])
  public func apply(_ v: SIMD3<Float>) -> SIMD3<Float> {
    // Preserve the old identity path exactly, including signed zeros.
    if self == .identity { return v }
    return SIMD3(values[0]*v.x + values[1]*v.y + values[2]*v.z,
                 values[3]*v.x + values[4]*v.y + values[5]*v.z,
                 values[6]*v.x + values[7]*v.y + values[8]*v.z)
  }
  public func row(_ index: Int) -> SIMD4<Float> {
    SIMD4(values[index*3], values[index*3+1], values[index*3+2], 0)
  }
  public init(from decoder: Decoder) throws {
    try self.init(decoder.singleValueContainer().decode([Float].self))
  }
  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(values)
  }
}

public struct MatrixPreset: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let name: String
  public let coefficients: RGBMatrix
  public var label: String { name }
  public var isBuiltIn: Bool { id == "identity" || id == "ledLightSource" || id == Self.sonyA7CII.id }
  public static let identity = MatrixPreset(builtin: "identity", name: "Identity", coefficients: .identity)
  public static let ledLightSource = MatrixPreset(builtin: "ledLightSource", name: "LED Light Source", coefficients: .led)
  // calibration_matrix.npy, float64 row-major; SHA256 recorded in docs/decisions.md.
  // Encode as a coefficient snapshot so older schema-5 readers retain the same image.
  public static let sonyA7CII = MatrixPreset(builtin: "6DA9259A-6676-48CF-AB02-9C3DBBE43762", name: "Sony A7C II",
    coefficients: try! RGBMatrix([
      1.1466704233413691, -0.11124903420598868, -0.035421389135380503,
      -0.22858890193068157, 1.7070179367809262, -0.47842903485024479,
      -0.016680585423849963, -0.23594647294799959, 1.2526270583718495]))
  public static let allCases: [Self] = [.identity, .ledLightSource]
  private init(builtin: String, name: String, coefficients: RGBMatrix) {
    id = builtin; self.name = name; self.coefficients = coefficients
  }
  public init(id: String = UUID().uuidString, name: String, coefficients: RGBMatrix) throws {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard UUID(uuidString: id) != nil, !name.isEmpty, name.count <= 80 else {
      throw PrintroomError.invalid("自定义矩阵需要有效标识及 1–80 字的名称。")
    }
    if id.uppercased() == Self.sonyA7CII.id {
      guard name == Self.sonyA7CII.name, coefficients == Self.sonyA7CII.coefficients else {
        throw PrintroomError.invalid("不能覆盖内置 Sony A7C II 矩阵。")
      }
      self = Self.sonyA7CII
      return
    }
    self.id = id; self.name = name; self.coefficients = coefficients
  }
  private enum CodingKeys: CodingKey { case id, name, coefficients }
  public init(from decoder: Decoder) throws {
    // Historical projects encoded the two built-ins as strings.
    if let raw = try? decoder.singleValueContainer().decode(String.self) {
      guard let builtin = Self.allCases.first(where: { $0.id == raw }) else {
        throw PrintroomError.invalid("未知内置矩阵。")
      }
      self = builtin
      return
    }
    let c = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(id: c.decode(String.self, forKey: .id), name: c.decode(String.self, forKey: .name),
                  coefficients: c.decode(RGBMatrix.self, forKey: .coefficients))
  }
  public func encode(to encoder: Encoder) throws {
    if id == "identity" || id == "ledLightSource" {
      var c = encoder.singleValueContainer(); try c.encode(id)
    } else {
      var c = encoder.container(keyedBy: CodingKeys.self)
      try c.encode(id, forKey: .id); try c.encode(name, forKey: .name)
      try c.encode(coefficients, forKey: .coefficients)
    }
  }
}

public typealias PrintDensityMatrix = MatrixPreset

public enum MatrixKind: String, Codable, CaseIterable, Identifiable, Sendable {
  case cmos, density
  public var id: String { rawValue }
  public var label: String { self == .cmos ? "CMOS 矩阵" : "密度矩阵" }
  public var builtIns: [MatrixPreset] { self == .cmos ? [.identity, .sonyA7CII] : MatrixPreset.allCases }
}

public struct MatrixLibraryEntry: Codable, Equatable, Sendable {
  public let kind: MatrixKind
  public let preset: MatrixPreset
  public init(kind: MatrixKind, preset: MatrixPreset) { self.kind = kind; self.preset = preset }
}

/// A computer-local library; projects retain independent coefficient snapshots.
public struct MatrixLibraryStore: Sendable {
  public let url: URL
  public init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Printroom/matrices.json")) { self.url = url }
  private struct Document: Codable { var version = 1; var entries: [MatrixLibraryEntry] }
  public func load() throws -> [MatrixLibraryEntry] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    let doc = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
    guard doc.version == 1 else { throw PrintroomError.invalid("矩阵库版本不支持。") }
    try validate(doc.entries)
    return doc.entries
  }
  private func validate(_ entries: [MatrixLibraryEntry]) throws {
    guard Set(entries.map { $0.preset.id }).count == entries.count,
      entries.allSatisfy({ !$0.preset.isBuiltIn }) else {
      throw PrintroomError.invalid("矩阵库存在重复标识或尝试覆盖内置矩阵。")
    }
  }
  public func save(_ entries: [MatrixLibraryEntry], replacing expected: [MatrixLibraryEntry]) throws {
    try validate(entries)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(Document(entries: entries))
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var error: NSError?
    var result: Result<Void, Error>?
    NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &error) { target in
      result = Result {
        guard try load() == expected else { throw PrintroomError.invalid("矩阵库已被其他窗口或应用修改，请重新载入后再保存。") }
        try data.write(to: target, options: .atomic)
      }
    }
    if let error { throw error }
    guard let result else { throw PrintroomError.invalid("无法访问矩阵库。") }
    try result.get()
  }
}

public struct CMOSCalibrationResult: Sendable {
  public let coefficients: RGBMatrix
  /// Indices in the user's selection, ordered by detected red/green/blue light.
  public let sourceIndices: [Int]
  public let means: [SIMD3<Double>]
}

public enum CMOSCalibration {
  public static func make(tiffs: [URL]) throws -> CMOSCalibrationResult {
    try make(sources: tiffs)
  }
  public static func make(sources: [URL]) throws -> CMOSCalibrationResult {
    guard sources.count == 3, Set(sources.map { $0.standardizedFileURL.resolvingSymlinksInPath() }).count == 3,
      sources.allSatisfy(SourceImageIO.isSupportedSource) else {
      throw PrintroomError.invalid("请选择三张不同的 RGB 光源 TIFF 或 ARW 照片。")
    }
    return try solve(means: sampleMeans(sources: sources))
  }
  static func sampleMeans(sources: [URL]) throws -> [SIMD3<Double>] {
    try sources.map { url -> SIMD3<Double> in
      try Task.checkCancellation()
      let before = try FileManager.default.attributesOfItem(atPath: url.path)
      let identity = try SourceImageIO.processingIdentity(url: url)
      let metadata = try SourceImageIO.metadata(url: url)
      let w = metadata.width > 10 ? max(1, metadata.width / 5) : metadata.width
      let h = metadata.height > 10 ? max(1, metadata.height / 5) : metadata.height
      let image = try SourceImageIO.readRegion(url: url, rect: PixelRect(
        x: (metadata.width-w)/2, y: (metadata.height-h)/2, width: w, height: h), expectedIdentity: identity)
      var sum = SIMD3<Double>(repeating: 0)
      for y in 0..<h {
        try Task.checkCancellation()
        for x in 0..<w {
          let offset = (y*w+x)*3
          let v = SIMD3<Double>(Double(image.samples[offset]), Double(image.samples[offset+1]), Double(image.samples[offset+2]))
          guard v.max() < 65535 else { throw PrintroomError.invalid("\(url.lastPathComponent) 中心标定区域存在过曝样本，请使用未剪切的照片。") }
          sum += v / 65535
        }
      }
      let after = try FileManager.default.attributesOfItem(atPath: url.path)
      guard (before[.size] as? NSNumber) == (after[.size] as? NSNumber),
        (before[.modificationDate] as? Date) == (after[.modificationDate] as? Date) else {
        throw PrintroomError.invalid("标定照片在读取期间已改变，请重新选择。")
      }
      return sum / Double(w*h)
    }
  }
  public static func solve(means: [SIMD3<Double>]) throws -> CMOSCalibrationResult {
    guard means.count == 3, means.allSatisfy({ v in (0..<3).allSatisfy { v[$0].isFinite && v[$0] >= 0 && v[$0] < 1 } }) else {
      throw PrintroomError.invalid("标定样本必须为未剪切的有限线性 RGB。")
    }
    let indices = (0..<3).map { channel in (0..<3).max { means[$0][channel] < means[$1][channel] }! }
    guard Set(indices).count == 3 else {
      throw PrintroomError.invalid("无法分别识别红、绿、蓝光源。请确认三张照片分别仅开启一种光源。")
    }
    let a = simd_double3x3(columns: (means[indices[0]], means[indices[1]], means[indices[2]]))
    let inverse = a.inverse
    func norm(_ m: simd_double3x3) -> Double {
      (0..<3).map { r in (0..<3).reduce(0.0) { $0 + abs(m[$1][r]) } }.max()!
    }
    let condition = norm(a) * norm(inverse)
    guard condition.isFinite, condition < 1e8 else {
      throw PrintroomError.invalid("三张标定照片无法稳定求解矩阵，请重新拍摄。")
    }
    var values: [Float] = []
    for row in 0..<3 {
      let sum = (0..<3).reduce(0.0) { $0 + inverse[$1][row] }
      let magnitude = (0..<3).reduce(0.0) { $0 + abs(inverse[$1][row]) }
      guard sum.isFinite, abs(sum) > 1e-8 * magnitude else {
        throw PrintroomError.invalid("矩阵无法进行稳定的中性归一化，请重新拍摄。")
      }
      for column in 0..<3 { values.append(Float(inverse[column][row] / sum)) }
    }
    return CMOSCalibrationResult(coefficients: try RGBMatrix(values), sourceIndices: indices, means: means)
  }
}
