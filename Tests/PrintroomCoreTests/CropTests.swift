import CoreGraphics
import Foundation
import XCTest

@testable import PrintroomCore

final class CropTests: XCTestCase {
  private func ramp(width: Int, height: Int) -> PixelBuffer {
    PixelBuffer(width: width, height: height, pixels: (0..<(width * height)).map {
      SIMD4(Float($0 % width) / Float(width), Float($0 / width) / Float(height), 0.4, 1)
    })
  }

  func testFullImageKeepsEveryOriginalSampleForAllDirections() throws {
    let input = ramp(width: 12, height: 8)
    for orientation in FrameOrientation.allCases {
      let geometry = try CropGeometry(crop: nil, sourceWidth: 12, sourceHeight: 8,
                                      orientation: orientation)
      let output = try geometry.render(input)
      let original = try orientation.transform(input)
      XCTAssertEqual(output.width, original.width)
      XCTAssertEqual(output.height, original.height)
      XCTAssertEqual(output.pixels, original.pixels)
    }
  }

  func testZeroAngleUsesExactIntegerCropAndStrictSelectedRatio() throws {
    let input = ramp(width: 120, height: 80)
    let geometry = try CropGeometry(crop: FrameCrop(width: 0.5), sourceWidth: 120, sourceHeight: 80)
    XCTAssertEqual(geometry.rect, CGRect(x: 30, y: 20, width: 60, height: 40))
    let result = try geometry.render(input)
    XCTAssertEqual(result.width, 60)
    XCTAssertEqual(result.height, 40)
    for y in 0..<40 {
      for x in 0..<60 { XCTAssertEqual(result.pixels[y * 60 + x], input.pixels[(y + 20) * 120 + x + 30]) }
    }
    for aspect in CropAspectRatio.allCases {
      for portrait in [false, true] {
        let crop = FrameCrop(aspect: aspect, portrait: portrait, width: 0.63)
        let fit = try CropGeometry(crop: crop, sourceWidth: 120, sourceHeight: 80)
        XCTAssertEqual(Double(fit.outputWidth) / Double(fit.outputHeight), crop.ratio, accuracy: 1e-14)
        XCTAssertEqual(fit.rect.minX, fit.rect.minX.rounded())
        XCTAssertEqual(fit.rect.minY, fit.rect.minY.rounded())
      }
    }
  }

  func testAnalyticRotationAndLinearRampInterpolationBeforeDensity() throws {
    let input = ramp(width: 120, height: 80)
    let geometry = try CropGeometry(crop: FrameCrop(width: 0.5, angleDegrees: 10),
                                    sourceWidth: 120, sourceHeight: 80)
    XCTAssertEqual(geometry.outputWidth, 60)
    XCTAssertEqual(geometry.outputHeight, 40)
    let result = try geometry.render(input)
    // Analytic inverse rotation about (60,40), independent of production point mapping.
    let angle = 10.0 * Double.pi / 180
    let x = 15, y = 11
    let dx = Double(x) + 0.5 - 30, dy = Double(y) + 0.5 - 20
    let sx = cos(angle) * dx + sin(angle) * dy + 60 - 0.5
    let sy = -sin(angle) * dx + cos(angle) * dy + 40 - 0.5
    XCTAssertEqual(Double(result.pixels[y * 60 + x].x), sx / 120, accuracy: 1e-7)
    XCTAssertEqual(Double(result.pixels[y * 60 + x].y), sy / 80, accuracy: 1e-7)
    XCTAssertEqual(result.pixels[y * 60 + x].z, 0.4)
    let expectedSource = SIMD2(sx + 0.5, sy + 0.5)
    let point = geometry.sourcePoint(outputX: Double(x) + 0.5, outputY: Double(y) + 0.5)
    XCTAssertEqual(point.x, expectedSource.x, accuracy: 1e-12)
    XCTAssertEqual(point.y, expectedSource.y, accuracy: 1e-12)
  }

