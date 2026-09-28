import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import XCTest
import simd

@testable import PrintroomCore

final class ExportColorTests: XCTestCase, @unchecked Sendable {
  private var root: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
  }
  private func p3() throws -> Data {
    try Data(contentsOf: root.appendingPathComponent("ICC/DCIP3_D65.icc"))
  }
  private func temporary() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "printroom-export-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
  private func identityLUT() throws -> CubeLUT {
    var pixels: [SIMD4<Float>] = []
    for b in 0...1 {
      for g in 0...1 {
        for r in 0...1 {
          pixels.append(SIMD4(Float(r), Float(g), Float(b), 1))
        }
      }
    }
    return try CubeLUT(size: 2, values: pixels)
  }
  private func fixture(_ url: URL, width: Int = 7, height: Int = 97) throws {
    try TIFFCodec.write(
      url: url, width: width, height: height, profile: p3(), compression: .deflate
    ) { rows in
      var values: [UInt16] = []
      for y in rows {
        for x in 0..<width {
          for c in 0..<3 {
            values.append(UInt16(1 + ((y * width + x) * 97 + c * 719) % 65534))
          }
        }
      }
      return values
    }
  }

  func testJPEGExportProfilesNumberingAndNoOverwrite() async throws {
    let folder = try temporary()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("source.tiff")
    try TIFFCodec.write(url: source, width: 32, height: 48, profile: p3()) { rows in
      Array(repeating: [UInt16(20000), 24000, 28000], count: rows.count * 32).flatMap { $0 }
    }
    let original = try Data(contentsOf: source)
    var project = try ProjectStore.open(folder: folder)
    project.frames[0].orientation = FrameOrientation.allCases.first { $0.outputSize(sourceWidth: 32, sourceHeight: 48).width == 48 }!
    project.exportSettings.format = .jpeg
    try ProjectStore.save(project, folder: folder, expectedModification: nil)
    XCTAssertEqual(try ProjectStore.open(folder: folder).exportSettings.format, .jpeg)
    let engine = ExportEngine(useCPUReference: true)
    for profile in OutputColorProfile.allCases {
      project.exportSettings.profile = profile
      let request = try ExportRequest(project: project, targetIDs: [project.frames[0].id],
        destinationDirectory: folder, filenamePrefix: profile.rawValue)
      let summary = try await engine.run(request, lut: identityLUT(), p3Profile: p3())
      XCTAssertEqual(summary.completedCount, 1, "\(summary.results)")
      let url = try XCTUnwrap(summary.results[0].destination)
      XCTAssertEqual(url.lastPathComponent, profile.rawValue + "-01.jpg")
      let reader = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
      XCTAssertEqual(CGImageSourceGetType(reader) as String?, "public.jpeg")
      let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(reader, 0, nil))
      XCTAssertEqual(decoded.bitsPerComponent, 8)
      XCTAssertEqual(decoded.width, 48)
      XCTAssertEqual(decoded.height, 32)
      let embedded = try XCTUnwrap(decoded.colorSpace?.copyICCData()) as Data
      XCTAssertEqual(embedded, try profile.profileData(p3: p3()))
      let converter = try OutputColorConverter(p3Profile: p3(), output: profile)
      let input = try TIFFCodec.read(url: source).preview(maxDimension: 48)
      let final = try Pipeline.render(input, calibration: project.calibration,
        adjustments: project.frames[0].adjustments, lut: identityLUT())
      let expected = try converter.quantized8(final)
      let pixelData = try XCTUnwrap(decoded.dataProvider?.data) as Data
      let stride = decoded.bitsPerPixel / 8
      XCTAssertGreaterThanOrEqual(stride, 3)
      for channel in 0..<3 {
        XCTAssertLessThanOrEqual(abs(Int(pixelData[channel]) - Int(expected[channel])), 3)
      }
      let before = try Data(contentsOf: url)
      let repeated = try await engine.run(request, lut: identityLUT(), p3Profile: p3())
      XCTAssertEqual(repeated.results[0].destination?.lastPathComponent, profile.rawValue + "-01-1.jpg")
      XCTAssertEqual(try Data(contentsOf: url), before)
    }
    XCTAssertEqual(try Data(contentsOf: source), original)
    XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains { $0.hasPrefix(".printroom-") })
  }

  func testCropBypassPreservesDirectionAndFrozenSettingsForBothFormats() async throws {
    let folder = try temporary()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("source.tiff")
    try fixture(source, width: 32, height: 48)
    let original = try Data(contentsOf: source)
    var project = try ProjectStore.open(folder: folder)
    let crop = FrameCrop(width: 0.5, angleDegrees: 4)
    let engine = ExportEngine(useCPUReference: true)
    for format in ExportFormat.allCases {
      for (index, orientation) in FrameOrientation.allCases.enumerated() {
        project.frames[0].orientation = orientation
        project.frames[0].crop = crop
        project.exportSettings.format = format
        project.exportSettings.applyCrop = false
        let request = try ExportRequest(project: project, targetIDs: [project.frames[0].id],
          destinationDirectory: folder, filenamePrefix: "bypass-\(format)-\(index)")
        // Changing the project after capture must not change the queued export.
        project.exportSettings.applyCrop = true
        let bypass = try await engine.run(request, lut: identityLUT(), p3Profile: p3())
        XCTAssertEqual(bypass.completedCount, 1, "\(bypass.results)")
        let bypassURL = try XCTUnwrap(bypass.results[0].destination)
        let reader = try XCTUnwrap(CGImageSourceCreateWithURL(bypassURL as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(reader, 0, nil))
        let size = orientation.outputSize(sourceWidth: 32, sourceHeight: 48)
        XCTAssertEqual(image.width, size.width)
        XCTAssertEqual(image.height, size.height)
        XCTAssertEqual(project.frames[0].crop, crop)
        let croppedRequest = try ExportRequest(project: project, targetIDs: [project.frames[0].id],
          destinationDirectory: folder, filenamePrefix: "cropped-\(format)-\(index)")
        let cropped = try await engine.run(croppedRequest, lut: identityLUT(), p3Profile: p3())
        let croppedURL = try XCTUnwrap(cropped.results[0].destination)
        let croppedReader = try XCTUnwrap(CGImageSourceCreateWithURL(croppedURL as CFURL, nil))
        let croppedImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(croppedReader, 0, nil))
        XCTAssertLessThan(croppedImage.width, image.width)
        XCTAssertLessThan(croppedImage.height, image.height)
        project.frames[0].crop = nil
        let reference = try ExportRequest(project: project, targetIDs: [project.frames[0].id],
          destinationDirectory: folder, filenamePrefix: "reference-\(format)-\(index)")
        let full = try await engine.run(reference, lut: identityLUT(), p3Profile: p3())
        let fullURL = try XCTUnwrap(full.results[0].destination)
        XCTAssertEqual(try Data(contentsOf: bypassURL), try Data(contentsOf: fullURL))
      }
    }
    XCTAssertEqual(try Data(contentsOf: source), original)
  }

  func testJPEGWriterFailureRemovesTemporaryFiles() throws {
    let folder = try temporary()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("cancelled.jpg")
    XCTAssertThrowsError(try JPEGCodec.write(url: url, width: 32, height: 64,
      profile: OutputColorProfile.sRGB.profileData(p3: p3())) { rows in
        if rows.lowerBound > 0 { throw CancellationError() }
        return Array(repeating: UInt8(127), count: rows.count * 32 * 3)
      })
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
  }

  func testProfilesTransformNumbersAndMatchIndependentCoreGraphics() throws {
    let sourceData = try p3()
    let sourceSpace = try XCTUnwrap(CGColorSpace(iccData: sourceData as CFData))
    let colors: [SIMD4<Float>] = [
      SIMD4(0.1, 0.1, 0.1, 1), SIMD4(0.5, 0.5, 0.5, 1),
      SIMD4(0.8, 0.4, 0.3, 1), SIMD4(0.3, 0.65, 0.5, 1), SIMD4(0.4, 0.35, 0.7, 1),
      SIMD4(0, 0, 0, 1), SIMD4(1, 1, 1, 1),
    ]
    let input = PixelBuffer(width: colors.count, height: 1, pixels: colors)
    for profile in OutputColorProfile.allCases {
      let converter = try OutputColorConverter(p3Profile: sourceData, output: profile)
      let converted = try converter.convert(input)
      let space = try XCTUnwrap(CGColorSpace(iccData: converter.outputProfile as CFData))
      XCTAssertEqual(
        SHA256.hash(data: converter.outputProfile).map { String(format: "%02x", $0) }.joined(),
        profile.profileSHA256)
      XCTAssertGreaterThan(abs(converted.pixels[1].x - 0.5), profile == .rec2020 ? 0.02 : 0.04,
                           "Must convert, not relabel")
      var maximum: Float = 0
      for (index, color) in colors.enumerated() {
        let original = try XCTUnwrap(
          CGColor(
            colorSpace: sourceSpace,
            components: [CGFloat(color.x), CGFloat(color.y), CGFloat(color.z), 1]))
        let reference = try XCTUnwrap(
          original.converted(to: space, intent: .relativeColorimetric, options: nil)?.components)
        for channel in 0..<3 {
          let error = abs(
            min(1, max(0, converted.pixels[index][channel]))
              - min(1, max(0, Float(reference[channel]))))
          // Apple's Float32 CMM adds a low-end toe to pure-gamma profiles.
          // Its midrange remains a useful independent implementation reference.
          if index != 0 {
            maximum = max(maximum, error)
            XCTAssertLessThanOrEqual(error, 0.0002, "\(profile) color \(index) channel \(channel)")
          }
        }
      }
      print("ICC CoreGraphics independent reference \(profile.rawValue): max abs=\(maximum)")
    }
  }

  func testProPhotoD50AdaptedMatrixAndGammaAnalyticalReference() throws {
    let source = try p3()
    let destination = try OutputColorProfile.proPhoto.profileData(p3: source)
    let tags = iccTags(destination)
    let white = xyz(try XCTUnwrap(tags["wtpt"]))
    XCTAssertEqual(white.x, 0.9642, accuracy: 0.00003)
    XCTAssertEqual(white.y, 1, accuracy: 0.00003)
    XCTAssertEqual(white.z, 0.8249, accuracy: 0.00003)
    let inputColors: [SIMD4<Float>] = [
      SIMD4(0.73, 0.31, 0.45, 1), SIMD4(0.2, 0.6, 0.3, 1), SIMD4(0.5, 0.5, 0.5, 1),
    ]
    let output = try OutputColorConverter(p3Profile: source, output: .proPhoto)
      .convert(PixelBuffer(width: inputColors.count, height: 1, pixels: inputColors))
    // Independent Float64 matrix math reads the ICC colorants already adapted to
    // D50 PCS. Omitting source chad adaptation (using D65 colorants) fails this.
    let matrix = try iccMatrix(destination).inverse * iccMatrix(source)
    for (index, pixel) in inputColors.enumerated() {
      let linear = SIMD3(
        pow(Double(pixel.x), 2.600006103515625),
        pow(Double(pixel.y), 2.600006103515625), pow(Double(pixel.z), 2.600006103515625))
      let rommLinear = matrix * linear
      for c in 0..<3 {
        let expected =
          rommLinear[c] < 1.0 / 512
          ? rommLinear[c] * 16
          : pow(rommLinear[c], 1 / 1.8000030517578125)
        XCTAssertEqual(Double(output.pixels[index][c]), expected, accuracy: 0.0005)
      }
    }
    let tiny = PixelBuffer(width: 1, height: 1, pixels: [SIMD4(0.02, 0.02, 0.02, 1)])
    let toe = try OutputColorConverter(p3Profile: source, output: .proPhoto).convert(tiny)
    XCTAssertEqual(toe.pixels[0].x, Float(pow(0.02, 2.600006103515625) * 16), accuracy: 0.000002)
    let sourceSpace = try XCTUnwrap(CGColorSpace(iccData: source as CFData))
    let targetSpace = try XCTUnwrap(CGColorSpace(iccData: destination as CFData))
    let sourceColor = try XCTUnwrap(
      CGColor(colorSpace: sourceSpace, components: [0.02, 0.02, 0.02, 1]))
    let systemDark = try XCTUnwrap(
      sourceColor.converted(
        to: targetSpace, intent: .relativeColorimetric,
        options: nil)?.components?.first)
    print(
      "ProPhoto D50 dark reference: P3=.02, ICC analytic=\(toe.pixels[0].x), ColorSync/CGColor Float=\(systemDark)"
    )
  }

  func testBothCompressionsAllProfilesReadBackExactICCAndPixelsWithImageIO() throws {
    let folder = try temporary()
    defer { try? FileManager.default.removeItem(at: folder) }
    let pixels: [SIMD4<Float>] = (0..<105).map { value in
      let v = Float(value) / 104
      return SIMD4<Float>(v, 0.75 * v, 1 - v, 1)
    }
    for profile in OutputColorProfile.allCases {
      for compression in TIFFCompression.allCases {
        let converter = try OutputColorConverter(p3Profile: p3(), output: profile)
        let expected = try converter.quantized(PixelBuffer(width: 7, height: 15, pixels: pixels))
        let url = folder.appendingPathComponent("\(profile)-\(compression).tiff")
        try TIFFCodec.write(
          url: url, width: 7, height: 15, profile: converter.outputProfile, compression: compression
        ) { rows in
          Array(expected[(rows.lowerBound * 21)..<(rows.upperBound * 21)])
        }
        let file = try Data(contentsOf: url)
        XCTAssertEqual(tiffTag(file, 34675), converter.outputProfile)
        XCTAssertEqual(tiffTag(file, 274), Data([1, 0]))
        XCTAssertEqual(tiffTag(file, 259), Data([compression == .none ? 1 : 8, 0]))
        XCTAssertEqual(try TIFFCodec.read(url: url).samples, expected)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.bitsPerComponent, 16)
        XCTAssertEqual(image.bitsPerPixel, 48)
        let decoded = try XCTUnwrap(image.dataProvider?.data) as Data
        let little = image.bitmapInfo.intersection(.byteOrderMask) == .byteOrder16Little
        for y in 0..<15 {
          for x in 0..<21 {
            let offset = y * image.bytesPerRow + x * 2
            let sample = UInt16(decoded[offset]) | UInt16(decoded[offset + 1]) << 8
            XCTAssertEqual(little ? sample : sample.byteSwapped, expected[y * 21 + x])
          }
        }
      }
    }
  }

  func testSingleBatchSnapshotConsistencyAndAllDirectionPixels() async throws {
    let folder = try temporary()
    defer { try? FileManager.default.removeItem(at: folder) }
    try fixture(folder.appendingPathComponent("a.tiff"), width: 3, height: 2)
    try fixture(folder.appendingPathComponent("b.tiff"), width: 3, height: 2)
    let outputFolder = folder.appendingPathComponent("out")
    try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
    var project = try ProjectStore.open(folder: folder)
    let original = try TIFFCodec.read(url: folder.appendingPathComponent("a.tiff"))
    let lut = try identityLUT()
    let engine = ExportEngine(useCPUReference: true)
    for direction in FrameOrientation.allCases {
      project.frames[0].orientation = direction
      project.frames[0].adjustments.timing.master = 19
      project.exportSettings = .init(profile: .proPhoto, compression: .deflate)
      let request = try ExportRequest(
        project: project, targetIDs: Set(project.frames.map(\.id)),
        destinationDirectory: outputFolder)
      var edited = project
      edited.frames[0].adjustments.timing.master = -200
      edited.calibration.gainRGB = SIMD3(repeating: 2)
      edited.frames[0].orientation = .identity
      edited.exportSettings = .init(profile: .sRGB, compression: .none)
      XCTAssertNotEqual(edited.frames[0].adjustments, request.frames[0].adjustments)
      let batch = try await engine.run(request, lut: lut, p3Profile: p3())
      XCTAssertEqual(batch.completedCount, 2)
      let singleRequest = try ExportRequest(
        project: project, targetIDs: [project.frames[0].id], destinationDirectory: outputFolder,
        explicitDestination: outputFolder.appendingPathComponent(
          "single-\(direction.rawValue).tiff"))
      let single = try await engine.run(singleRequest, lut: lut, p3Profile: p3())
      let batchURL = try XCTUnwrap(batch.results[0].destination)
      let singleURL = try XCTUnwrap(single.results[0].destination)
      XCTAssertEqual(try Data(contentsOf: batchURL), try Data(contentsOf: singleURL))
      let read = try TIFFCodec.read(url: singleURL)
      let size = direction.outputSize(sourceWidth: 3, sourceHeight: 2)
      XCTAssertEqual(read.width, size.width)
      XCTAssertEqual(read.height, size.height)
      let unrotated = try Pipeline.render(
        original.preview(maxDimension: 3), calibration: project.calibration,
        adjustments: project.frames[0].adjustments, lut: lut)
      let converter = try OutputColorConverter(p3Profile: p3(), output: .proPhoto)
      let expected = try converter.quantized(direction.transform(unrotated))
      XCTAssertEqual(read.samples, expected)
      XCTAssertEqual(tiffTag(try Data(contentsOf: singleURL), 274), Data([1, 0]))
    }
  }

  func testCropExportSnapshotAllICCCompressionsAndAnalyticLinearSampling() async throws {
    let folder = try temporary()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("crop-source.tiff")
    let profile = try p3()
    // An affine UInt16 field has an independent exact bilinear solution. Its
    // three unequal channels also catch accidental input ICC/gamma conversion.
    try TIFFCodec.write(url: source, width: 120, height: 80, profile: profile) { rows in
      var samples: [UInt16] = []
      for y in rows {
        for x in 0..<120 {
          for c in 0..<3 { samples.append(UInt16(20000 + 100 * x + 150 * y + 3000 * c)) }
        }
      }
      return samples
    }
    let original = try Data(contentsOf: source)
    var project = try ProjectStore.open(folder: folder)
    // The independent affine/density reference assumes no calibration matrices.
    project.calibration = FilmCalibration()
    let lut = try identityLUT()
    let engine = ExportEngine(useCPUReference: true)
    for angle in [0.0, 6.73] {
      let crop = FrameCrop(width: 0.5, angleDegrees: angle)
      project.frames[0].crop = crop
      let radians = angle * .pi / 180
      var analytic: [SIMD4<Float>] = []
      for y in 0..<40 {
        for x in 0..<60 {
          let dx = Double(x) + 0.5 - 30, dy = Double(y) + 0.5 - 20
          let sx = cos(radians) * dx + sin(radians) * dy + 60 - 0.5
          let sy = -sin(radians) * dx + cos(radians) * dy + 40 - 0.5
          var color = SIMD4<Float>(repeating: 1)
          for c in 0..<3 {
            let linear = (20000 + 100 * sx + 150 * sy + 3000 * Double(c)) / 65535
            color[c] = Float(-log10(linear) / 2.048)
          }
          analytic.append(color)
        }
      }
      for output in OutputColorProfile.allCases {
        for compression in TIFFCompression.allCases {
          project.exportSettings = .init(profile: output, compression: compression)
          let request = try ExportRequest(project: project, targetIDs: [project.frames[0].id],
                                          destinationDirectory: folder)
          var edited = project
          edited.frames[0].crop = FrameCrop(aspect: .square, angleDegrees: -10)
          XCTAssertEqual(request.frames[0].crop, crop)
          XCTAssertNotEqual(request.frames[0].crop, edited.frames[0].crop)
          let summary = try await engine.run(request, lut: lut, p3Profile: profile)
          XCTAssertEqual(summary.completedCount, 1, summary.results.first?.error ?? "")
          let destination = try XCTUnwrap(summary.results[0].destination)
          let image = try TIFFCodec.read(url: destination)
          XCTAssertEqual(image.width, 60)
          XCTAssertEqual(image.height, 40)
          let converter = try OutputColorConverter(p3Profile: profile, output: output)
          let expected = try converter.quantized(PixelBuffer(width: 60, height: 40, pixels: analytic))
          for index in expected.indices {
            XCTAssertLessThanOrEqual(abs(Int(image.samples[index]) - Int(expected[index])), 1,
                                    "\(output) \(compression) angle \(angle) sample \(index)")
          }
          let bytes = try Data(contentsOf: destination)
          XCTAssertEqual(tiffTag(bytes, 34675), converter.outputProfile)
          XCTAssertEqual(tiffTag(bytes, 274), Data([1, 0]))
        }
      }
    }
    XCTAssertEqual(try Data(contentsOf: source), original)
  }

  func testSharedSourceCropBatchExportKeepsSameOriginalRegionForEveryDirection() async throws {
    let folder = try temporary()
    defer { try? FileManager.default.removeItem(at: folder) }
    for orientation in FrameOrientation.allCases {
      try fixture(folder.appendingPathComponent("source-\(orientation.rawValue).tiff"), width: 120, height: 80)
    }
    var project = try ProjectStore.open(folder: folder)
    let crop = try FrameCrop(aspect: .sevenSix, centerX: 0.27, centerY: 0.61,
                             width: 0.35, angleDegrees: 6.73)
      .constrained(sourceWidth: 120, sourceHeight: 80)
    XCTAssertEqual(crop.geometryVersion, 2)
    for index in project.frames.indices {
      project.frames[index].crop = crop
      project.frames[index].orientation = FrameOrientation.allCases[index]
    }
    project.exportSettings = .init(profile: .sRGB, compression: .deflate)
    let request = try ExportRequest(project: project, targetIDs: Set(project.frames.map(\.id)),
                                    destinationDirectory: folder)
    XCTAssertTrue(request.frames.allSatisfy { $0.crop == crop })
    let summary = try await ExportEngine(useCPUReference: true).run(request, lut: identityLUT(), p3Profile: p3())
    XCTAssertEqual(summary.completedCount, 8)
    let originalCrop = try TIFFCodec.read(url: XCTUnwrap(summary.results[0].destination))
    for (index, result) in summary.results.enumerated() {
      let direction = FrameOrientation.allCases[index]
      let actual = try TIFFCodec.read(url: XCTUnwrap(result.destination))
      let size = direction.outputSize(sourceWidth: originalCrop.width, sourceHeight: originalCrop.height)
      XCTAssertEqual(actual.width, size.width)
      XCTAssertEqual(actual.height, size.height)
      for y in 0..<actual.height {
        for x in 0..<actual.width {
          let from = direction.inversePixel(x: x, y: y,
            sourceWidth: originalCrop.width, sourceHeight: originalCrop.height)
          for channel in 0..<3 {
            let expected = originalCrop.samples[(from.y * originalCrop.width + from.x) * 3 + channel]
            let value = actual.samples[(y * actual.width + x) * 3 + channel]
            XCTAssertLessThanOrEqual(abs(Int(value) - Int(expected)), 1,
                                    "\(direction) pixel \(x),\(y) channel \(channel)")
          }
        }
      }
    }
  }

  func testPrefixUsesOriginalRollNumbersAndZIP() async throws {
    let folder = try temporary()
    defer { try? FileManager.default.removeItem(at: folder) }
    for name in ["a.tiff", "b.tiff", "c.tiff"] { try fixture(folder.appendingPathComponent(name)) }
    let project = try ProjectStore.open(folder: folder)
    XCTAssertEqual(project.exportSettings.compression, .deflate)
    let engine = ExportEngine(useCPUReference: true)
    let single = try ExportRequest(project: project, targetIDs: [project.frames[1].id],
      destinationDirectory: folder, filenamePrefix: "假日")
    let result = try await engine.run(single, lut: identityLUT(), p3Profile: p3())
    let url = try XCTUnwrap(result.results.first?.destination)
    XCTAssertEqual(url.lastPathComponent, "假日-02.tiff")
    XCTAssertEqual(tiffTag(try Data(contentsOf: url), 259), Data([8, 0]))
    _ = try TIFFCodec.read(url: url)
    let batch = try ExportRequest(project: project,
      targetIDs: [project.frames[1].id, project.frames[2].id],
      destinationDirectory: folder, filenamePrefix: "假日")
    let repeated = try await engine.run(batch, lut: identityLUT(), p3Profile: p3())
    XCTAssertEqual(repeated.results.compactMap { $0.destination?.lastPathComponent },
      ["假日-02-1.tiff", "假日-03.tiff"])
    for prefix in ["", "../bad", "bad:name"] {
      XCTAssertThrowsError(try ExportRequest(project: project, targetIDs: [project.frames[1].id],
        destinationDirectory: folder, filenamePrefix: prefix))
    }
  }

  func testFailureContinuesConflictSuffixAndProtectsAllOriginals() async throws {
    let folder = try temporary()
    defer { try? FileManager.default.removeItem(at: folder) }
    for name in ["a.tiff", "b.tiff", "c.tiff"] { try fixture(folder.appendingPathComponent(name)) }
    let project = try ProjectStore.open(folder: folder)
    let snapshot = try ExportRequest(
      project: project, targetIDs: Set(project.frames.map(\.id)), destinationDirectory: folder)
    try Data("occupied".utf8).write(to: folder.appendingPathComponent("a-Printroom.tiff"))
    try FileManager.default.removeItem(at: folder.appendingPathComponent("b.tiff"))
    let engine = ExportEngine(useCPUReference: true)
    let summary = try await engine.run(snapshot, lut: identityLUT(), p3Profile: p3())
    XCTAssertEqual(summary.completedCount, 2)
    XCTAssertEqual(summary.failedCount, 1)
    XCTAssertEqual(summary.results[0].destination?.lastPathComponent, "a-Printroom-1.tiff")
    XCTAssertEqual(summary.results[1].status, .failed)
    XCTAssertNotNil(summary.results[1].error)
    XCTAssertEqual(
      try String(contentsOf: folder.appendingPathComponent("a-Printroom.tiff"), encoding: .utf8),
      "occupied")
    let protected = folder.appendingPathComponent("c.tiff")
    let before = try Data(contentsOf: protected)
    let bad = try ExportRequest(
      project: project, targetIDs: [project.frames[0].id], destinationDirectory: folder,
      explicitDestination: protected)
    let rejected = try await engine.run(bad, lut: identityLUT(), p3Profile: p3())
    XCTAssertEqual(rejected.failedCount, 1)
    XCTAssertEqual(try Data(contentsOf: protected), before)
    let named = folder.appendingPathComponent("chosen.tiff")
    try Data("other writer".utf8).write(to: named)
    let explicit = try ExportRequest(
      project: project, targetIDs: [project.frames[0].id], destinationDirectory: folder,
      explicitDestination: named)
    let suffixed = try await engine.run(explicit, lut: identityLUT(), p3Profile: p3())
    XCTAssertEqual(suffixed.results.first?.destination?.lastPathComponent, "chosen-1.tiff")
    XCTAssertFalse(
      try FileManager.default.contentsOfDirectory(atPath: folder.path).contains {
        $0.hasSuffix(".tmp")
      })
  }

  func testCancelKeepsCompletedAndCleansTemporaryFile() async throws {
    let folder = try temporary()
    defer { try? FileManager.default.removeItem(at: folder) }
    for name in ["a.tiff", "b.tiff", "c.tiff"] { try fixture(folder.appendingPathComponent(name)) }
    let project = try ProjectStore.open(folder: folder)
    let request = try ExportRequest(
      project: project, targetIDs: Set(project.frames.map(\.id)), destinationDirectory: folder)
    let lut = try identityLUT()
    let profile = try p3()
    let task = Task.detached {
      try await ExportEngine(useCPUReference: true, maximumConcurrentExports: 1).run(request, lut: lut, p3Profile: profile) {
        update in
        if update.processedCount == 1, update.frameProgress > 0.2 {
          withUnsafeCurrentTask { $0?.cancel() }
        }
      }
    }
    let summary = try await task.value
    XCTAssertTrue(summary.wasCancelled)
    XCTAssertEqual(summary.results.map(\.status), [.completed, .cancelled, .notStarted])
    XCTAssertEqual(summary.completedCount, 1)
    XCTAssertEqual(summary.cancelledCount, 2)
    let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
    XCTAssertTrue(names.contains("a-Printroom.tiff"))
    XCTAssertFalse(names.contains("b-Printroom.tiff"))
    XCTAssertFalse(names.contains { $0.hasSuffix(".tmp") })
  }

  func testFourLaneBatchMatchesSerialAndReportsMonotonicProgress() async throws {
    let folder = try temporary()
    defer { try? FileManager.default.removeItem(at: folder) }
    for index in 0..<9 {
      try fixture(folder.appendingPathComponent("frame-\(index).tiff"), width: 257, height: 513)
    }
    var project = try ProjectStore.open(folder: folder)
    project.exportSettings = .init(profile: .proPhoto, compression: .deflate)
    for index in project.frames.indices {
      project.frames[index].adjustments.timing.red = index * 7
      project.frames[index].orientation = FrameOrientation.allCases[index % 8]
    }
    let serialFolder = folder.appendingPathComponent("serial")
    let parallelFolder = folder.appendingPathComponent("parallel")
    for url in [serialFolder, parallelFolder] {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    let targets = Set(project.frames.map(\.id))
    let serial = try await ExportEngine(useCPUReference: true, maximumConcurrentExports: 1).run(
      ExportRequest(project: project, targetIDs: targets, destinationDirectory: serialFolder),
      lut: identityLUT(), p3Profile: p3())
    let capture = ExportProgressCapture()
    let parallel = try await ExportEngine(useCPUReference: true).run(
      ExportRequest(project: project, targetIDs: targets, destinationDirectory: parallelFolder),
      lut: identityLUT(), p3Profile: p3()) { capture.record($0, folder: parallelFolder) }
    XCTAssertEqual(serial.completedCount, 9)
    XCTAssertEqual(parallel.completedCount, 9)
    XCTAssertEqual(parallel.results.map(\.id), project.frames.map(\.id))
    for (a, b) in zip(serial.results, parallel.results) {
      XCTAssertEqual(try Data(contentsOf: XCTUnwrap(a.destination)),
                     try Data(contentsOf: XCTUnwrap(b.destination)))
    }
    let updates = capture.updates
    XCTAssertEqual(updates.last?.fraction, 1)
    XCTAssertEqual(updates.last?.completedCount, 9)
    for (a, b) in zip(updates, updates.dropFirst()) {
      XCTAssertLessThanOrEqual(a.fraction, b.fraction + 1e-12)
      XCTAssertLessThanOrEqual(a.processedCount, b.processedCount)
    }
    XCTAssertGreaterThan(capture.peakUnpublished, 1)
    XCTAssertLessThanOrEqual(capture.peakUnpublished, 4)
  }

  func testParallelCancellationKeepsPublishedFilesAndStopsQueuedFrames() async throws {
    let folder = try temporary()
    defer { try? FileManager.default.removeItem(at: folder) }
    for index in 0..<9 {
      try fixture(folder.appendingPathComponent("frame-\(index).tiff"), width: 257, height: 513)
    }
    let project = try ProjectStore.open(folder: folder)
    let request = try ExportRequest(project: project, targetIDs: Set(project.frames.map(\.id)),
      destinationDirectory: folder)
    let lut = try identityLUT(), profile = try p3()
    let task = Task.detached {
      try await ExportEngine(useCPUReference: true).run(request, lut: lut, p3Profile: profile) {
        if $0.completedCount == 1 { withUnsafeCurrentTask { $0?.cancel() } }
      }
    }
    let result = try await task.value
    XCTAssertTrue(result.wasCancelled)
    XCTAssertGreaterThanOrEqual(result.completedCount, 1)
    XCTAssertLessThanOrEqual(result.completedCount, 4)
    XCTAssertGreaterThanOrEqual(result.results.filter { $0.status == .notStarted }.count, 5)
    XCTAssertEqual(result.results.map(\.id), project.frames.map(\.id))
    for frame in result.results where frame.status == .completed {
      XCTAssertNoThrow(try TIFFCodec.read(url: XCTUnwrap(frame.destination)))
    }
    let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
    XCTAssertEqual(files.filter { $0.contains("-Printroom") }.count, result.completedCount)
    XCTAssertFalse(files.contains { $0.hasSuffix(".tmp") })
  }

  func testParallelSameBasenameCannotOverwriteAndFailureDoesNotStopQueue() async throws {
    let folder = try temporary()
    defer { try? FileManager.default.removeItem(at: folder) }
    try fixture(folder.appendingPathComponent("same.tif"), width: 7, height: 97)
    try fixture(folder.appendingPathComponent("same.tiff"), width: 11, height: 65)
    try fixture(folder.appendingPathComponent("missing.tiff"))
    for index in 0..<5 { try fixture(folder.appendingPathComponent("extra-\(index).tiff")) }
    let project = try ProjectStore.open(folder: folder)
    let request = try ExportRequest(project: project, targetIDs: Set(project.frames.map(\.id)),
      destinationDirectory: folder)
    try FileManager.default.removeItem(at: folder.appendingPathComponent("missing.tiff"))
    let result = try await ExportEngine(useCPUReference: true).run(request, lut: identityLUT(), p3Profile: p3())
    XCTAssertEqual(result.failedCount, 1)
    XCTAssertEqual(result.completedCount, 7)
    XCTAssertEqual(Set(result.results.compactMap(\.destination)).count, 7)
    for frame in result.results where frame.sourceName.hasPrefix("same.") {
      let image = try TIFFCodec.read(url: XCTUnwrap(frame.destination))
      XCTAssertEqual(image.width, frame.sourceName == "same.tif" ? 7 : 11)
    }
  }

  func testCancelledBeforeStartDoesNotCreateAnyFiles() async throws {
    let folder = try temporary()
    defer { try? FileManager.default.removeItem(at: folder) }
    try fixture(folder.appendingPathComponent("a.tiff"))
    let project = try ProjectStore.open(folder: folder)
    let request = try ExportRequest(project: project, targetIDs: Set(project.frames.map(\.id)),
      destinationDirectory: folder)
    let lut = try identityLUT(), profile = try p3()
    let task = Task.detached {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await ExportEngine(useCPUReference: true).run(request, lut: lut, p3Profile: profile)
    }
    let result = try await task.value
    XCTAssertTrue(result.wasCancelled)
    XCTAssertEqual(result.results.map(\.status), [.notStarted])
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["a.tiff"])
  }

  func testConflictDecisionsPreserveOrReplaceTIFFAndJPEG() async throws {
    for format in ExportFormat.allCases {
      let folder = try temporary()
      defer { try? FileManager.default.removeItem(at: folder) }
      let source = folder.appendingPathComponent("a.tiff")
      try fixture(source)
      var project = try ProjectStore.open(folder: folder)
      project.exportSettings.format = format
      let target = folder.appendingPathComponent("chosen." + format.fileExtension)
      let original = Data("existing export".utf8)
      try original.write(to: target)
      let request = try ExportRequest(project: project, targetIDs: [project.frames[0].id],
        destinationDirectory: folder, explicitDestination: target)
      let engine = ExportEngine(useCPUReference: true)
      let cancelled = try await engine.run(request, lut: identityLUT(), p3Profile: p3(),
        resolveConflict: { url in XCTAssertEqual(url, target); return .cancel })
      XCTAssertTrue(cancelled.wasCancelled)
      XCTAssertEqual(try Data(contentsOf: target), original)
      let renamed = try await engine.run(request, lut: identityLUT(), p3Profile: p3(),
        resolveConflict: { _ in .rename })
      XCTAssertEqual(renamed.results.first?.destination?.lastPathComponent, "chosen-1." + format.fileExtension)
      XCTAssertEqual(try Data(contentsOf: target), original)
      let replaced = try await engine.run(request, lut: identityLUT(), p3Profile: p3(),
        resolveConflict: { _ in .overwrite })
      XCTAssertEqual(replaced.completedCount, 1)
      XCTAssertEqual(replaced.results.first?.destination, target)
      XCTAssertEqual(try Data(contentsOf: target), try Data(contentsOf: XCTUnwrap(renamed.results.first?.destination)))
      let protected = try ExportRequest(project: project, targetIDs: [project.frames[0].id],
        destinationDirectory: folder, explicitDestination: source)
      let before = try Data(contentsOf: source)
      let rejected = try await engine.run(protected, lut: identityLUT(), p3Profile: p3(),
        resolveConflict: { _ in XCTFail("Must not offer replacement of originals"); return .overwrite })
      XCTAssertEqual(rejected.failedCount, 1)
      XCTAssertEqual(try Data(contentsOf: source), before)
      XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains { $0.hasSuffix(".tmp") })
    }
  }

  func testCancellationDuringOverwriteKeepsOldFile() async throws {
    let folder = try temporary()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("a.tiff")
    try fixture(source, width: 65, height: 129)
    let target = folder.appendingPathComponent("old.tiff")
    let original = Data("old completed export".utf8)
    try original.write(to: target)
    let request = try ExportRequest(source: source, destination: target,
      calibration: .init(), adjustments: .init())
    let lut = try identityLUT(), profile = try p3()
    let task = Task.detached {
      try await ExportEngine(useCPUReference: true).run(request, lut: lut, p3Profile: profile,
        resolveConflict: { _ in .overwrite }) {
          if $0.frameProgress > 0.2 { withUnsafeCurrentTask { $0?.cancel() } }
        }
    }
    let summary = try await task.value
    XCTAssertTrue(summary.wasCancelled)
    XCTAssertEqual(try Data(contentsOf: target), original)
    XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)), ["a.tiff", "old.tiff"])
  }

  func testTIFFPublicationRaceDoesNotReplaceOtherWriter() throws {
    let folder = try temporary()
    defer { try? FileManager.default.removeItem(at: folder) }
    let target = folder.appendingPathComponent("race.tiff")
    XCTAssertThrowsError(
      try TIFFCodec.write(url: target, width: 3, height: 65, profile: p3(), compression: .deflate) {
        rows in
        if rows.lowerBound == 32 { try Data("won by other writer".utf8).write(to: target) }
        return [UInt16](repeating: 32768, count: rows.count * 9)
      }
    ) { error in
      XCTAssertEqual(error as? TIFFWriteError, .destinationExists("race.tiff"))
    }
    XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "won by other writer")
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["race.tiff"])
  }

  func testQueueRetriesPublicationRaceAndSourceChangeFails() async throws {
    let folder = try temporary()
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("a.tiff")
    try fixture(source)
    let project = try ProjectStore.open(folder: folder)
    let target = folder.appendingPathComponent("race.tiff")
    let request = try ExportRequest(
      project: project, targetIDs: [project.frames[0].id],
      destinationDirectory: folder, explicitDestination: target)
    let engine = ExportEngine(useCPUReference: true)
    let summary = try await engine.run(request, lut: identityLUT(), p3Profile: p3()) { update in
      if update.frameProgress > 0.2, !FileManager.default.fileExists(atPath: target.path) {
        try? Data("competing writer".utf8).write(to: target)
      }
    }
    XCTAssertEqual(summary.completedCount, 1)
    XCTAssertEqual(summary.results.first?.destination?.lastPathComponent, "race-1.tiff")
    XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "competing writer")
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: source.path)
    let changed = try await engine.run(request, lut: identityLUT(), p3Profile: p3())
    XCTAssertEqual(changed.failedCount, 1)
    XCTAssertTrue(changed.results[0].error?.contains("发生变化") == true)
    XCTAssertFalse(
      try FileManager.default.contentsOfDirectory(atPath: folder.path).contains {
        $0.hasSuffix(".tmp")
      })
  }

  func testPublishedPrimariesBradfordAdaptationAndTransferReference() throws {
    func rows(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>) -> simd_double3x3 {
      simd_double3x3(rows: [a, b, c])
    }
    // Independent published RGB-to-XYZ matrices and Bradford D65->D50;
    // none of these reference values is read from production converter metadata.
    let p3D65 = rows(
      SIMD3(0.48657095, 0.26566769, 0.19821729),
      SIMD3(0.22897456, 0.69173852, 0.07928691), SIMD3(0, 0.04511338, 1.04394437))
    let bradford = rows(
      SIMD3(1.0479298, 0.0229468, -0.0501922),
      SIMD3(0.0296278, 0.9904345, -0.0170738), SIMD3(-0.0092430, 0.0150552, 0.7518743))
    let sRGB = rows(
      SIMD3(0.4124564, 0.3575761, 0.1804375),
      SIMD3(0.2126729, 0.7151522, 0.0721750), SIMD3(0.0193339, 0.1191920, 0.9503041))
    let adobe = rows(
      SIMD3(0.5767309, 0.1855540, 0.1881852),
      SIMD3(0.2973769, 0.6273491, 0.0752741), SIMD3(0.0270343, 0.0706872, 0.9911085))
    let rec2020 = rows(
      SIMD3(0.6369580483, 0.1446169036, 0.1688809752),
      SIMD3(0.2627002120, 0.6779980715, 0.0593017165),
      SIMD3(0, 0.0280726930, 1.0609850577))
    let proPhotoD50 = rows(
      SIMD3(0.7976749, 0.1351917, 0.0313534),
      SIMD3(0.2880402, 0.7118741, 0.0000857), SIMD3(0, 0, 0.82521))
    let colors: [SIMD4<Float>] = [
      SIMD4(0.02, 0.03, 0.01, 1), SIMD4(0.9, 0.1, 0.3, 1),
      SIMD4(0.1, 0.8, 0.2, 1), SIMD4(0.2, 0.3, 0.9, 1), SIMD4(1, 1, 1, 1),
    ]
    for profile in OutputColorProfile.allCases {
      let actual = try OutputColorConverter(p3Profile: p3(), output: profile).convert(
        PixelBuffer(width: colors.count, height: 1, pixels: colors))
      var maxError: Double = 0
      for (index, color) in colors.enumerated() {
        let sourceLinear = SIMD3(
          pow(Double(color.x), 2.6), pow(Double(color.y), 2.6), pow(Double(color.z), 2.6))
        let linear: SIMD3<Double>
        switch profile {
        case .sRGB: linear = sRGB.inverse * p3D65 * sourceLinear
        case .displayP3: linear = sourceLinear
        case .rec2020: linear = rec2020.inverse * p3D65 * sourceLinear
        case .adobeRGB: linear = adobe.inverse * p3D65 * sourceLinear
        case .proPhoto: linear = proPhotoD50.inverse * bradford * p3D65 * sourceLinear
        }
        for channel in 0..<3 {
          let value = max(0, linear[channel])
          let encoded: Double
          switch profile {
          case .sRGB, .displayP3:
            encoded = value <= 0.0031308 ? 12.92 * value : 1.055 * pow(value, 1 / 2.4) - 0.055
          case .rec2020: encoded = pow(value, 1 / 2.4)
          case .adobeRGB: encoded = pow(value, 1 / (563.0 / 256))
          case .proPhoto: encoded = value < 1.0 / 512 ? value * 16 : pow(value, 1 / 1.8)
          }
          let error = abs(min(1, max(0, Double(actual.pixels[index][channel]))) - min(1, encoded))
          maxError = max(maxError, error)
          XCTAssertLessThan(error, 0.0005, "\(profile) sample \(index) channel \(channel)")
        }
      }
      print("Published primaries/Bradford ICC reference \(profile): max abs=\(maxError)")
    }
  }

  func testInvalidOutputCannotCreateFile() throws {
    let input = PixelBuffer(width: 1, height: 1, pixels: [SIMD4(.nan, 0, 0, 1)])
    for profile in OutputColorProfile.allCases {
      XCTAssertThrowsError(
        try OutputColorConverter(p3Profile: p3(), output: profile).quantized(input))
    }
    XCTAssertThrowsError(try OutputColorConverter(p3Profile: Data([0]), output: .displayP3))
  }

  func testGrayTransferAgainstIndependentAnalyticDefinitions() throws {
    let levels: [Float] = [0, 0.001, 0.01, 0.02, 0.03, 0.05, 0.1, 0.2, 0.5, 1]
    let buffer = PixelBuffer(
      width: levels.count, height: 1,
      pixels: levels.map { SIMD4<Float>($0, $0, $0, 1) })
    for profile in OutputColorProfile.allCases {
      let values = try OutputColorConverter(p3Profile: p3(), output: profile).convert(buffer)
      for (index, level) in levels.enumerated() {
        let linear = pow(Double(level), 2.600006103515625)
        let expected: Double
        switch profile {
        case .sRGB, .displayP3:
          expected = linear <= 0.0031308 ? 12.92 * linear : 1.055 * pow(linear, 1 / 2.4) - 0.055
        case .rec2020: expected = pow(linear, 1 / 2.4)
        case .adobeRGB: expected = pow(linear, 1 / (563.0 / 256))
        case .proPhoto:
          expected = linear < 1.0 / 512 ? 16 * linear : pow(linear, 1 / 1.8000030517578125)
        }
        // sRGB's fixed 1024-point ICC table and s15Fixed16 colorants explain the
        // small difference from the unquantized published transfer definition.
        XCTAssertEqual(Double(values.pixels[index].x), expected, accuracy: 0.0002)
      }
      print("ICC gray transfer \(profile) \(values.pixels.map(\.x))")
    }
  }

  private func u32(_ data: Data, _ offset: Int, little: Bool = false) -> UInt32 {
    let values = (0..<4).map { UInt32(data[offset + $0]) }
    if little { return values[0] | values[1] << 8 | values[2] << 16 | values[3] << 24 }
    return values[3] | values[2] << 8 | values[1] << 16 | values[0] << 24
  }
  private func iccTags(_ data: Data) -> [String: Data] {
    var result: [String: Data] = [:]
    for index in 0..<Int(u32(data, 128)) {
      let record = 132 + index * 12
      let name = String(data: data[record..<(record + 4)], encoding: .ascii)!
      let start = Int(u32(data, record + 4))
      let length = Int(u32(data, record + 8))
      result[name] = data.subdata(in: start..<(start + length))
    }
    return result
  }
  private func xyz(_ tag: Data) -> SIMD3<Double> {
    SIMD3(
      Double(Int32(bitPattern: u32(tag, 8))) / 65536,
      Double(Int32(bitPattern: u32(tag, 12))) / 65536,
      Double(Int32(bitPattern: u32(tag, 16))) / 65536)
  }
  private func iccMatrix(_ data: Data) throws -> simd_double3x3 {
    let tags = iccTags(data)
    return simd_double3x3(
      columns: (
        xyz(try XCTUnwrap(tags["rXYZ"])),
        xyz(try XCTUnwrap(tags["gXYZ"])), xyz(try XCTUnwrap(tags["bXYZ"]))
      ))
  }
  private func tiffTag(_ data: Data, _ tag: UInt16) -> Data? {
    let start = Int(u32(data, 4, little: true))
    let count = Int(data[start]) | Int(data[start + 1]) << 8
    for index in 0..<count {
      let offset = start + 2 + index * 12
      let key = UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
      if key != tag { continue }
      let kind = UInt16(data[offset + 2]) | UInt16(data[offset + 3]) << 8
      let bytes = Int(u32(data, offset + 4, little: true)) * (kind == 3 ? 2 : (kind == 4 ? 4 : 1))
      let position = bytes <= 4 ? offset + 8 : Int(u32(data, offset + 8, little: true))
      return data.subdata(in: position..<(position + bytes))
    }
    return nil
  }
}

private final class ExportProgressCapture: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [ExportProgress] = []
  private var started: Set<String> = []
  private var peak = 0
  var updates: [ExportProgress] { lock.lock(); defer { lock.unlock() }; return stored }
  var peakUnpublished: Int { lock.lock(); defer { lock.unlock() }; return peak }
  func record(_ update: ExportProgress, folder: URL) {
    lock.lock()
    defer { lock.unlock() }
    stored.append(update)
    if let name = update.currentName { started.insert(name) }
    let outstanding = started.filter { name in
      let output = (name as NSString).deletingPathExtension + "-Printroom.tiff"
      return !FileManager.default.fileExists(atPath: folder.appendingPathComponent(output).path)
    }.count
    peak = max(peak, outstanding)
  }
}
