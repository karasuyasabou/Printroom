import CryptoKit
import Foundation
import XCTest
@testable import PrintroomCore

final class RawDecoderTests: XCTestCase, @unchecked Sendable {
  private var root: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  }
  func testPinnedNativeVersionAndEarlyCancellation() throws {
    XCTAssertEqual(RawDecoder.version, "0.22.1-Release")
    XCTAssertThrowsError(try RawDecoder.decode(linearDNG: URL(fileURLWithPath: "/nonexistent.dng"), cancelled: { true })) {
      XCTAssertTrue($0 is CancellationError)
    }
  }
  func testRejectsCFABeforeAnyDemosaicing() throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("printroom-cfa-\(UUID()).dng")
    defer { try? FileManager.default.removeItem(at: path) }
    var bytes = Data([0x49,0x49,42,0,8,0,0,0])
    func u16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { bytes.append(contentsOf: $0) } }
    func u32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { bytes.append(contentsOf: $0) } }
    u16(7)
    for (tag, value) in [(256,10),(257,10),(258,16),(259,1),(262,32803),(277,1),(50706,1)] {
      u16(UInt16(tag)); u16(4); u32(1); u32(UInt32(value))
    }
    u32(0); try bytes.write(to: path)
    XCTAssertThrowsError(try RawDecoder.metadata(linearDNG: path)) {
      XCTAssertTrue($0.localizedDescription.contains("not CFA"))
    }
  }
  func testActualDecodeOnDispatchWorkerDoesNotOverflowItsStack() async throws {
    guard ProcessInfo.processInfo.environment["PRINTROOM_RAW_NATIVE"] == "1" else {
      throw XCTSkip("Set PRINTROOM_RAW_NATIVE=1; requires retained Adobe Linear DNG.")
    }
    let url = root.appendingPathComponent("scratch/raw-adobe-study/DSC07119/direct.dng")
    let digest: String = try await withCheckedThrowingContinuation { continuation in
      DispatchQueue(label: "printroom.native.stack-regression").async {
        do {
          let image = try RawDecoder.decode(linearDNG: url)
          let hash = image.samples.withUnsafeBytes {
            SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
          }
          continuation.resume(returning: hash)
        } catch { continuation.resume(throwing: error) }
      }
    }
    XCTAssertEqual(digest, "f2cc1e1c2ee79c209c89d8ef0ab888a210fc809c1c3ccb156c078c30af1eea0f")
  }
  func testEightProductionNativeDecodesMatchRecordedIndependentHashes() throws {
    guard ProcessInfo.processInfo.environment["PRINTROOM_RAW_NATIVE"] == "1" else {
      throw XCTSkip("Set PRINTROOM_RAW_NATIVE=1; requires retained Adobe study Linear DNGs.")
    }
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("docs/raw-adobe-study-2026-09-09.json"))) as! [String: Any]
    for row in object["comparisons"] as! [[String: Any]] {
      let frame = row["frame"] as! String
      try autoreleasepool {
        let url = root.appendingPathComponent("scratch/raw-adobe-study/\(frame)/direct.dng")
        let metadata = try RawDecoder.metadata(linearDNG: url)
        XCTAssertEqual(metadata.width, 7008); XCTAssertEqual(metadata.height, 4672)
        let image = try RawDecoder.decode(linearDNG: url)
        let hash = image.samples.withUnsafeBytes { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
        XCTAssertEqual(hash, row["rgb_hash"] as? String, frame)
      }
    }
  }
}