  func testAllCropCornersStayInsideSourceAndPointsRoundTrip() throws {
    for orientation in FrameOrientation.allCases {
      for aspect in CropAspectRatio.allCases {
        for angle in [-10.0, -0.01, 0, 0.01, 10] {
          for center in [SIMD2(0.0, 0.0), SIMD2(0.5, 0.5), SIMD2(1.0, 1.0)] {
            let crop = FrameCrop(aspect: aspect, centerX: center.x, centerY: center.y,
                                 width: 1, angleDegrees: angle)
            let geometry = try CropGeometry(crop: crop, sourceWidth: 120, sourceHeight: 80,
                                            orientation: orientation)
            for x in [0.0, Double(geometry.outputWidth)] {
              for y in [0.0, Double(geometry.outputHeight)] {
                let p = geometry.sourcePoint(outputX: x, outputY: y)
                XCTAssertGreaterThanOrEqual(p.x, -1e-10)
                XCTAssertGreaterThanOrEqual(p.y, -1e-10)
                XCTAssertLessThanOrEqual(p.x, 120 + 1e-10)
                XCTAssertLessThanOrEqual(p.y, 80 + 1e-10)
                let q = geometry.outputPoint(sourceX: p.x, sourceY: p.y)
                XCTAssertEqual(q.x, x, accuracy: 1e-10)
                XCTAssertEqual(q.y, y, accuracy: 1e-10)
              }
            }
            var moved = geometry.crop!
            moved.centerX = 1
            moved.centerY = 0
            let translated = try moved.constrained(sourceWidth: 120, sourceHeight: 80, orientation: orientation)
            XCTAssertEqual(translated.width, geometry.crop!.width, accuracy: 1e-12)
          }
        }
      }
    }
  }

  func testCropFollowsEveryDirectionChangeIncludingResetAndReflections() throws {
    let source = ramp(width: 120, height: 80)
    for old in FrameOrientation.allCases {
      for operation in OrientationOperation.allCases {
        let crop = try FrameCrop(centerX: 0.43, centerY: 0.57, width: 0.35, angleDegrees: 5.37)
          .constrained(sourceWidth: 120, sourceHeight: 80, orientation: old)
        let original = try CropGeometry(crop: crop, sourceWidth: 120, sourceHeight: 80,
                                        orientation: old).render(source)
        let new = old.applying(operation)
        let next = try crop.transformed(from: old, to: new, sourceWidth: 120, sourceHeight: 80)
        XCTAssertEqual(next, crop, "Direction edits never mutate a source-coordinate crop")
        let actual = try CropGeometry(crop: next, sourceWidth: 120, sourceHeight: 80,
                                      orientation: new).render(source)
        // Reset's relative transform is inverse(old); other operations are appended.
        let inverse: FrameOrientation = old == .rotate90CW ? .rotate90CCW : old == .rotate90CCW ? .rotate90CW : old
        let relative = operation == .reset ? inverse : FrameOrientation.identity.applying(operation)
        let expected = try relative.transform(original)
        XCTAssertEqual(actual.width, expected.width)
        XCTAssertEqual(actual.height, expected.height)
        for index in actual.pixels.indices {
          for c in 0..<4 { XCTAssertEqual(actual.pixels[index][c], expected.pixels[index][c], accuracy: 2e-7) }
        }
      }
    }
  }

  func testSameSourceCropUnderAllDirectionsEqualsCroppingOriginalThenD4() throws {
    let width = 120, height = 80
    let pixels: [SIMD4<Float>] = (0..<(width * height)).map { index in
      let red = Float((index * 71 + 103) % 65535) / 65535
      let green = Float((index * 311 + 1703) % 65535) / 65535
      let blue = Float((index * 37 + 3307) % 65535) / 65535
      return SIMD4<Float>(red, green, blue, 1)
    }
    let source = PixelBuffer(width: width, height: height, pixels: pixels)
    for angle in [-10.0, -3.17, -0.01, 0, 0.01, 3.17, 10] {
      let crop = FrameCrop(aspect: .sevenSix, centerX: 0.27, centerY: 0.61,
                           width: 0.35, angleDegrees: angle)
      XCTAssertEqual(crop.geometryVersion, 2)
      let original = try CropGeometry(crop: crop, sourceWidth: width, sourceHeight: height)
      let croppedOriginal = try original.render(source)
      if angle == 0 {
        XCTAssertEqual(original.rect, CGRect(x: 11, y: 31, width: 42, height: 36))
        XCTAssertEqual(croppedOriginal.pixels[0], source.pixels[31 * width + 11])
      }
      for orientation in FrameOrientation.allCases {
        let geometry = try CropGeometry(crop: crop, sourceWidth: width, sourceHeight: height,
                                         orientation: orientation)
        XCTAssertEqual(geometry.crop, original.crop)
        let actual = try geometry.render(source)
        let expected = try orientation.transform(croppedOriginal)
        XCTAssertEqual(actual.width, expected.width)
        XCTAssertEqual(actual.height, expected.height)
        if angle == 0 { XCTAssertEqual(actual.pixels, expected.pixels) }
        else {
          for index in actual.pixels.indices {
            for channel in 0..<3 {
              XCTAssertEqual(actual.pixels[index][channel], expected.pixels[index][channel],
                             accuracy: 2e-7, "\(orientation) \(angle) sample \(index)")
            }
          }
        }
        // Independently reorder output coordinates, then require the same source
        // location. Neither frame's orientation can change the selected original.
        for p in [SIMD2(0, 0), SIMD2(actual.width / 2, actual.height / 2),
                  SIMD2(actual.width - 1, actual.height - 1)] {
          let unrotated = orientation.inversePixel(x: p.x, y: p.y,
            sourceWidth: original.outputWidth, sourceHeight: original.outputHeight)
          let a = geometry.sourcePoint(outputX: Double(p.x) + 0.5, outputY: Double(p.y) + 0.5)
          let b = original.sourcePoint(outputX: Double(unrotated.x) + 0.5,
                                        outputY: Double(unrotated.y) + 0.5)
          XCTAssertEqual(a.x, b.x, accuracy: 1e-10)
          XCTAssertEqual(a.y, b.y, accuracy: 1e-10)
        }
      }
    }
  }

