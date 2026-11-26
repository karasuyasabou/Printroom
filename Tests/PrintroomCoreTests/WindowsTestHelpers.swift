#if os(Windows)
import CWinPlatform
import Foundation
@testable import PrintroomCore

enum WindowsJPEGTestReader {
  struct DecodedJPEG {
    let width: Int
    let height: Int
    let rgb24: [UInt8]
    let iccProfile: Data
  }

  static func read(url: URL) throws -> DecodedJPEG {
    let data = try Data(contentsOf: url)
    let icc = extractICCProfile(from: data)
    let path = url.withUnsafeFileSystemRepresentation { String(cString: $0!) }
    var rawOut: UnsafeMutablePointer<UInt8>?
    var w: UInt32 = 0
    var h: UInt32 = 0
    var winErr: UInt32 = 0
    let rc = path.withCString { cpath in
      pr_win_wic_decode_image_rgb8(cpath, &rawOut, &w, &h, &winErr)
    }
    guard rc == 0, let rawOut, w > 0, h > 0 else {
      if let rawOut { pr_win_free_buffer(rawOut) }
      throw PrintroomError.invalid("WIC JPEG decode failed (0x\(String(winErr, radix: 16)))")
    }
    let count = Int(w) * Int(h) * 3
    let rgb = Array(UnsafeBufferPointer(start: rawOut, count: count))
    pr_win_free_buffer(rawOut)
    return DecodedJPEG(width: Int(w), height: Int(h), rgb24: rgb, iccProfile: icc)
  }

  static func extractICCProfile(from jpeg: Data) -> Data {
    guard jpeg.count >= 4, jpeg[0] == 0xFF, jpeg[1] == 0xD8 else { return Data() }
    var chunks: [Int: Data] = [:]
    var expectedTotal = 0
    var offset = 2
    while offset + 1 < jpeg.count {
      if jpeg[offset] != 0xFF { break }
      var mOffset = offset + 1
      while mOffset < jpeg.count && jpeg[mOffset] == 0xFF { mOffset += 1 }
      guard mOffset < jpeg.count else { break }
      let marker = jpeg[mOffset]
      if marker == 0xDA || marker == 0xD9 { break }
      if marker == 0x00 || (0xD0...0xD7).contains(marker) {
        offset = mOffset + 1
        continue
      }
      guard mOffset + 2 < jpeg.count else { break }
      let segLen = (Int(jpeg[mOffset + 1]) << 8) | Int(jpeg[mOffset + 2])
      let nextOffset = mOffset + 1 + segLen
      guard segLen >= 2, nextOffset <= jpeg.count else { break }
      let payloadStart = mOffset + 3
      if marker == 0xE2, nextOffset - payloadStart > 14 {
        let sig = Data("ICC_PROFILE\0".utf8)
        if jpeg[payloadStart..<(payloadStart + 12)] == sig {
          let seq = Int(jpeg[payloadStart + 12])
          let total = Int(jpeg[payloadStart + 13])
          expectedTotal = total
          chunks[seq] = jpeg.subdata(in: (payloadStart + 14)..<nextOffset)
        }
      }
      offset = nextOffset
    }
    guard expectedTotal > 0 else { return Data() }
    var out = Data()
    for i in 1...expectedTotal {
      if let part = chunks[i] { out.append(part) }
    }
    return out
  }
}
#endif
