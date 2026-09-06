import Foundation

public let algorithmVersion = "printroom-density-v1"
public enum PipelineStage: Int, CaseIterable, Codable, Sendable {
  case l0, l1, d0, d1, d2, d3, final
  public var label: String { ["L0", "L1", "D0", "D1", "D2", "D3", "Final"][rawValue] }
}
public enum PrintDensityMatrix: String, CaseIterable, Codable, Sendable {
  case identity, ledLightSource
  public var label: String { self == .identity ? "Identity" : "LED Light Source" }
}
public struct TimingParameters: Codable, Equatable, Sendable {
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
public struct FrameAdjustments: Codable, Equatable, Sendable {
  public var timing = TimingParameters()
  public var contrast = ContrastParameters()
  public init(timing: TimingParameters = .init(), contrast: ContrastParameters = .init()) {
    self.timing = timing
    self.contrast = contrast
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
  public var baseRGB: SIMD3<Float>?
  public var gainRGB = SIMD3<Float>(repeating: 1)
  public var filmBaseOffsetCV = SIMD3<Float>(repeating: 0)
  public var sourceFrameID: UUID?
  public var selection: PixelRect?
  public var sourceWidth: Int?
  public var sourceHeight: Int?
  public var isCalibrated: Bool { baseRGB != nil }
  public init() {}
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
