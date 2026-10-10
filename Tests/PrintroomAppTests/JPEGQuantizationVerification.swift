import CryptoKit
import Foundation
import PrintroomCore
import Testing
@testable import PrintroomApp

/// Opt-in, full RGB byte comparison on the same four photographic TIFFs as the benchmark.
@Suite(.serialized)
struct JPEGQuantizationVerification {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["PRINTROOM_JPEG_RGB_VERIFY"] == "1"))
  func fourTIFFsMatchLegacyRGBBytes() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let directory = root.appendingPathComponent("scratch/performance")
    let folder = directory.appendingPathComponent("derived-tiff")
    let project = try ProjectStore.open(folder: folder)
    let frames = Array(project.frames.prefix(4))
    try #require(frames.count == 4)
    let calibration = try await ImageService().sample(folder.appendingPathComponent(frames[0].filename),
      rect: PixelRect(x: 359, y: 604, width: 79, height: 494),
      matrix: .ledLightSource, frameID: frames[0].id)
    let assets = try AppAssets()
    let converter = try OutputColorConverter(p3Profile: assets.profile, output: .displayP3)
    let adjustments = FrameAdjustments(timing: .init(master: 30, red: 5, green: -3, blue: 7),
      contrast: .init(master: 1.05, red: 0.95, green: 1.02, blue: 1.1))
    var records: [[String: Any]] = []
    for frame in frames {
      let image = try SourceImageIO.read(url: folder.appendingPathComponent(frame.filename))
      let geometry = try CropGeometry(crop: nil, sourceWidth: image.width, sourceHeight: image.height,
        orientation: frame.orientation)
      var legacyHash = SHA256(), optimizedHash = SHA256(), byteCount = 0
      for start in stride(from: 0, to: image.height, by: 32) {
        let input = try geometry.renderRows(image, rows: start..<min(image.height, start + 32))
        let final = try assets.gpu.render(input, calibration: calibration,
          adjustments: adjustments, lut: assets.lut)
        let converted = try converter.convert(final)
        let legacy = converted.pixels.flatMap { pixel in
          (0..<3).map { UInt8(floor(min(1, max(0, pixel[$0])) * 255 + 0.5)) }
        }
        let optimized = try OutputColorConverter.quantize8(converted)
        try #require(optimized == legacy, "RGB byte mismatch: \(frame.filename), row \(start)")
        legacyHash.update(data: Data(legacy)); optimizedHash.update(data: Data(optimized))
        byteCount += optimized.count
      }
      func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
      }
      records.append(["frame": frame.filename, "bytes": byteCount, "byteEqual": true,
        "legacySHA256": hex(legacyHash.finalize()), "optimizedSHA256": hex(optimizedHash.finalize())])
    }
    let data = try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: directory.appendingPathComponent("jpeg-quantization-rgb-consistency.json"))
  }
}
