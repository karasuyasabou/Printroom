import CoreGraphics
import Foundation
import PrintroomCore
import Testing

@testable import PrintroomApp

@Suite(.serialized)
struct ImageServiceTests {
  private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "PrintroomImageService-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }
  private func fixture(_ url: URL, width: Int = 13, height: Int = 7, offset: Int = 0) throws {
    try TIFFCodec.write(url: url, width: width, height: height, profile: Data([0])) { range in
      ((range.lowerBound * width * 3)..<(range.upperBound * width * 3)).map {
        UInt16(($0 * 173 + offset + 1) % 65536)
      }
    }
  }

  @Test func neutralFootprintIsResolutionIndependentAndClipsAtEdges() {
    let pixels = (0..<(1600 * 800)).map { SIMD4<Float>(Float($0 % 1600), Float($0 / 1600), 0.5, 1) }
    let preview = PixelBuffer(width: 1600, height: 800, pixels: pixels)
    for scale in [1, 2, 5] {
      let sample = ImageService.neutralSample(preview, sourceWidth: 1600 * scale,
        sourceHeight: 800 * scale, sourceX: 800 * scale, sourceY: 400 * scale)
      #expect(sample.width == 13 && sample.height == 13)
      #expect(sample.pixels.first == SIMD4<Float>(794, 394, 0.5, 1))
      #expect(sample.pixels.last == SIMD4<Float>(806, 406, 0.5, 1))
    }
    let corner = ImageService.neutralSample(preview, sourceWidth: 7008,
      sourceHeight: 3504, sourceX: 0, sourceY: 0)
    #expect(corner.width == 7 && corner.height == 7)
    #expect(corner.pixels.last == SIMD4<Float>(6, 6, 0.5, 1))
    let portrait = PixelBuffer(width: 800, height: 1600, pixels: pixels)
    let bottom = ImageService.neutralSample(portrait, sourceWidth: 3504,
      sourceHeight: 7008, sourceX: 3503, sourceY: 7007)
    #expect(bottom.width == 7 && bottom.height == 7)
    #expect(bottom.pixels.last == pixels.last)
  }

