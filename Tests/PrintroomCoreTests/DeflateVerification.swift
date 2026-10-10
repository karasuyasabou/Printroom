import Darwin
import Foundation
import ImageIO
import XCTest
@testable import PrintroomCore

/// Opt-in full-pixel verification on retained four-photo benchmark outputs.
final class DeflateVerification: XCTestCase {
  func testRealPhotosAgainstZlibBaselineAndImageIO() throws {
    let env = ProcessInfo.processInfo.environment
    guard let oldPath = env["PRINTROOM_DEFLATE_ORACLE"],
      let newPath = env["PRINTROOM_DEFLATE_OUTPUT"] else { throw XCTSkip("Requires retained benchmark outputs") }
    XCTAssertTrue(oldPath.contains("/scratch/performance/"))
    XCTAssertTrue(newPath.contains("/scratch/performance/"))
    let old = URL(fileURLWithPath: oldPath), new = URL(fileURLWithPath: newPath)
    let files = try FileManager.default.contentsOfDirectory(at: new, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "tiff" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    XCTAssertEqual(files.count, 4)
    for url in files {
      try autoreleasepool {
        let reference = try TIFFCodec.read(url: old.appendingPathComponent(url.lastPathComponent))
        let decoded = try TIFFCodec.read(url: url)
        XCTAssertEqual(decoded.width, reference.width)
        XCTAssertEqual(decoded.height, reference.height)
        XCTAssertEqual(decoded.embeddedProfileName, reference.embeddedProfileName)
        XCTAssertTrue(decoded.samples == reference.samples, "Full RGB samples differ: \(url.lastPathComponent)")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, reference.width)
        XCTAssertEqual(image.height, reference.height)
        XCTAssertEqual(image.bitsPerComponent, 16)
        XCTAssertEqual(image.bitsPerPixel, 48)
        XCTAssertEqual(image.alphaInfo, .none)
        let data = try XCTUnwrap(image.dataProvider?.data) as Data
        let little = image.bitmapInfo.intersection(.byteOrderMask) == .byteOrder16Little
        var identical = true
        reference.samples.withUnsafeBytes { expected in
          data.withUnsafeBytes { actual in
            for y in 0..<reference.height {
              let src = actual.baseAddress!.advanced(by: y * image.bytesPerRow)
              let dst = expected.baseAddress!.advanced(by: y * reference.width * 6)
              if little {
                if memcmp(src, dst, reference.width * 6) != 0 { identical = false; break }
              } else {
                let src16 = src.assumingMemoryBound(to: UInt16.self)
                let dst16 = dst.assumingMemoryBound(to: UInt16.self)
                for x in 0..<(reference.width * 3) where src16[x].byteSwapped != dst16[x] { identical = false }
              }
            }
          }
        }
        XCTAssertTrue(identical, "ImageIO samples differ: \(url.lastPathComponent)")
        print("Deflate RGB exact, Core + ImageIO: \(url.lastPathComponent), \(reference.samples.count) samples")
      }
    }
  }
}
