import CoreGraphics
import ImageIO
import Foundation
import XCTest
@testable import PrintroomCore

final class SprocketWhiteningTests: XCTestCase, @unchecked Sendable {
  private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
  private func lut() throws -> CubeLUT {
    var values: [SIMD4<Float>] = []
    for i in 0..<8 { values.append(SIMD4<Float>(Float(i % 2), Float((i / 2) % 2), Float(i / 4), 1)) }
    return try CubeLUT(size: 2, values: values)
  }
  private func calibration() -> FilmCalibration {
    var c = FilmCalibration()
    c.baseRGB = SIMD3(repeating: 0.2)
    c.gainRGB = SIMD3(repeating: 3.75)
    return c
  }
  private func context(_ settings: SprocketWhiteningSettings = .init(enabled: true),
    crop: FrameCrop = .init(aspect: .square, width: 0.5), orientation: FrameOrientation = .identity,
    rowOffset: Int = 0) throws -> SprocketWhiteningContext {
    let size = orientation.outputSize(sourceWidth: 96, sourceHeight: 72)
    return try .init(settings: settings, protectedCrop: crop, sourceWidth: 96, sourceHeight: 72,
      orientation: orientation, renderWidth: size.width, renderHeight: size.height, rowOffset: rowOffset)
  }
  func testAnalyticThresholdRGBAndProtectedInterior() throws {
    let mask = try context()
    let c = calibration()
    XCTAssertEqual(mask.opacity(rawRGB: SIMD3(repeating: 0.25), x: 0, y: 0, calibration: c), 0)
    XCTAssertEqual(mask.opacity(rawRGB: SIMD3(repeating: 0.255), x: 0, y: 0, calibration: c), 0.5, accuracy: 0.00001)
    XCTAssertEqual(mask.opacity(rawRGB: SIMD3(repeating: 0.27), x: 0, y: 0, calibration: c), 1)
    // One bright color channel cannot turn a patch of orange film base white.
    XCTAssertEqual(mask.opacity(rawRGB: SIMD3(0.9, 0.2, 0.2), x: 0, y: 0, calibration: c), 0)
    XCTAssertEqual(mask.opacity(rawRGB: SIMD3(repeating: 1), x: 48, y: 36, calibration: c), 0)
    XCTAssertEqual(mask.opacity(rawRGB: SIMD3(repeating: 1), x: 0, y: 0, calibration: FilmCalibration()), 0)
    let disabled = try context(.init(enabled: false))
    XCTAssertEqual(disabled.opacity(rawRGB: SIMD3(repeating: 1), x: 0, y: 0, calibration: c), 0)
    XCTAssertThrowsError(try context(.init(enabled: true, thresholdPercent: .nan)))
    XCTAssertThrowsError(try context(.init(enabled: true, thresholdPercent: 0)))
    var unknown = SprocketWhiteningSettings()
    unknown.version = "future"
    XCTAssertThrowsError(try context(unknown))
  }
  func testRotatedCropNeverWhitenedAndStripCoordinatesFollowAllDirections() throws {
    let crop = FrameCrop(aspect: .free, centerX: 0.43, centerY: 0.53, width: 0.67,
      angleDegrees: 7.3, freeRatio: 1.36)
    let protected = try CropGeometry(crop: crop, sourceWidth: 96, sourceHeight: 72)
    for direction in FrameOrientation.allCases {
      let full = try CropGeometry(crop: nil, sourceWidth: 96, sourceHeight: 72, orientation: direction)
      let mask = try context(crop: crop, orientation: direction)
      let strip = try context(crop: crop, orientation: direction, rowOffset: 32)
      var insideCount = 0, outsideCount = 0
      for y in 0..<full.outputHeight {
        for x in 0..<full.outputWidth {
          let p = full.sourcePoint(outputX: Double(x) + 0.5, outputY: Double(y) + 0.5)
          let q = protected.outputPoint(sourceX: p.x, sourceY: p.y)
          let amount = mask.opacity(rawRGB: SIMD3(repeating: 1), x: x, y: y, calibration: calibration())
          let guardX = Double(protected.outputWidth) * 0.000004
          let guardY = Double(protected.outputHeight) * 0.000004
          if q.x >= -guardX, q.x <= Double(protected.outputWidth) + guardX,
            q.y >= -guardY, q.y <= Double(protected.outputHeight) + guardY {
            XCTAssertEqual(amount, 0)
            insideCount += 1
          } else {
            XCTAssertEqual(amount, 1, "dir=\(direction) pixel=\(x),\(y) crop=\(q)")
            outsideCount += 1
          }
          if y >= 32 {
            XCTAssertEqual(amount, strip.opacity(rawRGB: SIMD3(repeating: 1), x: x, y: y - 32, calibration: calibration()))
          }
        }
      }
      XCTAssertGreaterThan(insideCount, 0)
      XCTAssertGreaterThan(outsideCount, 0)
    }
  }
  func testCPUAndMetalThresholdChangesReuseDensityWithoutChangingDiagnostics() throws {
    let gpu = try MetalPipeline().makeSession()
    let input = PixelBuffer(width: 96, height: 72, pixels: (0..<(96 * 72)).map {
      let v = Float($0 % 257) / 256 * 0.5 + 0.05
      return SIMD4(v, v * 1.02, v * 1.03, 1)
    })
    let identity = UUID()
    var c = calibration()
    c.cmosMatrix = .sonyA7CII
    let table = try lut()
    var edits = FrameAdjustments()
    for threshold in [5.0, 25, 80] {
      let mask = try context(.init(enabled: true, thresholdPercent: threshold),
        crop: .init(aspect: .square, width: 0.5, angleDegrees: -8.2))
      edits.timing.master += 20
      edits.contrast.red = 1.2
      let expected = try Pipeline.render(input, calibration: c, adjustments: edits, lut: table, sprocketWhitening: mask)
      let actual = try gpu.render(input, calibration: c, adjustments: edits, lut: table,
        inputIdentity: identity, sprocketWhitening: mask)
      var maxError: Float = 0, squareError: Double = 0
      for i in expected.pixels.indices {
        for channel in 0..<3 {
          let error = abs(expected.pixels[i][channel] - actual.pixels[i][channel])
          maxError = max(maxError, error)
          squareError += Double(error * error)
        }
      }
      print("Sprocket CPU/Metal threshold=\(threshold)% max=\(maxError) rms=\(sqrt(squareError / Double(expected.pixels.count * 3)))")
      XCTAssertLessThanOrEqual(maxError, 0.0002)
      XCTAssertLessThanOrEqual(sqrt(squareError / Double(expected.pixels.count * 3)), 0.00002)
      for stage in [PipelineStage.l2, .d3] {
        let plain = try gpu.render(input, calibration: c, adjustments: edits, lut: table, stage: stage, inputIdentity: identity)
        let treated = try gpu.render(input, calibration: c, adjustments: edits, lut: table, stage: stage,
          inputIdentity: identity, sprocketWhitening: mask)
        XCTAssertEqual(plain.pixels, treated.pixels)
      }
    }
    XCTAssertEqual(gpu.statistics.densityPasses, 1)
    XCTAssertGreaterThan(gpu.statistics.densityCacheHits, 0)
  }
  func testSchemaEightDefaultsBacksUpOriginalAndValidatesSettings() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprocket-schema-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    var project = RollProject()
    project.frames = [FrameRecord(filename: "A.tiff", isMissing: true, crop: .init(width: 0.6))]
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any])
    json["schemaVersion"] = 8
    json.removeValue(forKey: "sprocketWhitening")
    let bytes = try JSONSerialization.data(withJSONObject: json)
    let path = folder.appendingPathComponent(ProjectStore.filename)
    try bytes.write(to: path)
    var loaded = try ProjectStore.open(folder: folder)
    XCTAssertEqual(loaded.sprocketWhitening, .init())
    XCTAssertEqual(loaded.frames[0].crop, project.frames[0].crop)
    XCTAssertEqual(try Data(contentsOf: path), bytes)
    loaded.sprocketWhitening = .init(enabled: true, thresholdPercent: 42)
    try ProjectStore.save(loaded, folder: folder, expectedModification: loaded.loadedModificationDate)
    let backups = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
      .filter { $0.lastPathComponent.hasPrefix(".printroom-schema8-") }
    XCTAssertEqual(backups.count, 1)
    XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), bytes)
    XCTAssertEqual(try ProjectStore.open(folder: folder).sprocketWhitening, loaded.sprocketWhitening)
    loaded.sprocketWhitening.thresholdPercent = 201
    XCTAssertThrowsError(try ProjectStore.decodeSnapshot(JSONEncoder().encode(loaded)))
  }
  func testJPEGWhiteningAcrossOutputProfilesAndBothBackends() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprocket-jpeg-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let profile = try Data(contentsOf: root.appendingPathComponent("ICC/DCIP3_D65.icc"))
    let source = folder.appendingPathComponent("source.tiff")
    try TIFFCodec.write(url: source, width: 128, height: 96, profile: profile) {
      Array(repeating: UInt16(40000), count: $0.count * 128 * 3)
    }
    let table = try lut()
    let c = calibration()
    let raw = PixelBuffer(width: 1, height: 1, pixels: [SIMD4<Float>(40000 / 65535.0, 40000 / 65535.0, 40000 / 65535.0, 1)])
    let native = try Pipeline.render(raw, calibration: c, adjustments: .init(), lut: table)
    for cpu in [false, true] {
      let engine = ExportEngine(useCPUReference: cpu)
      for color in OutputColorProfile.allCases {
        var settings = ProjectExportSettings()
        settings.profile = color
        settings.format = .jpeg
        settings.applyCrop = false
        let request = try ExportRequest(source: source,
          destination: folder.appendingPathComponent("\(cpu)-\(color.rawValue).jpg"), calibration: c,
          adjustments: .init(), settings: settings, crop: .init(aspect: .square, width: 0.5),
          sprocketWhitening: .init(enabled: true))
        let result = try await engine.run(request, lut: table, p3Profile: profile)
        XCTAssertEqual(result.completedCount, 1)
        let url = try XCTUnwrap(result.results[0].destination)
        let reader = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(reader, 0, nil))
        XCTAssertEqual(image.bitsPerComponent, 8)
        let data = try XCTUnwrap(image.dataProvider?.data) as Data
        let stride = image.bitsPerPixel / 8
        let expected = try OutputColorConverter(p3Profile: profile, output: color).quantized8(native)
        for channel in 0..<3 {
          XCTAssertLessThanOrEqual(abs(Int(data[48 * image.bytesPerRow + 8 * stride + channel]) - 255), 2)
          XCTAssertLessThanOrEqual(abs(Int(data[48 * image.bytesPerRow + 64 * stride + channel]) - Int(expected[channel])), 3)
        }
      }
    }
  }
  func testTIFFExportAllDirectionsProfilesAndBackendsProtectCropAndWriteExactWhite() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprocket-export-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let profile = try Data(contentsOf: root.appendingPathComponent("ICC/DCIP3_D65.icc"))
    let source = folder.appendingPathComponent("source.tiff")
    try TIFFCodec.write(url: source, width: 96, height: 72, profile: profile) { rows in
      rows.flatMap { y in (0..<96).flatMap { x in [UInt16](repeating: x < 4 && y < 4 ? 13107 : 40000, count: 3) } }
    }
    let original = try Data(contentsOf: source)
    var roll = try ProjectStore.open(folder: folder)
    roll.calibration = try Pipeline.calibrate(image: TIFFCodec.read(url: source), rect: .init(x: 0, y: 0, width: 4, height: 4),
      matrix: .identity, sourceFrameID: roll.frames[0].id)
    let crop = FrameCrop(aspect: .square, centerX: 0.43, width: 0.5, angleDegrees: 6.7)
    roll.frames[0].crop = crop
    let table = try lut()
    let engines = [ExportEngine(useCPUReference: true), ExportEngine()]
    for (backend, engine) in engines.enumerated() {
      for direction in FrameOrientation.allCases {
        roll.frames[0].orientation = direction
        let geometry = try CropGeometry(crop: crop, sourceWidth: 96, sourceHeight: 72, orientation: direction)
        for color in OutputColorProfile.allCases {
          roll.exportSettings.profile = color
          roll.exportSettings.applyCrop = false
          var results: [LinearImage] = []
          for enabled in [false, true] {
            roll.calibrationNeedsReview = true // Legacy review cannot suppress an export snapshot.
            roll.sprocketWhitening = .init(enabled: enabled)
            let request = try ExportRequest(project: roll, targetIDs: [roll.frames[0].id], destinationDirectory: folder,
              filenamePrefix: "b\(backend)-d\(direction.rawValue)-\(color.rawValue)-\(enabled)")
            // A task remains frozen even when the editor disables the treatment afterwards.
            roll.sprocketWhitening.enabled = false
            let summary = try await engine.run(request, lut: table, p3Profile: profile)
            XCTAssertEqual(summary.completedCount, 1, "\(summary.results)")
            let destination = try XCTUnwrap(summary.results[0].destination)
            let reader = try XCTUnwrap(CGImageSourceCreateWithURL(destination as CFURL, nil))
            let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(reader, 0, nil))
            let embedded = try XCTUnwrap(decoded.colorSpace?.copyICCData()) as Data
            XCTAssertEqual(embedded, try color.profileData(p3: profile))
            results.append(try TIFFCodec.read(url: destination))
          }
          let before = results[0], after = results[1]
          for y in 0..<after.height {
            for x in 0..<after.width {
              let sourcePixel = direction.inversePixel(x: x, y: y, sourceWidth: 96, sourceHeight: 72)
              let point = geometry.outputPoint(sourceX: Double(sourcePixel.x) + 0.5, sourceY: Double(sourcePixel.y) + 0.5)
              let inside = point.x >= 0 && point.x <= Double(geometry.outputWidth)
                && point.y >= 0 && point.y <= Double(geometry.outputHeight)
              let base = sourcePixel.x < 4 && sourcePixel.y < 4
              let i = (y * after.width + x) * 3
              for c in 0..<3 {
                XCTAssertEqual(after.samples[i + c], inside || base ? before.samples[i + c] : 65535)
              }
            }
          }
        }
        roll.exportSettings.applyCrop = true
        var cropped: [[UInt16]] = []
        for enabled in [false, true] {
          roll.sprocketWhitening.enabled = enabled
          let request = try ExportRequest(project: roll, targetIDs: [roll.frames[0].id], destinationDirectory: folder,
            filenamePrefix: "cropped-\(backend)-\(direction.rawValue)-\(enabled)")
          let summary = try await engine.run(request, lut: table, p3Profile: profile)
          cropped.append(try TIFFCodec.read(url: XCTUnwrap(summary.results[0].destination)).samples)
        }
        XCTAssertEqual(cropped[0], cropped[1])
      }
    }
    XCTAssertEqual(try Data(contentsOf: source), original)
  }
}
