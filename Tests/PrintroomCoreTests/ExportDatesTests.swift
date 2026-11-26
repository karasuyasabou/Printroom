#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
#if canImport(ImageIO)
import ImageIO
#endif
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif
import XCTest
@testable import PrintroomCore

final class ExportDatesTests: XCTestCase, @unchecked Sendable {
  private let exif = [
    "DateTimeOriginal": "2004:05:06 07:08:09", "DateTimeDigitized": "2020:10:11 12:13:14",
    "OffsetTimeOriginal": "+08:00", "OffsetTimeDigitized": "+09:00", "OffsetTime": "+07:00",
    "SubsecTimeOriginal": "123456", "SubsecTimeDigitized": "654321", "SubsecTime": "789",
  ]

  func testDatesSurviveBothFormatsCompressionAndReplacement() async throws {
    try await checkExport(withCaptureTime: true)
  }

  func testMissingCaptureTimeIsNotInvented() async throws {
    try await checkExport(withCaptureTime: false)
  }

  private func checkExport(withCaptureTime: Bool) async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let profile = try Data(contentsOf: root.appendingPathComponent("ICC/DCIP3_D65.icc"))
    let seed = folder.appendingPathComponent("seed.tiff")
    try TIFFCodec.write(url: seed, width: 4, height: 4, profile: profile) { rows in
      Array(repeating: UInt16(25000), count: rows.count * 4 * 3)
    }
    // Independent ImageIO encoder supplies the source timestamp metadata.
    let source = folder.appendingPathComponent("source.tiff")
    #if canImport(ImageIO)
    let seedReader = try XCTUnwrap(CGImageSourceCreateWithURL(seed as CFURL, nil))
    let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(seedReader, 0, nil))
    let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, UTType.tiff.identifier as CFString, 1, nil))
    var properties: [String: Any] = [kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFCompression as String: 1]]
    if withCaptureTime {
      properties[kCGImagePropertyExifDictionary as String] = exif
      properties[kCGImagePropertyTIFFDictionary as String] = [kCGImagePropertyTIFFCompression as String: 1,
        kCGImagePropertyTIFFDateTime as String: "2021:02:03 04:05:06"]
    }
    CGImageDestinationAddImage(writer, image, properties as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(writer))
    #else
    var seedDates = ExportDates()
    if withCaptureTime {
      seedDates.tiffDateTime = "2021:02:03 04:05:06"
      seedDates.exif = exif
    }
    try TIFFCodec.write(url: source, width: 4, height: 4, profile: profile, dates: seedDates) { rows in
      Array(repeating: UInt16(25000), count: rows.count * 4 * 3)
    }
    #endif
    #if os(Windows)
    try PlatformFS.setFileDates(
      source,
      creation: Date(timeIntervalSince1970: 1_000_000_000),
      modification: Date(timeIntervalSince1970: 1_100_000_000)
    )
    let sourceDates = try PlatformFS.getFileDates(source)
    let expectedCreation = try XCTUnwrap(sourceDates.creation)
    let expectedModification = try XCTUnwrap(sourceDates.modification)
    #else
    try FileManager.default.setAttributes([
      .creationDate: Date(timeIntervalSince1970: 1_000_000_000),
      .modificationDate: Date(timeIntervalSince1970: 1_100_000_000),
    ], ofItemAtPath: source.path)
    let sourceAttributes = try FileManager.default.attributesOfItem(atPath: source.path)
    let expectedCreation = try XCTUnwrap(sourceAttributes[.creationDate] as? Date)
    let expectedModification = try XCTUnwrap(sourceAttributes[.modificationDate] as? Date)
    #endif
    let sourceBytes = try Data(contentsOf: source)
    let dates = try ExportDates.read(from: source)
    XCTAssertEqual(dates.exif, withCaptureTime ? exif : [:])
    var values: [SIMD4<Float>] = []
    for b in 0...1 { for g in 0...1 { for r in 0...1 { values.append(SIMD4(Float(r), Float(g), Float(b), 1)) } } }
    let lut = try CubeLUT(size: 2, values: values)
    let engine = ExportEngine(useCPUReference: true)
    #if canImport(ImageIO) || os(Windows)
    let modes = 0..<3
    #else
    let modes = 0..<2
    #endif
    for mode in modes {
      var settings = ProjectExportSettings()
      settings.format = mode == 2 ? .jpeg : .tiff
      settings.compression = mode == 0 ? .none : .deflate
      let target = folder.appendingPathComponent("out-\(mode).\(settings.format.fileExtension)")
      let request = try ExportRequest(source: source, destination: target,
        calibration: .init(), adjustments: .init(), settings: settings)
      for _ in 0..<2 {
        let result = try await engine.run(request, lut: lut, p3Profile: profile,
          resolveConflict: { _ in .overwrite })
        XCTAssertEqual(result.completedCount, 1, "\(result.results)")
        #if canImport(ImageIO)
        let reader = try XCTUnwrap(CGImageSourceCreateWithURL(target as CFURL, nil))
        let actual = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(reader, 0, nil) as? [String: Any])
        let actualExif = actual[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        for (key, expected) in exif {
          XCTAssertEqual(actualExif[key] as? String, withCaptureTime ? expected : nil, key)
        }
        let tiff = actual[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        XCTAssertEqual(tiff?[kCGImagePropertyTIFFDateTime as String] as? String,
          withCaptureTime ? "2021:02:03 04:05:06" : nil)
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(reader, 0, nil))
        XCTAssertEqual(decoded.width, 4)
        XCTAssertEqual(decoded.height, 4)
        #else
        let roundTripDates = try ExportDates.read(from: target)
        XCTAssertEqual(roundTripDates.exif, withCaptureTime ? exif : [:])
        XCTAssertEqual(roundTripDates.tiffDateTime, withCaptureTime ? "2021:02:03 04:05:06" : nil)
        #if os(Windows)
        if mode == 2 {
          let jpg = try WindowsJPEGTestReader.read(url: target)
          XCTAssertEqual(jpg.width, 4)
          XCTAssertEqual(jpg.height, 4)
        }
        #endif
        #endif
        #if os(Windows)
        let actualDates = try PlatformFS.getFileDates(target)
        XCTAssertEqual(try XCTUnwrap(actualDates.creation).timeIntervalSince1970,
          expectedCreation.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(actualDates.modification).timeIntervalSince1970,
          expectedModification.timeIntervalSince1970, accuracy: 0.001)
        #else
        let attrs = try FileManager.default.attributesOfItem(atPath: target.path)
        XCTAssertEqual(try XCTUnwrap(attrs[.creationDate] as? Date).timeIntervalSince1970,
          expectedCreation.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(attrs[.modificationDate] as? Date).timeIntervalSince1970,
          expectedModification.timeIntervalSince1970, accuracy: 0.001)
        #endif
        if mode != 2 { XCTAssertEqual(try TIFFCodec.read(url: target).width, 4) }
      }
    }
    XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
    #if os(Windows)
    let afterDates = try PlatformFS.getFileDates(source)
    XCTAssertEqual(afterDates.modification, expectedModification)
    XCTAssertEqual(afterDates.creation, expectedCreation)
    #else
    let after = try FileManager.default.attributesOfItem(atPath: source.path)
    XCTAssertEqual(after[.modificationDate] as? Date, expectedModification)
    XCTAssertEqual(after[.creationDate] as? Date, expectedCreation)
    #endif
    XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains { $0.hasPrefix(".printroom-") })
  }
}
