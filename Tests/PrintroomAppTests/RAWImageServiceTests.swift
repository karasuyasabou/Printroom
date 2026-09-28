import Foundation
import PrintroomCore
import Testing
@testable import PrintroomApp

@Suite(.serialized)
struct RAWImageServiceTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["PRINTROOM_VALIDATE_RAW"] == "1"))
  func realAdobeProxySamplingAndGeometry() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let source = root.appendingPathComponent("TEST/RAW/DSC07119.ARW")
    let reference = root.appendingPathComponent("scratch/raw-adobe-study/reference/DSC07119.ARW.tiff")
    let service = ImageService()
    let expected = try TIFFCodec.readPreview(url: reference, maxDimension: 1600)
    let preview = try await service.preview(source)
    #expect(preview.0.pixels == expected.preview(maxDimension: 1600).pixels)
    #expect(preview.1 == 7008 && preview.2 == 4672)
    let roi = PixelRect(x: 2711, y: 1953, width: 11, height: 11)
    func proxyRegion(_ rect: PixelRect) -> LinearImage {
      var values = [UInt16]()
      for y in rect.y..<(rect.y + rect.height) {
        for x in rect.x..<(rect.x + rect.width) {
          let offset = ((y * expected.height / 4672) * expected.width + x * expected.width / 7008) * 3
          values.append(contentsOf: expected.samples[offset..<(offset + 3)])
        }
      }
      return LinearImage(width: rect.width, height: rect.height, samples: values)
    }
    let referenceROI = proxyRegion(roi)
    let actual = try await service.region(source, rect: roi)
    #expect(actual.pixels == referenceROI.preview(maxDimension: 11).pixels)
    let frameID = UUID()
    let sampled = try await service.sample(source, rect: roi, matrix: .identity, frameID: frameID)
    let expectedCalibration = try Pipeline.calibrate(image: referenceROI,
      rect: PixelRect(x: 0, y: 0, width: 11, height: 11), matrix: .identity, sourceFrameID: frameID)
    #expect(sampled.gainRGB == expectedCalibration.gainRGB)
    #expect(sampled.filmBaseOffsetCV == expectedCalibration.filmBaseOffsetCV)
    #expect(sampled.sourceWidth == 7008 && sampled.sourceHeight == 4672)
    for value in 1...8 {
      let orientation = try #require(FrameOrientation(rawValue: value))
      let geometry = try CropGeometry(crop: nil, sourceWidth: 7008, sourceHeight: 4672, orientation: orientation)
      let tile = PixelRect(x: 1300, y: 900, width: 21, height: 13)
      let rawTile = try await service.transformedRegion(source, geometry: geometry, rect: tile)
      let sourceRect = try geometry.sourceRegion(for: tile)
      let input = proxyRegion(sourceRect).preview(maxDimension: max(sourceRect.width, sourceRect.height))
      let tiffTile = try geometry.render(input, sourceRegion: sourceRect, outputRegion: tile,
        maxDimension: max(tile.width, tile.height))
      #expect(rawTile.pixels == tiffTile.pixels)
    }
  }
}
