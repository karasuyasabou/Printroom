import Foundation
import Testing
import simd
@testable import PrintroomCore
@testable import PrintroomApp

/// Opt-in photographic A/B; reuses existing four TIFFs and GPU settings.
@Suite(.serialized)
struct ICCAccelerationVerification {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["PRINTROOM_ICC_VERIFY"] == "1"))
  func photosAndStressSamples() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let directory = root.appendingPathComponent("scratch/performance")
    let folder = directory.appendingPathComponent("derived-tiff")
    let project = try ProjectStore.open(folder: folder)
    let frames = Array(project.frames.prefix(4))
    try #require(frames.count == 4)
    let calibration = try await ImageService().sample(folder.appendingPathComponent(frames[0].filename),
      rect: PixelRect(x: 359, y: 604, width: 79, height: 494), matrix: .ledLightSource, frameID: frames[0].id)
    let assets = try AppAssets()
    let adjustments = FrameAdjustments(timing: .init(master: 30, red: 5, green: -3, blue: 7),
      contrast: .init(master: 1.05, red: 0.95, green: 1.02, blue: 1.1))
    struct Stats {
      var count = 0, changed8 = 0, changed16 = 0, max8 = 0, max16 = 0
      var bias8 = SIMD3<Double>(repeating: 0), bias16 = SIMD3<Double>(repeating: 0)
      var maxFloat: Float = 0
      var pairs: [Float] = []
      mutating func compare(_ old: PixelBuffer, _ new: PixelBuffer, sampleStride: Int) {
        for i in old.pixels.indices {
          var differs8 = false, differs16 = false
          for c in 0..<3 {
            let a = old.pixels[i][c], b = new.pixels[i][c]
            maxFloat = max(maxFloat, abs(a-b))
            let d8 = Int(floor(min(1,max(0,b))*255+0.5)) - Int(floor(min(1,max(0,a))*255+0.5))
            let d16 = Int(floor(min(1,max(0,b))*65535+0.5)) - Int(floor(min(1,max(0,a))*65535+0.5))
            differs8 = differs8 || d8 != 0; differs16 = differs16 || d16 != 0
            max8 = max(max8,abs(d8)); max16 = max(max16,abs(d16))
            bias8[c] += Double(d8); bias16[c] += Double(d16)
          }
          count += 1; if differs8 { changed8 += 1 }; if differs16 { changed16 += 1 }
          if i % sampleStride == 0 {
            pairs += [old.pixels[i].x, old.pixels[i].y, old.pixels[i].z,
              new.pixels[i].x, new.pixels[i].y, new.pixels[i].z]
          }
        }
      }
      func record() -> [String: Any] {
        ["pixels":count,"changed8":changed8,"changed16":changed16,"max8":max8,"max16":max16,
         "bias8":(0..<3).map { bias8[$0]/Double(count) },
         "bias16":(0..<3).map { bias16[$0]/Double(count) },"maxFloat":maxFloat]
      }
    }
    let converters = try OutputColorProfile.allCases.map { try OutputColorConverter(p3Profile: assets.profile, output: $0) }
    var photo = Array(repeating: Stats(), count: converters.count)
    // All pixels and all profiles for quantization; colorimetric pairs sampled every 257 pixels.
    for frame in frames {
      let image = try SourceImageIO.read(url: folder.appendingPathComponent(frame.filename))
      let geometry = try CropGeometry(crop: nil, sourceWidth: image.width, sourceHeight: image.height, orientation: frame.orientation)
      for start in stride(from: 0, to: image.height, by: 32) {
        let input = try geometry.renderRows(image, rows: start..<min(image.height,start+32))
        let final = try assets.gpu.render(input, calibration: calibration, adjustments: adjustments, lut: assets.lut)
        for i in converters.indices {
          photo[i].compare(try converters[i].convertReference(final), try converters[i].convert(final), sampleStride: 257)
        }
      }
      print("ICC verified photo \(frame.filename)")
    }
    var stress: [SIMD4<Float>] = []
    for i in 0...65536 { let x = Float(i)/65536; stress.append(SIMD4(x,x,x,1)) }
    for r in 0...32 { for g in 0...32 { for b in 0...32 { stress.append(SIMD4(Float(r)/32,Float(g)/32,Float(b)/32,1)) } } }
    for i in 0...12000 {
      let x = Float(pow(10, -12 + Double(i)/1000))
      stress += [SIMD4(x,x,x,1), SIMD4(x,0,1,1), SIMD4(1,x,0,1)]
    }
    // Destination parametric boundaries and sampled-table knots mapped back to source RGB.
    let source = try MatrixICCProfile(assets.profile)
    for converter in converters {
      let target = try MatrixICCProfile(converter.outputProfile)
      var levels: [Double] = [0,1,0x1p-32]
      switch target.curves[0] {
      case .piecewise(_,_,_,let c,let d): levels.append(c*d)
      case .table(let entries): levels += entries
      case .gamma: break
      }
      let reverse = source.colorants.inverse * target.colorants
      for level in levels { for epsilon in [-1e-9,0,1e-9] {
        for channel in 0..<4 {
          var linear = SIMD3<Double>(repeating: level+epsilon)
          if channel < 3 { linear = SIMD3(repeating: 0); linear[channel] = level+epsilon }
          let native = reverse * linear
          stress.append(SIMD4(Float(source.curves[0].encode(native.x)),Float(source.curves[1].encode(native.y)),Float(source.curves[2].encode(native.z)),1))
        }
      } }
    }
    stress += [SIMD4(-1,0,2,1),SIMD4(-0.01,1.1,0.5,1),SIMD4(10,-10,0,1)]
    let input = PixelBuffer(width: stress.count, height: 1, pixels: stress)
    var records: [[String: Any]] = []
    for i in converters.indices {
      var synthetic = Stats()
      synthetic.compare(try converters[i].convertReference(input), try converters[i].convert(input), sampleStride: 1)
      let name = converters[i].profile.rawValue
      for (kind, stats) in [("photo",photo[i]),("stress",synthetic)] {
        var record = stats.record(); record["profile"] = name; record["kind"] = kind
        records.append(record)
        try stats.pairs.withUnsafeBytes { try Data($0).write(to: directory.appendingPathComponent("icc-\(name)-\(kind).bin")) }
        try #require(stats.max8 <= 1 && stats.max16 <= 2)
      }
    }
    try JSONSerialization.data(withJSONObject:records,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("icc-quality.json"))
    let invalid = PixelBuffer(width:1,height:1,pixels:[SIMD4(.nan,0,0,1)])
    #expect(throws: (any Error).self) { try converters[0].convert(invalid) }
    let profileData = assets.profile
    let task = Task.detached {
      let converter = try OutputColorConverter(p3Profile: profileData, output: .sRGB)
      return try converter.convert(input)
    }
    task.cancel()
    do { _ = try await task.value; Issue.record("Cancellation ignored") } catch is CancellationError {} 
  }
}