  func testLegacyDisplayCropMigrationPreservesAppearanceForEveryDirection() throws {
    let source = ramp(width: 121, height: 83)
    for orientation in FrameOrientation.allCases {
      for angle in [-9.73, 0, 4.21] {
        let old = FrameCrop(aspect: .fourThree, portrait: true, centerX: 0.32, centerY: 0.7,
                             width: 0.47, angleDegrees: angle, geometryVersion: 1)
        let before = try CropGeometry(crop: old, sourceWidth: 121, sourceHeight: 83,
                                      orientation: orientation).render(source)
        let migrated = try old.sourceCoordinates(sourceWidth: 121, sourceHeight: 83,
                                                   orientation: orientation)
        XCTAssertEqual(migrated.geometryVersion, 2)
        let after = try CropGeometry(crop: migrated, sourceWidth: 121, sourceHeight: 83,
                                     orientation: orientation).render(source)
        XCTAssertEqual(after.width, before.width)
        XCTAssertEqual(after.height, before.height)
        if angle == 0 { XCTAssertEqual(after.pixels, before.pixels) }
        else {
          for index in before.pixels.indices {
            for channel in 0..<3 {
              XCTAssertEqual(after.pixels[index][channel], before.pixels[index][channel], accuracy: 2e-7)
            }
          }
        }
      }
    }
  }

  func testDisplayedDraftConversionPreservesSourceAndReflectsAngleAndAspect() throws {
    let source = try FrameCrop(aspect: .sevenSix, centerX: 0.31, centerY: 0.66,
                               width: 0.35, angleDegrees: 5.27)
      .constrained(sourceWidth: 1400, sourceHeight: 1200)
    for orientation in FrameOrientation.allCases {
      let display = try source.displayCoordinates(sourceWidth: 1400, sourceHeight: 1200,
                                                    orientation: orientation)
      XCTAssertEqual(display.geometryVersion, 1)
      XCTAssertEqual(display.portrait, orientation.swapsAxes)
      let reflected = [FrameOrientation.flipHorizontal, .flipVertical, .transpose, .transverse]
        .contains(orientation)
      XCTAssertEqual(display.angleDegrees, reflected ? -5.27 : 5.27)
      let restored = try display.sourceCoordinates(sourceWidth: 1400, sourceHeight: 1200,
                                                      orientation: orientation)
      XCTAssertEqual(restored.geometryVersion, 2)
      XCTAssertEqual(restored.aspect, source.aspect)
      XCTAssertEqual(restored.portrait, source.portrait)
      XCTAssertEqual(restored.angleDegrees, source.angleDegrees)
      XCTAssertEqual(restored.centerX, source.centerX, accuracy: 1e-12)
      XCTAssertEqual(restored.centerY, source.centerY, accuracy: 1e-12)
      XCTAssertEqual(restored.width, source.width, accuracy: 1e-12)
    }
  }

