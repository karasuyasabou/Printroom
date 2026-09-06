import CryptoKit
import Foundation
import ImageIO
import XCTest
import zlib

@testable import PrintroomCore

final class TIFFCodecTests: XCTestCase {
  private let known: [UInt16] = [
    0, 1, 65535, 32768, 60000, 10, 65534, 256, 257,
    42, 32767, 50000, 12345, 2, 65000, 100, 200, 300,
  ]
  private var root: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
  }

  func testRawKnownSamplesAndICCDoNotChangeChannels() throws {
    try inTemporaryDirectory { directory in
      for profile in [
        nil, descriptionProfile("Deliberately unrelated RGB"), mlucProfile("P3 D65 Gamma 2.6"),
      ] as [Data?] {
        let url = directory.appendingPathComponent(UUID().uuidString + ".tiff")
        try fixture(profile: profile).write(to: url)
        let image = try TIFFCodec.read(url: url)
        XCTAssertEqual(image.samples, known)
        XCTAssertEqual(image.width, 3)
        XCTAssertEqual(image.height, 2)
        XCTAssertEqual(image.pixel(x: 0, y: 0), SIMD3<Float>(0, 1 / 65535, 1))
        XCTAssertEqual(image.pixel(x: 1, y: 0).x, Float(32768) / 65535)
        XCTAssertEqual(
          image.embeddedProfileName,
          profile == nil
            ? "无嵌入 ICC"
            : profile == descriptionProfile("Deliberately unrelated RGB")
              ? "Deliberately unrelated RGB" : "P3 D65 Gamma 2.6")
      }
    }
  }

  func testEndianDeflatePredictorAndAllOrientations() throws {
    let expectedPixels = [
      [0, 1, 2, 3, 4, 5], [2, 1, 0, 5, 4, 3],
      [5, 4, 3, 2, 1, 0], [3, 4, 5, 0, 1, 2],
      [0, 3, 1, 4, 2, 5], [3, 0, 4, 1, 5, 2],
      [5, 2, 4, 1, 3, 0], [2, 5, 1, 4, 0, 3],
    ]
    try inTemporaryDirectory { directory in
      let url = directory.appendingPathComponent("orientation.tiff")
      for little in [true, false] {
        for compression: UInt32 in [1, 8, 32946] {
          for predictor: UInt32 in [1, 2] {
            for orientation: UInt32 in 1...8 {
              try fixture(
                little: little, compression: compression, predictor: predictor,
                orientation: orientation
              ).write(to: url)
              let image = try TIFFCodec.read(url: url)
              let expected = expectedPixels[Int(orientation) - 1].flatMap {
                Array(known[($0 * 3)..<($0 * 3 + 3)])
              }
              XCTAssertEqual(
                image.samples, expected,
                "endian=\(little), compression=\(compression), predictor=\(predictor), orientation=\(orientation)"
              )
              XCTAssertEqual(image.width, orientation < 5 ? 3 : 2)
              XCTAssertEqual(image.height, orientation < 5 ? 2 : 3)
            }
          }
        }
      }
    }
  }

  func testRejectsUnsupportedAndMalformedFiles() throws {
    try inTemporaryDirectory { directory in
      let url = directory.appendingPathComponent("invalid.tiff")
      let overrides: [[UInt16: [UInt32]]] = [
        [258: [8, 8, 8]], [339: [3, 3, 3]], [339: [2, 2, 2]],
        [262: [1]], [277: [4]], [277: [1]], [284: [2]], [338: [2]],
        [259: [5]], [317: [3]], [274: [0]], [274: [9]], [266: [2]],
        [278: [0]], [256: [0]], [257: [UInt32.max]], [324: [8]],
        [273: [UInt32.max, UInt32.max]], [279: [0, 0]], [279: [1, 1]],
      ]
      for override in overrides {
        try fixture(overrides: override).write(to: url)
        XCTAssertThrowsError(try TIFFCodec.read(url: url), "Accepted \(override)")
      }
      let valid = try fixture(compression: 8)
      for length in [0, 4, 7, 8, valid.count - 1] {
        try valid.prefix(length).write(to: url)
        XCTAssertThrowsError(try TIFFCodec.read(url: url))
      }
      var corrupt = valid
      corrupt[8] ^= 0xff  // Deflate stream, not directory.
      try corrupt.write(to: url)
      XCTAssertThrowsError(try TIFFCodec.read(url: url))
      var bigTIFF = valid
      bigTIFF.replaceSubrange(2..<4, with: [43, 0])
      try bigTIFF.write(to: url)
      XCTAssertThrowsError(try TIFFCodec.read(url: url))
      try Data("not a TIFF image".utf8).write(to: url)
      XCTAssertThrowsError(try TIFFCodec.read(url: url))
    }
  }

  func testOutputHasExactICC16BitRGBAndIndependentImageIODecode() throws {
    try inTemporaryDirectory { directory in
      let profile = try Data(contentsOf: root.appendingPathComponent("ICC/DCIP3_D65.icc"))
      let url = directory.appendingPathComponent("export.tiff")
      try TIFFCodec.write(url: url, width: 3, height: 2, profile: profile) { range in
        XCTAssertEqual(range, 0..<2)
        return self.known
      }
      let file = try Data(contentsOf: url)
      let tags = inspect(file)
      XCTAssertEqual(tags[34675]?.bytes, profile)
      XCTAssertEqual(tags[258]?.values, [16, 16, 16])
      XCTAssertEqual(tags[277]?.values, [3])
      XCTAssertEqual(tags[262]?.values, [2])
      XCTAssertEqual(tags[274]?.values, [1])
      XCTAssertEqual(tags[259]?.values, [1])  // Explicit M1 uncompressed mode.
      XCTAssertEqual(tags[339]?.values, [1, 1, 1])
      XCTAssertNil(tags[338])
      let reread = try TIFFCodec.read(url: url)
      XCTAssertEqual(reread.samples, known)
      XCTAssertEqual(reread.embeddedProfileName, "P3 D65 Gamma 2.6")
      // A separate system decoder verifies interoperability. This path is
      // verification only; production import never depends on ImageIO.
      let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
      XCTAssertEqual(CGImageSourceGetCount(source), 1)
      let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
      XCTAssertEqual(image.width, 3)
      XCTAssertEqual(image.height, 2)
      XCTAssertEqual(image.bitsPerComponent, 16)
      XCTAssertEqual(image.bitsPerPixel, 48)
      XCTAssertEqual(image.alphaInfo, .none)
      let decoded = try XCTUnwrap(image.dataProvider?.data) as Data
      let imageLittleEndian = image.bitmapInfo.intersection(.byteOrderMask) == .byteOrder16Little
      for y in 0..<2 {
        for sample in 0..<9 {
          let offset = y * image.bytesPerRow + sample * 2
          let raw = UInt16(decoded[offset]) | UInt16(decoded[offset + 1]) << 8
          XCTAssertEqual(imageLittleEndian ? raw : raw.byteSwapped, known[y * 9 + sample])
        }
      }
    }
  }

  func testChunkedRowsAndShortInlineICC() throws {
    try inTemporaryDirectory { directory in
      let url = directory.appendingPathComponent("chunks.tiff")
      var nextRow = 0
      var calls = 0
      try TIFFCodec.write(url: url, width: 7, height: 137, profile: Data([9, 8, 7])) { range in
        XCTAssertEqual(range.lowerBound, nextRow)
        XCTAssertLessThanOrEqual(range.count, 64)
        nextRow = range.upperBound
        calls += 1
        return range.flatMap { y in (0..<21).map { UInt16(y * 21 + $0) } }
      }
      XCTAssertEqual(nextRow, 137)
      XCTAssertGreaterThan(calls, 1)
      XCTAssertEqual(try TIFFCodec.read(url: url).samples, (0..<(137 * 21)).map { UInt16($0) })
      XCTAssertEqual(inspect(try Data(contentsOf: url))[34675]?.bytes, Data([9, 8, 7]))
      XCTAssertEqual(
        try FileManager.default.contentsOfDirectory(atPath: directory.path), ["chunks.tiff"])
    }
  }

  func testExistingDestinationAndSymlinkAreNeverOverwritten() throws {
    try inTemporaryDirectory { directory in
      let original = directory.appendingPathComponent("source.tiff")
      let sourceBytes = try fixture()
      try sourceBytes.write(to: original)
      let symlink = directory.appendingPathComponent("alias.tiff")
      try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: original)
      let dangling = directory.appendingPathComponent("dangling.tiff")
      try FileManager.default.createSymbolicLink(
        at: dangling, withDestinationURL: directory.appendingPathComponent("missing"))
      for url in [original, symlink, dangling, directory] {
        XCTAssertThrowsError(
          try TIFFCodec.write(url: url, width: 3, height: 2, profile: Data([1])) { _ in
            XCTFail("Existing destination must be rejected before requesting rows")
            return self.known
          })
      }
      XCTAssertEqual(try Data(contentsOf: original), sourceBytes)
    }
  }

  func testDestinationCreatedDuringWriteWinsWithoutClobbering() throws {
    try inTemporaryDirectory { directory in
      let url = directory.appendingPathComponent("race.tiff")
      let sentinel = Data("concurrent writer".utf8)
      XCTAssertThrowsError(
        try TIFFCodec.write(url: url, width: 3, height: 2, profile: Data([1])) { _ in
          try sentinel.write(to: url)
          return self.known
        })
      XCTAssertEqual(try Data(contentsOf: url), sentinel)
      XCTAssertEqual(
        try FileManager.default.contentsOfDirectory(atPath: directory.path), ["race.tiff"])
    }
  }

  func testCancellationAndIncorrectRowCountCleanUpTemporaryFiles() throws {
    try inTemporaryDirectory { directory in
      let url = directory.appendingPathComponent("cancelled.tiff")
      var calls = 0
      XCTAssertThrowsError(
        try TIFFCodec.write(url: url, width: 3, height: 130, profile: Data([1])) { range in
          calls += 1
          if calls == 2 { throw CancellationError() }
          return [UInt16](repeating: 0, count: range.count * 9)
        }
      ) { XCTAssertTrue($0 is CancellationError) }
      XCTAssertEqual(calls, 2)
      XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
      XCTAssertThrowsError(
        try TIFFCodec.write(url: url, width: 3, height: 2, profile: Data([1])) { _ in [0] })
      XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }
  }

  func testInvalidOutputArgumentsAndMissingDirectoryFailBeforeRows() throws {
    try inTemporaryDirectory { directory in
      let url = directory.appendingPathComponent("invalid.tiff")
      for (width, height, profile) in [
        (0, 2, Data([1])), (2, -1, Data([1])), (Int.max, 2, Data([1])),
        (2, Int.max, Data([1])), (70000, 70000, Data([1])), (1, 1, Data()),
      ] {
        XCTAssertThrowsError(
          try TIFFCodec.write(url: url, width: width, height: height, profile: profile) { _ in
            XCTFail("Invalid output must be rejected before rows")
            return []
          })
      }
      XCTAssertThrowsError(
        try TIFFCodec.write(
          url: directory.appendingPathComponent("missing/out.tiff"), width: 1, height: 1,
          profile: Data([1])
        ) { _ in
          XCTFail("Missing parent must be rejected before rows")
          return [0, 0, 0]
        })
      XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }
  }

  /// Opt in to ~1.64 GB of immutable input reads and a full-size export:
  /// PRINTROOM_VALIDATE_ASSETS=1 swift test --scratch-path /tmp/printroom-io-agent-build --filter TIFFCodecTests
  func testTenReferenceTIFFsAgainstIndependentPythonZlibDecoder() throws {
    guard ProcessInfo.processInfo.environment["PRINTROOM_VALIDATE_ASSETS"] == "1" else {
      throw XCTSkip("Set PRINTROOM_VALIDATE_ASSETS=1 for all ten full-resolution TIFFs.")
    }
    let script = #"""
      import hashlib, json, pathlib, struct, sys, zlib
      root = pathlib.Path(sys.argv[1])
      manifest = json.loads((root / 'assets/manifest.json').read_text())
      result = []
      for asset in manifest['assets']:
          if asset['kind'] != 'reference_tiff': continue
          path = root / asset['path']
          source_hash = hashlib.sha256()
          with path.open('rb') as f:
              for block in iter(lambda: f.read(1048576), b''): source_hash.update(block)
              assert source_hash.hexdigest() == asset['sha256'], path
              f.seek(0); header = f.read(8); endian = '<' if header[:2] == b'II' else '>'
              ifd = struct.unpack(endian+'I', header[4:])[0]
              f.seek(ifd); n = struct.unpack(endian+'H', f.read(2))[0]
              records = [struct.unpack(endian+'HHI4s', f.read(12)) for _ in range(n)]
              tags = {}
              for tag, typ, count, inline in records:
                  if typ not in (1, 3, 4, 7): continue
                  unit = {1:1, 3:2, 4:4, 7:1}[typ]
                  if unit*count <= 4: raw = inline[:unit*count]
                  else:
                      f.seek(struct.unpack(endian+'I', inline)[0]); raw = f.read(unit*count)
                  tags[tag] = raw if typ in (1,7) else struct.unpack(endian+{3:'H',4:'I'}[typ]*count, raw)
              assert tags[258] == (16,16,16) and tags[259] == (8,) and tags[262] == (2,)
              assert tags.get(317,(1,)) == (1,) and tags.get(274,(1,)) == (1,)
              assert tags[277] == (3,) and tags[284] == (1,) and endian == '<'
              sample_hash = hashlib.sha256(); decoded_bytes = 0
              for offset, count in zip(tags[273], tags[279]):
                  f.seek(offset); raw = zlib.decompress(f.read(count))
                  sample_hash.update(raw); decoded_bytes += len(raw)
              width, height = tags[256][0], tags[257][0]
              assert decoded_bytes == width*height*6
              result.append({'path':asset['path'], 'width':width, 'height':height,
                             'sampleSHA256':sample_hash.hexdigest(), 'sourceSHA256':source_hash.hexdigest(),
                             'iccSHA256':hashlib.sha256(tags[34675]).hexdigest()})
      print(json.dumps(result))
      """#
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-c", script, root.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    let json = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
    let references = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [[String: Any]])
    XCTAssertEqual(references.count, 10)
    for reference in references {
      let path = try XCTUnwrap(reference["path"] as? String)
      let image = try TIFFCodec.read(url: root.appendingPathComponent(path))
      XCTAssertEqual(image.width, 7008)
      XCTAssertEqual(image.height, 4672)
      XCTAssertEqual(image.embeddedProfileName, "ProPhoto RGB Linear")
      let digest = image.samples.withUnsafeBytes {
        SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
      }
      XCTAssertEqual(digest, reference["sampleSHA256"] as? String, path)
      XCTAssertEqual(
        reference["iccSHA256"] as? String,
        "0d0cd826330a7ca2b4b4ff08371c9f1a064295e930fbbc6e3e15262151ddbe66")
      print("TIFF raw verification \(path): \(image.samples.count) samples; SHA256=\(digest)")
    }
  }

  func testFullSize7008By4672Export() throws {
    guard ProcessInfo.processInfo.environment["PRINTROOM_VALIDATE_ASSETS"] == "1" else {
      throw XCTSkip("Set PRINTROOM_VALIDATE_ASSETS=1 for the full-size export.")
    }
    try inTemporaryDirectory { directory in
      let url = directory.appendingPathComponent("full-size.tiff")
      let profile = try Data(contentsOf: root.appendingPathComponent("ICC/DCIP3_D65.icc"))
      var nextRow = 0
      try TIFFCodec.write(url: url, width: 7008, height: 4672, profile: profile) { range in
        XCTAssertEqual(range.lowerBound, nextRow)
        nextRow = range.upperBound
        return range.flatMap { y in (0..<(7008 * 3)).map { UInt16(truncatingIfNeeded: y * 31 + $0) }
        }
      }
      XCTAssertEqual(nextRow, 4672)
      let image = try TIFFCodec.read(url: url)
      XCTAssertEqual(image.width, 7008)
      XCTAssertEqual(image.height, 4672)
      XCTAssertEqual(image.embeddedProfileName, "P3 D65 Gamma 2.6")
      // Compare every sample without creating another full-size array.
      let mismatch = image.samples.withUnsafeBufferPointer { samples -> Int? in
        for y in 0..<4672 {
          for i in 0..<(7008 * 3) {
            let offset = y * 7008 * 3 + i
            if samples[offset] != UInt16(truncatingIfNeeded: y * 31 + i) { return offset }
          }
        }
        return nil
      }
      XCTAssertNil(mismatch)
      let file = try Data(contentsOf: url, options: .mappedIfSafe)
      XCTAssertEqual(inspect(file)[34675]?.bytes, profile)
      print(
        "TIFF full-size export: \(file.count) bytes, \(image.samples.count) samples, all samples exact"
      )
    }
  }

  private func inTemporaryDirectory(_ body: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "printroom-tiff-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
  }

  // Independent fixture layout: pixel strips precede the IFD; production writes
  // its IFD and metadata first. A 3x2 fixture has one strip per row.
  private func fixture(
    little: Bool = true, compression: UInt32 = 1, predictor: UInt32 = 1,
    orientation: UInt32? = nil, profile: Data? = nil,
    overrides: [UInt16: [UInt32]] = [:]
  ) throws -> Data {
    var file = Data(repeating: 0, count: 8)
    var offsets: [UInt32] = []
    var counts: [UInt32] = []
    for y in 0..<2 {
      var raw = Data()
      for x in 0..<3 {
        for c in 0..<3 {
          let i = y * 9 + x * 3 + c
          let value = predictor == 2 && x > 0 ? known[i] &- known[i - 3] : known[i]
          raw.append(contentsOf: encoded(UInt32(value), size: 2, little: little))
        }
      }
      if compression != 1 {
        var length = compressBound(uLong(raw.count))
        var packed = Data(count: Int(length))
        let code = packed.withUnsafeMutableBytes { destination in
          raw.withUnsafeBytes { source in
            compress2(
              destination.bindMemory(to: Bytef.self).baseAddress!, &length,
              source.bindMemory(to: Bytef.self).baseAddress!, uLong(raw.count), Z_BEST_SPEED)
          }
        }
        XCTAssertEqual(code, Z_OK)
        packed.count = Int(length)
        raw = packed
      }
      offsets.append(UInt32(file.count))
      counts.append(UInt32(raw.count))
      file.append(raw)
    }
    if file.count % 2 != 0 { file.append(0) }
    let ifd = UInt32(file.count)
    var tags: [UInt16: [UInt32]] = [
      256: [3], 257: [2], 258: [16, 16, 16], 259: [compression],
      262: [2], 273: offsets, 277: [3], 278: [1], 279: counts, 284: [1], 317: [predictor],
    ]
    if let orientation { tags[274] = [orientation] }
    tags.merge(overrides) { _, new in new }
    let tagIDs = (Array(tags.keys) + (profile == nil ? [] : [34675])).sorted()
    var directory = Data(encoded(UInt32(tagIDs.count), size: 2, little: little))
    var extra = Data()
    for tag in tagIDs {
      let type: UInt32 = tag == 34675 ? 7 : [256, 257, 273, 278, 279, 324].contains(tag) ? 4 : 3
      let values = tags[tag] ?? []
      let payload =
        tag == 34675
        ? profile! : Data(values.flatMap { encoded($0, size: type == 4 ? 4 : 2, little: little) })
      directory.append(contentsOf: encoded(UInt32(tag), size: 2, little: little))
      directory.append(contentsOf: encoded(type, size: 2, little: little))
      directory.append(
        contentsOf: encoded(
          UInt32(tag == 34675 ? payload.count : values.count), size: 4, little: little))
      if payload.count <= 4 {
        directory.append(payload)
        directory.append(Data(repeating: 0, count: 4 - payload.count))
      } else {
        directory.append(
          contentsOf: encoded(
            ifd + UInt32(2 + tagIDs.count * 12 + 4 + extra.count), size: 4, little: little))
        extra.append(payload)
        if extra.count % 2 != 0 { extra.append(0) }
      }
    }
    directory.append(Data(repeating: 0, count: 4))
    file.append(directory)
    file.append(extra)
    file.replaceSubrange(
      0..<8,
      with: (little ? [0x49, 0x49] : [0x4d, 0x4d])
        + encoded(42, size: 2, little: little) + encoded(ifd, size: 4, little: little))
    return file
  }

  private func encoded(_ value: UInt32, size: Int, little: Bool) -> [UInt8] {
    (0..<size).map { UInt8(truncatingIfNeeded: value >> ((little ? $0 : size - 1 - $0) * 8)) }
  }

  private func descriptionProfile(_ name: String) -> Data {
    let text = Data(name.utf8) + Data([0])
    var tag = Data("desc".utf8) + Data(repeating: 0, count: 4)
    tag.append(contentsOf: encoded(UInt32(text.count), size: 4, little: false))
    tag.append(text)
    return profileWithDescriptionTag(tag)
  }

  private func mlucProfile(_ name: String) -> Data {
    let text = name.data(using: .utf16BigEndian)!
    var tag = Data("mluc".utf8) + Data(repeating: 0, count: 4)
    for value: UInt32 in [1, 12] { tag.append(contentsOf: encoded(value, size: 4, little: false)) }
    tag.append(Data("enUS".utf8))
    for value in [UInt32(text.count), 28] {
      tag.append(contentsOf: encoded(value, size: 4, little: false))
    }
    tag.append(text)
    return profileWithDescriptionTag(tag)
  }

  private func profileWithDescriptionTag(_ tag: Data) -> Data {
    var profile = Data(repeating: 0, count: 128)
    profile.append(contentsOf: encoded(1, size: 4, little: false))
    profile.append(Data("desc".utf8))
    for value in [144, UInt32(tag.count)] {
      profile.append(contentsOf: encoded(value, size: 4, little: false))
    }
    profile.append(tag)
    profile.replaceSubrange(0..<4, with: encoded(UInt32(profile.count), size: 4, little: false))
    return profile
  }

  private struct InspectedTag {
    let values: [UInt32]
    let bytes: Data
  }

  /// Small independent tag reader for assertions; it never calls TIFFCodec.
  private func inspect(_ file: Data) -> [UInt16: InspectedTag] {
    let little = file[0] == 0x49
    func number(_ start: Int, _ size: Int) -> UInt32 {
      (0..<size).reduce(0) { $0 | UInt32(file[start + $1]) << ((little ? $1 : size - 1 - $1) * 8) }
    }
    let ifd = Int(number(4, 4))
    let count = Int(number(ifd, 2))
    var result: [UInt16: InspectedTag] = [:]
    for i in 0..<count {
      let base = ifd + 2 + i * 12
      let tag = UInt16(number(base, 2))
      let type = number(base + 2, 2)
      let items = Int(number(base + 4, 4))
      let unit = type == 3 ? 2 : type == 4 ? 4 : 1
      let size = unit * items
      let start = size <= 4 ? base + 8 : Int(number(base + 8, 4))
      result[tag] = InspectedTag(
        values: (0..<items).map { number(start + $0 * unit, unit) },
        bytes: file.subdata(in: start..<(start + size)))
    }
    return result
  }
}
