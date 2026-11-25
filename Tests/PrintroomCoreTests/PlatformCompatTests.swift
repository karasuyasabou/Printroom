#if canImport(CryptoKit)
import CryptoKit
#endif
import Foundation
#if canImport(simd)
import simd
#endif
import XCTest
@testable import PrintroomCore

final class PlatformCompatTests: XCTestCase {
  private func hex(_ bytes: some Sequence<UInt8>) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
  }

  func testSHA256MatchesNISTVectorsAndPinnedICC() throws {
    XCTAssertEqual(
      hex(SHA256.hash(data: Data())),
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    )
    XCTAssertEqual(
      hex(SHA256.hash(data: Data("abc".utf8))),
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    )
    XCTAssertEqual(
      hex(SHA256.hash(data: Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8))),
      "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
    )
    var streaming = SHA256()
    let chunk = Data(repeating: 0x61, count: 1000)
    for _ in 0..<1000 {
      streaming.update(data: chunk)
    }
    XCTAssertEqual(
      hex(streaming.finalize()),
      "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
    )
    for profile in OutputColorProfile.allCases {
      let data = try profile.profileData(p3: Data())
      XCTAssertEqual(hex(SHA256.hash(data: data)), profile.profileSHA256)
    }
  }

  func testSimdDouble3x3InverseAndTranspose() {
    let m = simd_double3x3(columns: (
      SIMD3(1.2, 0.3, -0.1),
      SIMD3(0.05, 1.4, 0.2),
      SIMD3(-0.15, 0.1, 0.95)
    ))
    let product = m * m.inverse
    for col in 0..<3 {
      for row in 0..<3 {
        XCTAssertEqual(product[col][row], col == row ? 1.0 : 0.0, accuracy: 1e-14)
      }
    }
    let t = m.transpose
    for col in 0..<3 {
      for row in 0..<3 {
        XCTAssertEqual(t[col][row], m[row][col], accuracy: 1e-15)
      }
    }
    let clamped = simd_clamp(SIMD3(-2.0, 0.5, 5.0), SIMD3(0.0, 0.0, 0.0), SIMD3(1.0, 1.0, 1.0))
    XCTAssertEqual(clamped, SIMD3(0.0, 0.5, 1.0))
  }

  #if os(Windows)
  func testWindowsPlatformFSUnicodeExclusiveAndLockContention() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("printroom-winfs-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let unicodeFile = dir.appendingPathComponent("胶卷_01.tiff")
    let sample = [UInt16](repeating: 43210, count: 12)
    try TIFFCodec.write(url: unicodeFile, width: 2, height: 2, profile: nil, compression: .deflate) { _ in
      sample
    }
    let st = try XCTUnwrap(PlatformFS.lstat(unicodeFile))
    XCTAssertTrue(st.isRegular)
    XCTAssertGreaterThan(st.size, 0)
    XCTAssertEqual(try TIFFCodec.read(url: unicodeFile).samples, sample)

    let staging = dir.appendingPathComponent("staging.tmp")
    let h = try PlatformFS.openTempExclusive(staging)
    try PlatformFS.writeAll(handle: h, data: Data("second".utf8))
    try PlatformFS.flushAndClose(handle: h)
    XCTAssertThrowsError(try PlatformFS.moveExclusive(from: staging, to: unicodeFile)) { err in
      XCTAssertTrue(err is TIFFWriteError)
    }

    try PlatformFS.atomicWrite(Data("replaced".utf8), to: unicodeFile)
    XCTAssertEqual(try Data(contentsOf: unicodeFile), Data("replaced".utf8))

    let lockFile = dir.appendingPathComponent(".lock")
    let l1 = try PlatformFS.openLock(lockFile)
    defer { PlatformFS.closeLock(handle: l1) }
    XCTAssertTrue(try PlatformFS.tryLock(handle: l1, exclusive: true))

    let l2 = try PlatformFS.openLock(lockFile)
    defer { PlatformFS.closeLock(handle: l2) }
    XCTAssertFalse(try PlatformFS.tryLock(handle: l2, exclusive: false))
  }
  #endif
}