  func testSourceCropSynchronizesAcrossDimensionsIndependentlyOfDestinationDirection() throws {
    let original = try FrameCrop(aspect: .sevenSix, portrait: true, centerX: 0.3, centerY: 0.68,
                                 width: 0.32, angleDegrees: -4.37)
      .constrained(sourceWidth: 1400, sourceHeight: 1200)
    for size in [(1400, 1200), (2800, 2400), (900, 1600)] {
      let expected = try original.constrained(sourceWidth: size.0, sourceHeight: size.1)
      for orientation in FrameOrientation.allCases {
        let applied = try original.constrained(sourceWidth: size.0, sourceHeight: size.1,
                                                orientation: orientation)
        XCTAssertEqual(applied, expected)
        XCTAssertEqual(applied.angleDegrees, original.angleDegrees)
        XCTAssertEqual(applied.aspect, original.aspect)
        XCTAssertEqual(applied.portrait, original.portrait)
      }
    }
  }

  func testNativeROIContainsInterpolationSupportAndMatchesWholeRender() throws {
    let source = ramp(width: 120, height: 80)
    for orientation in FrameOrientation.allCases {
      let geometry = try CropGeometry(crop: FrameCrop(width: 0.8, angleDegrees: -9.87),
                                      sourceWidth: 120, sourceHeight: 80, orientation: orientation)
      let full = try geometry.render(source)
      let region = PixelRect(x: 3, y: 5, width: geometry.outputWidth - 8, height: 7)
      let needed = try geometry.sourceRegion(for: region)
      var pixels: [SIMD4<Float>] = []
      for y in needed.y..<(needed.y + needed.height) {
        pixels += source.pixels[(y * 120 + needed.x)..<(y * 120 + needed.x + needed.width)]
      }
      let roi = PixelBuffer(width: needed.width, height: needed.height, pixels: pixels)
      let partial = try geometry.render(roi, sourceRegion: needed, outputRegion: region)
      XCTAssertEqual(partial.width, region.width)
      XCTAssertEqual(partial.height, region.height)
      for y in 0..<partial.height {
        for x in 0..<partial.width {
          let expected = full.pixels[(y + region.y) * full.width + x + region.x]
          for c in 0..<4 { XCTAssertEqual(partial.pixels[y * partial.width + x][c], expected[c], accuracy: 1e-7) }
        }
      }
    }
  }

  func testIntegerNativeROIIsExactWithoutUnusedBorderPixels() throws {
    for orientation in FrameOrientation.allCases {
      let region = PixelRect(x: 100, y: 100, width: 4096, height: 2048)
      let full = try CropGeometry(crop: nil, sourceWidth: 7008, sourceHeight: 4672,
                                  orientation: orientation)
      let expected = try orientation.inverseRect(region, sourceWidth: 7008, sourceHeight: 4672)
      let actual = try full.sourceRegion(for: region)
      XCTAssertEqual(actual, expected)
      XCTAssertEqual(actual.width * actual.height, 8_388_608)

      let cropped = try CropGeometry(crop: FrameCrop(aspect: .square, width: 0.5),
                                     sourceWidth: 7008, sourceHeight: 4672, orientation: orientation)
      let tile = PixelRect(x: 3, y: 5, width: 211, height: 173)
      let shifted = PixelRect(x: tile.x + Int(cropped.rect.minX),
                              y: tile.y + Int(cropped.rect.minY), width: tile.width, height: tile.height)
      XCTAssertEqual(try cropped.sourceRegion(for: tile),
                     try orientation.inverseRect(shifted, sourceWidth: 7008, sourceHeight: 4672))
      XCTAssertEqual(try cropped.sourceRegion(for: tile).width * cropped.sourceRegion(for: tile).height,
                     tile.width * tile.height)
    }
  }

  func testFineRotationAtExactPixelCenterReadsOnlyItsRequiredSample() throws {
    // Odd output dimensions put the middle sample exactly at the source center,
    // even under a nonzero fine rotation. It requires a 1x1 source ROI.
    let geometry = try CropGeometry(crop: FrameCrop(aspect: .square, width: 0.5, angleDegrees: 7.31),
                                    sourceWidth: 121, sourceHeight: 81)
    // A width of 59 is odd, ensuring both full source and crop have center pixels.
    var crop = geometry.crop!
    crop.width = 59.0 / 121
    let odd = try CropGeometry(crop: crop, sourceWidth: 121, sourceHeight: 81)
    XCTAssertEqual(odd.outputWidth, 59)
    let center = PixelRect(x: 29, y: 29, width: 1, height: 1)
    XCTAssertEqual(try odd.sourceRegion(for: center), PixelRect(x: 60, y: 40, width: 1, height: 1))
    let input = PixelBuffer(width: 1, height: 1, pixels: [SIMD4(0.2, 0.4, 0.6, 1)])
    let rendered = try odd.render(input, sourceRegion: odd.sourceRegion(for: center), outputRegion: center)
    XCTAssertEqual(rendered.pixels, input.pixels)
  }

