import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
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
    try FileManager.default.setAttributes([
      .creationDate: Date(timeIntervalSince1970: 1_000_000_000),
      .modificationDate: Date(timeIntervalSince1970: 1_100_000_000),
    ], ofItemAtPath: source.path)
    let sourceAttributes = try FileManager.default.attributesOfItem(atPath: source.path)
    let sourceBytes = try Data(contentsOf: source)
    let dates = try ExportDates.read(from: source)
    XCTAssertEqual(dates.exif, withCaptureTime ? exif : [:])
    var values: [SIMD4<Float>] = []
    for b in 0...1 { for g in 0...1 { for r in 0...1 { values.append(SIMD4(Float(r), Float(g), Float(b), 1)) } } }
    let lut = try CubeLUT(size: 2, values: values)
    let engine = ExportEngine(useCPUReference: true)
    for mode in 0..<3 {
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
        let reader = try XCTUnwrap(CGImageSourceCreateWithURL(target as CFURL, nil))
        let actual = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(reader, 0, nil) as? [String: Any])
        let actualExif = actual[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        for (key, expected) in exif {
          XCTAssertEqual(actualExif[key] as? String, withCaptureTime ? expected : nil, key)
        }
        let tiff = actual[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        XCTAssertEqual(tiff?[kCGImagePropertyTIFFDateTime as String] as? String,
          withCaptureTime ? "2021:02:03 04:05:06" : nil)
        let attrs = try FileManager.default.attributesOfItem(atPath: target.path)
        for key in [FileAttributeKey.creationDate, .modificationDate] {
          XCTAssertEqual(try XCTUnwrap(attrs[key] as? Date).timeIntervalSince1970,
            try XCTUnwrap(sourceAttributes[key] as? Date).timeIntervalSince1970, accuracy: 0.001)
        }
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(reader, 0, nil))
        XCTAssertEqual(decoded.width, 4)
        XCTAssertEqual(decoded.height, 4)
        if mode != 2 { XCTAssertEqual(try TIFFCodec.read(url: target).width, 4) }
      }
    }
    XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
    let after = try FileManager.default.attributesOfItem(atPath: source.path)
    XCTAssertEqual(after[.modificationDate] as? Date, sourceAttributes[.modificationDate] as? Date)
    XCTAssertEqual(after[.creationDate] as? Date, sourceAttributes[.creationDate] as? Date)
    XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains { $0.hasPrefix(".printroom-") })
  }
}