  @Test func neutralTIFFUsesUnadjustedPreviewGrid() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("neutral.tiff")
    try fixture(url, width: 3200, height: 400)
    let preview = try TIFFCodec.readPreview(url: url, maxDimension: 1600)
    let sample = try await ImageService().neutralSample(url, sourceX: 1600, sourceY: 200)
    #expect(sample.width == 13 && sample.height == 13)
    for y in 0..<13 {
      for x in 0..<13 {
        #expect(sample.pixels[y * 13 + x] == SIMD4(preview.pixel(x: 794 + x, y: 94 + y), 1))
      }
    }
  }

  @Test func previewRegionAndCalibrationUseExactOriginalSamples() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("samples.tiff")
    try fixture(url)
    let raw = try TIFFCodec.read(url: url)
    let service = ImageService()
    let preview = try await service.thumbnail(url, maxDimension: 5)
    #expect(preview.width == 5 && preview.height == 2)
    #expect(preview.pixels == raw.preview(maxDimension: 5).pixels)
    let region = PixelRect(x: 3, y: 2, width: 4, height: 4)
    let tile = try await service.region(url, rect: region)
    #expect(tile.width == 4 && tile.height == 4)
    for y in 0..<4 {
      for x in 0..<4 {
        #expect(tile.pixels[y * 4 + x] == SIMD4(raw.pixel(x: x + 3, y: y + 2), 1))
      }
    }
    let frameID = UUID()
    let reference = try Pipeline.calibrate(
      image: raw, rect: region, matrix: .ledLightSource, sourceFrameID: frameID)
    let sampled = try await service.sample(
      url, rect: region, matrix: .ledLightSource, frameID: frameID)
    #expect(sampled.0 == reference)
    #expect(sampled.1.pixelCount == 16)
    #expect(try await service.pixel(url, x: 8, y: 3) == raw.pixel(x: 8, y: 3))
    let dimensions = try await service.preview(url)
    #expect(dimensions.1 == raw.width && dimensions.2 == raw.height)
  }

  @Test func tiffOrientationIsDecodedOnceBeforeUserTileTransform() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("orientation.tiff")
    try fixture(url, width: 9, height: 6)
    let stored = try Data(contentsOf: url)
    let base = try TIFFCodec.read(url: url)
    let service = ImageService()
    for tiffOrientation in 1...8 {
      var data = stored
      data.withUnsafeMutableBytes { bytes in
        let count = Int(UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: 8, as: UInt16.self)))
        for entry in 0..<count {
          let offset = 10 + entry * 12
          let tag = UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
          if tag == 274 {
            bytes.storeBytes(of: UInt16(tiffOrientation).littleEndian, toByteOffset: offset + 8, as: UInt16.self)
          }
        }
      }
      try data.write(to: url, options: .atomic)
      let sourceOrientation = try #require(FrameOrientation(rawValue: tiffOrientation))
      let expectedFull = try sourceOrientation.transform(base.preview(maxDimension: 9))
      let decoded = try TIFFCodec.read(url: url)
      #expect(decoded.preview(maxDimension: 9).pixels == expectedFull.pixels)
      let small = try await service.thumbnail(url, maxDimension: 4)
      #expect(small.pixels == decoded.preview(maxDimension: 4).pixels)
      let rect = PixelRect(x: 1, y: 1, width: 3, height: 4)
      let tile = try await service.region(url, rect: rect)
      for y in 0..<rect.height {
        for x in 0..<rect.width {
          #expect(tile.pixels[y * rect.width + x] == SIMD4(decoded.pixel(x: x + 1, y: y + 1), 1))
        }
      }
      // Appended 90° is applied to the already-normalized tile exactly once.
      let rotated = try FrameOrientation.rotate90CW.transform(tile)
      #expect(rotated.width == rect.height && rotated.height == rect.width)
      #expect(rotated.pixels[0] == tile.pixels[(tile.height - 1) * tile.width])
    }
  }

  @Test func memoryCacheIsBoundedLRUAndInvalidatesChangedSources() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let service = ImageService(cacheLimitBytes: 320, cacheLimitEntries: 2)
    let urls = (0..<3).map { folder.appendingPathComponent("frame\($0).tiff") }
    for url in urls { try fixture(url) }
    for url in urls { _ = try await service.thumbnail(url, maxDimension: 5) }
    var stats = await service.cacheStatistics()
    #expect(stats.entries == 2 && stats.bytes == 320 && stats.misses == 3)
    _ = try await service.thumbnail(urls[2], maxDimension: 5)
    stats = await service.cacheStatistics()
    #expect(stats.hits == 1)
    _ = try await service.thumbnail(urls[0], maxDimension: 5)
    #expect(await service.cacheStatistics().misses == 4)
    let original = try await service.thumbnail(urls[0], maxDimension: 5)
    let originalDate = try FileManager.default.attributesOfItem(atPath: urls[0].path)[.modificationDate]
    let replacement = folder.appendingPathComponent("replacement.tiff")
    try fixture(replacement, offset: 5000)
    _ = try FileManager.default.replaceItemAt(urls[0], withItemAt: replacement)
    if let originalDate { try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: urls[0].path) }
    let changed = try await service.thumbnail(urls[0], maxDimension: 5)
    #expect(changed.pixels != original.pixels)
    #expect(changed.pixels == (try TIFFCodec.read(url: urls[0])).preview(maxDimension: 5).pixels)
    await service.clear()
    #expect(await service.cacheStatistics().entries == 0)
  }

  @Test func cancelledImageRequestsDoNotReadOrCache() async throws {
    let service = ImageService()
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await service.thumbnail(URL(fileURLWithPath: "/missing-cancelled-input.tiff"))
    }
    do {
      _ = try await task.value
      Issue.record("Cancelled request unexpectedly succeeded")
    } catch is CancellationError {
      #expect(await service.cacheStatistics().entries == 0)
      #expect(await service.cacheStatistics().misses == 0)
    }
  }

  @Test func diskCachePreservesPixelsAndClearsOnlyOwnedFiles() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let directory = folder.appendingPathComponent(".printroom-cache", isDirectory: true)
    let cache = DiskThumbnailCache(directory: directory)
    let pixels = PixelBuffer(width: 2, height: 1, pixels: [SIMD4(0.2, 0.5, 0.9, 1), SIMD4(1, 0, 0.5, 1)])
    let image = try DisplayImage.make(pixels, profile: nil)
    let key = String(repeating: "a", count: 64)
    #expect(try await cache.image(for: key) == nil)
    try await cache.store(image, for: key)
    try await cache.store(image, for: key)
    let read = try #require(try await cache.image(for: key))
    #expect(read.width == 2 && read.height == 1 && read.bitsPerComponent == 16)
    #expect((read.colorSpace?.copyICCData() as Data?) == (image.colorSpace?.copyICCData() as Data?))
    let unrelated = directory.appendingPathComponent("original.tiff")
    let contents = Data([1, 2, 3, 4])
    try contents.write(to: unrelated)
    let symlink = directory.appendingPathComponent(String(repeating: "b", count: 64) + ".png")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: unrelated)
    let cleared = try await cache.clear()
    #expect(cleared.removedFiles == 1)
    #expect(try Data(contentsOf: unrelated) == contents)
    #expect(try symlink.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    #expect(try await cache.image(for: key) == nil)
  }

  @Test func diskCacheEnforcesSizeAndAgeLimits() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let directory = folder.appendingPathComponent(".printroom-cache", isDirectory: true)
    let cache = DiskThumbnailCache(directory: directory, maximumBytes: 1)
    let image = try DisplayImage.make(
      PixelBuffer(width: 1, height: 1, pixels: [SIMD4(0.5, 0.5, 0.5, 1)]), profile: nil)
    let key = String(repeating: "c", count: 64)
    try await cache.store(image, for: key)
    #expect(try await cache.maintain().remainingFiles == 0)
    let aged = DiskThumbnailCache(directory: directory, maximumAge: 30)
    try await aged.store(image, for: key)
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-60)],
      ofItemAtPath: directory.appendingPathComponent(key + ".png").path)
    #expect(try await aged.maintain().removedFiles == 1)
    let nonCache = DiskThumbnailCache(directory: folder)
    do {
      _ = try await nonCache.clear()
      Issue.record("Non-cache folder must never be cleared")
    } catch is PrintroomError {}
  }
}