  func testNormalizedCropRefitsAcrossDifferentSourceSizes() throws {
    let crop = try FrameCrop(aspect: .sevenSix, centerX: 0.6, centerY: 0.4,
                             width: 0.35, angleDegrees: 4.25)
      .constrained(sourceWidth: 1400, sourceHeight: 1200)
    let twice = try crop.constrained(sourceWidth: 2800, sourceHeight: 2400)
    XCTAssertEqual(crop, twice)
    let different = try CropGeometry(crop: crop, sourceWidth: 900, sourceHeight: 1600)
    XCTAssertEqual(Double(different.outputWidth) / Double(different.outputHeight), 7.0 / 6)
    XCTAssertEqual(different.crop!.angleDegrees, 4.25)
  }

  func testSchemaTwoPreservesOldAppearanceAndBacksUpBeforeSchemaThreeSave() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("printroom-crop-migration-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    var project = RollProject()
    project.frames = [FrameRecord(filename: "missing.tif", isMissing: true, orientation: .rotate90CW)]
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as! [String: Any]
    json["schemaVersion"] = 2
    var frames = json["frames"] as! [[String: Any]]
    frames[0].removeValue(forKey: "crop")
    json["frames"] = frames
    let bytes = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    let settings = folder.appendingPathComponent(ProjectStore.filename)
    try bytes.write(to: settings)
    let migrated = try ProjectStore.open(folder: folder)
    XCTAssertEqual(migrated.frames, project.frames)
    XCTAssertNil(migrated.frames[0].crop)
    XCTAssertEqual(migrated.algorithmVersion, "printroom-density-v2")
    XCTAssertEqual(migrated.schemaVersion, 3)
    XCTAssertEqual(try Data(contentsOf: settings), bytes)
    XCTAssertThrowsError(try ProjectStore.save(migrated, folder: folder, expectedModification: nil))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [ProjectStore.filename])
    let date = try ProjectStore.save(migrated, folder: folder, expectedModification: migrated.loadedModificationDate)
    let backups = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
      .filter { $0.lastPathComponent.hasPrefix(".printroom-schema2-") }
    XCTAssertEqual(backups.count, 1)
    XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), bytes)
    try ProjectStore.save(migrated, folder: folder, expectedModification: date)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 2)
  }

  func testCropPersistenceRequiredNullAndCorruptionRejection() throws {
    var project = RollProject()
    project.frames = [FrameRecord(filename: "a.tif"), FrameRecord(filename: "b.tif", crop:
      FrameCrop(aspect: .sevenSix, portrait: true, centerX: 0.4, width: 0.5, angleDegrees: -5.23))]
    let encoded = try JSONEncoder().encode(project)
    XCTAssertEqual(try ProjectStore.decodeSnapshot(encoded).frames, project.frames)
    let original = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    let frames = original["frames"] as! [[String: Any]]
    XCTAssertTrue(frames[0]["crop"] is NSNull)
    for field in ["crop", "angleDegrees", "geometryVersion", "aspect"] {
      var bad = original
      var mutatedFrames = frames
      if field == "crop" { mutatedFrames[0].removeValue(forKey: "crop") }
      else {
        var crop = mutatedFrames[1]["crop"] as! [String: Any]
        crop.removeValue(forKey: field)
        mutatedFrames[1]["crop"] = crop
      }
      bad["frames"] = mutatedFrames
      XCTAssertThrowsError(try ProjectStore.decodeSnapshot(JSONSerialization.data(withJSONObject: bad)))
    }
    for invalid in [FrameCrop(angleDegrees: 10.01), FrameCrop(width: 0), FrameCrop(geometryVersion: 3)] {
      project.frames[0].crop = invalid
      XCTAssertThrowsError(try ProjectStore.decodeSnapshot(JSONEncoder().encode(project)))
    }
    let applied = try ParameterSnapshot(frame: project.frames[1]).applying(
      to: ProjectStore.decodeSnapshot(encoded), targets: Set(project.frames.map(\.id)))
    XCTAssertEqual(applied.frames.map(\.crop), [nil, project.frames[1].crop])
  }
}
