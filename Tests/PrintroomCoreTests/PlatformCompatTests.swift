#if canImport(CryptoKit)
import CryptoKit
#endif
#if os(Windows)
import CWinPlatform
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

  func testWindowsHiddenProcessRunnerSuccessFailureAndCancellation() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("printroom-winproc-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let comspec = ProcessInfo.processInfo.environment["ComSpec"] ?? #"C:\Windows\System32\cmd.exe"#
    let log1 = dir.appendingPathComponent("ok.log")
    var exitCode: Int32 = -1
    var winErr: UInt32 = 0
    let okArgs = ["/c", "echo", "hello_printroom"]
    let okCArgs = okArgs.map { _strdup($0) }
    defer { okCArgs.forEach { free($0) } }
    var okPtrs = okCArgs.map { UnsafePointer($0) }
    let st1 = comspec.withCString { exeC in
      log1.withUnsafeFileSystemRepresentation { logC in
        okPtrs.withUnsafeMutableBufferPointer { buf in
          CWinPlatform.pr_win_run_hidden_process(exeC, buf.baseAddress, buf.count, logC, 5000, nil, nil, &exitCode, &winErr)
        }
      }
    }
    XCTAssertEqual(st1, 0)
    XCTAssertEqual(exitCode, 0)
    XCTAssertTrue((try String(contentsOf: log1, encoding: .utf8)).contains("hello_printroom"))

    // Cancel callback terminates long-running child promptly
    let log2 = dir.appendingPathComponent("cancel.log")
    let cancelArgs = ["/c", "ping", "-n", "10", "127.0.0.1"]
    let cancelCArgs = cancelArgs.map { _strdup($0) }
    defer { cancelCArgs.forEach { free($0) } }
    var cancelPtrs = cancelCArgs.map { UnsafePointer($0) }
    let cancelCb: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { _ in 1 }
    let st2 = comspec.withCString { exeC in
      log2.withUnsafeFileSystemRepresentation { logC in
        cancelPtrs.withUnsafeMutableBufferPointer { buf in
          CWinPlatform.pr_win_run_hidden_process(exeC, buf.baseAddress, buf.count, logC, 10000, cancelCb, nil, &exitCode, &winErr)
        }
      }
    }
    XCTAssertEqual(st2, -2)
  }

  func testWindowsWICPNGEncodeDecodeAndMonitorColorTransform() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("printroom-wincolor-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let p3Data = try Data(contentsOf: root.appendingPathComponent("ICC/DCIP3_D65.icc"))
    let srgbData = try OutputColorProfile.sRGB.profileData(p3: p3Data)

    // 1. WIC 16-bit RGBA PNG round-trip
    let pixels16: [UInt16] = [
      65535, 32768, 0, 65535,
      0, 65535, 16384, 65535,
      1000, 2000, 3000, 65535,
      65535, 65535, 65535, 65535,
    ]
    var pngOut: UnsafeMutablePointer<UInt8>?
    var pngLen: Int = 0
    var winErr: UInt32 = 0
    let encRc = pixels16.withUnsafeBufferPointer { pxBuf in
      p3Data.withUnsafeBytes { iccBuf in
        pr_win_wic_encode_png_rgba16(
          pxBuf.baseAddress, 2, 2,
          iccBuf.baseAddress?.assumingMemoryBound(to: UInt8.self), p3Data.count,
          &pngOut, &pngLen, &winErr)
      }
    }
    XCTAssertEqual(encRc, 0)
    guard let pngOut else { XCTFail("Missing PNG bytes"); return }
    let pngData = Data(bytes: pngOut, count: pngLen)
    pr_win_free_buffer(pngOut)

    let pngURL = dir.appendingPathComponent("thumb.png")
    try pngData.write(to: pngURL)
    var decOut: UnsafeMutablePointer<UInt16>?
    var w: UInt32 = 0, h: UInt32 = 0
    let decRc = pngURL.withUnsafeFileSystemRepresentation { cpath in
      pr_win_wic_decode_png_rgba16(cpath, &decOut, &w, &h, &winErr)
    }
    XCTAssertEqual(decRc, 0)
    XCTAssertEqual(w, 2)
    XCTAssertEqual(h, 2)
    guard let decOut else { XCTFail("Missing decoded PNG"); return }
    let decoded = Array(UnsafeBufferPointer(start: decOut, count: 16))
    pr_win_free_buffer(decOut)
    XCTAssertEqual(decoded, pixels16)

    // 2. WCS/ICM Color Transform: sRGB -> sRGB (written to temp .icc) verifies BGRA channel order
    let srgbFile = dir.appendingPathComponent("srgb_monitor.icc")
    try srgbData.write(to: srgbFile)
    let xform = srgbData.withUnsafeBytes { srcBuf in
      srgbFile.withUnsafeFileSystemRepresentation { dstC in
        pr_win_color_transform_create(
          srcBuf.baseAddress?.assumingMemoryBound(to: UInt8.self), srgbData.count, dstC, &winErr)
      }
    }
    XCTAssertNotNil(xform, "WCS transform creation failed: 0x\(String(winErr, radix: 16))")
    if let xform {
      defer { pr_win_color_transform_destroy(xform) }
      // Pure red, pure green, pure blue, white
      let inRGB16: [UInt16] = [
        65535, 0, 0,
        0, 65535, 0,
        0, 0, 65535,
        65535, 65535, 65535,
      ]
      var outBGRA = [UInt8](repeating: 0, count: 16)
      let xRc = inRGB16.withUnsafeBufferPointer { inBuf in
        outBGRA.withUnsafeMutableBufferPointer { outBuf in
          pr_win_color_transform_apply_bgra8(xform, inBuf.baseAddress, outBuf.baseAddress, 4, 1, &winErr)
        }
      }
      XCTAssertEqual(xRc, 0)
      // Red in BGRA: [B<=2, G<=2, R>=253, A==255]
      XCTAssertLessThanOrEqual(outBGRA[0], 2)
      XCTAssertLessThanOrEqual(outBGRA[1], 2)
      XCTAssertGreaterThanOrEqual(outBGRA[2], 253)
      XCTAssertEqual(outBGRA[3], 255)
      // Green in BGRA
      XCTAssertLessThanOrEqual(outBGRA[4], 2)
      XCTAssertGreaterThanOrEqual(outBGRA[5], 253)
      XCTAssertLessThanOrEqual(outBGRA[6], 2)
      XCTAssertEqual(outBGRA[7], 255)
      // Blue in BGRA
      XCTAssertGreaterThanOrEqual(outBGRA[8], 253)
      XCTAssertLessThanOrEqual(outBGRA[9], 2)
      XCTAssertLessThanOrEqual(outBGRA[10], 2)
      XCTAssertEqual(outBGRA[11], 255)
      // White in BGRA
      XCTAssertEqual(outBGRA[12], 255)
      XCTAssertEqual(outBGRA[13], 255)
      XCTAssertEqual(outBGRA[14], 255)
      XCTAssertEqual(outBGRA[15], 255)
    }

    // 3. Primary monitor ICC query should not crash
    var iccBuf = [CChar](repeating: 0, count: 4096)
    _ = pr_win_get_monitor_icc_path(0, &iccBuf, iccBuf.count)
  }
  #endif
}
