import CryptoKit
import Foundation
import XCTest

@testable import PrintroomCore

final class CropRealAssetTests: XCTestCase, @unchecked Sendable {
  func testActualTIFFNativeFineCropExportAndIndependentPixelReadback() async throws {
    guard ProcessInfo.processInfo.environment["PRINTROOM_VALIDATE_ASSETS"] == "1" else {
      throw XCTSkip("Set PRINTROOM_VALIDATE_ASSETS=1 for the actual native-resolution crop export.")
    }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let source = root.appendingPathComponent("TEST/TIFF/DSC07079.tiff")
    let originalHash = try hash(source)
    let metadata = try TIFFCodec.metadata(url: source)
    XCTAssertEqual(metadata.width, 7008)
    XCTAssertEqual(metadata.height, 4672)
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("printroom-real-crop-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let destination = folder.appendingPathComponent("DSC07079-crop-sRGB.tiff")
    let profile = try Data(contentsOf: root.appendingPathComponent("ICC/DCIP3_D65.icc"))
    let lut = try CubeLUT(url: root.appendingPathComponent("LUT/DCI-P3 Kodak 2383 D65.cube"))
    let crop = FrameCrop(aspect: .sevenSix, width: 0.75, angleDegrees: 3.17)
    let calibration = FilmCalibration()
    let adjustments = FrameAdjustments()
    let request = try ExportRequest(source: source, destination: destination,
      calibration: calibration, adjustments: adjustments,
      settings: .init(profile: .sRGB, compression: .deflate), crop: crop)
    let summary = try await ExportEngine().run(request, lut: lut, p3Profile: profile)
    XCTAssertEqual(summary.completedCount, 1, summary.results.first?.error ?? "")
    let output = try TIFFCodec.metadata(url: destination)

    // Independent geometry for a centered 7:6 crop: inverse rotation projects
    // its width/height onto both source axes. Integer multiples keep exact ratio.
    let radians = 3.17 * Double.pi / 180
    let c = cos(radians), s = sin(radians)
    let w = Double(metadata.width), h = Double(metadata.height)
    let k = Int(floor(min(0.75 * w / 7, min(w / (7 * c + 6 * s), h / (7 * s + 6 * c)))))
    let expectedWidth = k * 7, expectedHeight = k * 6
    XCTAssertEqual(expectedWidth, 5124)
    XCTAssertEqual(expectedHeight, 4392)
    XCTAssertEqual(output.width, expectedWidth)
    XCTAssertEqual(output.height, expectedHeight)
    let bytes = try Data(contentsOf: destination, options: .mappedIfSafe)
    let converter = try OutputColorConverter(p3Profile: profile, output: .sRGB)
    XCTAssertEqual(try tag(34675, in: bytes), converter.outputProfile)
    XCTAssertEqual(try tag(274, in: bytes), Data([1, 0]))
    XCTAssertEqual(try tag(259, in: bytes), Data([8, 0]))

    let positions = [
      (0, 0), (expectedWidth - 1, 0), (0, expectedHeight - 1),
      (expectedWidth - 1, expectedHeight - 1), (expectedWidth / 2, expectedHeight / 2),
      (expectedWidth / 3, 31), (expectedWidth / 3, 32),
      (expectedWidth * 2 / 3, expectedHeight * 2 / 3),
    ]
    var maximumDifference = 0
    for (x, y) in positions {
      let dx = Double(x) + 0.5 - Double(expectedWidth) / 2
      let dy = Double(y) + 0.5 - Double(expectedHeight) / 2
      let sx = max(0, min(w - 1, c * dx + s * dy + w / 2 - 0.5))
      let sy = max(0, min(h - 1, -s * dx + c * dy + h / 2 - 0.5))
      let x0 = Int(floor(sx)), y0 = Int(floor(sy))
      let sourceROI = PixelRect(x: x0, y: y0, width: min(2, metadata.width - x0),
                                 height: min(2, metadata.height - y0))
      let tile = try TIFFCodec.readRegion(url: source, rect: sourceROI)
      let fx = sx - Double(x0), fy = sy - Double(y0)
      var linear = SIMD4<Float>(repeating: 1)
      // Four Float64 weights over original UInt16 values are independent from
      // production's SIMD Float32 bilinear expression and geometry helper.
      for channel in 0..<3 {
        let a = Double(tile.samples[channel])
        let b = Double(tile.samples[(sourceROI.width - 1) * 3 + channel])
        let d = Double(tile.samples[(sourceROI.width * sourceROI.height - 1) * 3 + channel])
        let lowerLeft = Double(tile.samples[(sourceROI.height - 1) * sourceROI.width * 3 + channel])
        linear[channel] = Float((a * (1 - fx) * (1 - fy) + b * fx * (1 - fy)
                                 + lowerLeft * (1 - fx) * fy + d * fx * fy) / 65535)
      }
      let final = try Pipeline.render(PixelBuffer(width: 1, height: 1, pixels: [linear]),
        calibration: calibration, adjustments: adjustments, lut: lut)
      let expected = try converter.quantized(final)
      let actual = try TIFFCodec.readRegion(url: destination,
        rect: PixelRect(x: x, y: y, width: 1, height: 1))
      for channel in 0..<3 {
        let difference = abs(Int(actual.samples[channel]) - Int(expected[channel]))
        maximumDifference = max(maximumDifference, difference)
        // Sparse sRGB readback threshold: 2e-4 encoded units plus two quantization
        // steps. Report the measured maximum separately from this failure bound.
        XCTAssertLessThanOrEqual(Double(difference) / 65535, 2e-4 + 2.0 / 65535,
                                 "pixel (\(x),\(y)) channel \(channel)")
      }
    }
    XCTAssertEqual(try hash(source), originalHash)
    print("Actual crop export: DSC07079.tiff → \(expectedWidth)×\(expectedHeight), 7:6 / 3.17°, sRGB Deflate, \(positions.count) independent pixels, max \(maximumDifference) UInt16 steps, \(summary.elapsedSeconds)s, \(bytes.count) bytes; original SHA256 unchanged")
  }

  private func hash(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    while let block = try handle.read(upToCount: 1_048_576), !block.isEmpty { hash.update(data: block) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }

  /// Independent little-endian classic TIFF directory inspection; no image decode.
  private func tag(_ wanted: UInt16, in data: Data) throws -> Data {
    func u16(_ at: Int) -> UInt16 { UInt16(data[at]) | UInt16(data[at + 1]) << 8 }
    func u32(_ at: Int) -> Int {
      Int(data[at]) | Int(data[at + 1]) << 8 | Int(data[at + 2]) << 16 | Int(data[at + 3]) << 24
    }
    XCTAssertEqual(data.prefix(4), Data([0x49, 0x49, 42, 0]))
    let directory = u32(4)
    for index in 0..<Int(u16(directory)) {
      let entry = directory + 2 + index * 12
      guard u16(entry) == wanted else { continue }
      let type = u16(entry + 2)
      let size = u32(entry + 4) * (type == 3 ? 2 : type == 4 ? 4 : 1)
      let offset = size <= 4 ? entry + 8 : u32(entry + 8)
      return data.subdata(in: offset..<(offset + size))
    }
    throw PrintroomError.invalid("Missing TIFF tag \(wanted)")
  }
}
