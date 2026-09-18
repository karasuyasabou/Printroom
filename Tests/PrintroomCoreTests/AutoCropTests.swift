import Foundation
import XCTest
@testable import PrintroomCore

final class AutoCropTests: XCTestCase {
  func testInternalEdgeCannotAnchorAnOutOfSourceRectangle() throws {
    let w = 800, h = 533
    var samples = [UInt16](repeating: 0, count: w * h * 3)
    for y in 0..<h { for x in 0..<w {
      var density = 2.3
      if x >= 50 && x < 764 && y >= 30 && y < 504 {
        density = (128..<220).contains(x) ? 2.9 : 2.35
      }
      let value = UInt16((65535 * exp(-density)).rounded())
      let i = (y * w + x) * 3
      samples[i] = value; samples[i + 1] = value; samples[i + 2] = value
    } }
    let analysis = try AutoCropAnalyzer.prepare(LinearImage(width: w, height: h, samples: samples))
    let template = AutoCropTemplate(width: 714, height: 474, analysisWidth: w, analysisHeight: h, seedCount: 1)
    let fit = try AutoCropAnalyzer.fit(analysis, template: template, sourceWidth: w, sourceHeight: h)
    // Anchoring the strong internal x=128 line would place the far side beyond
    // x=800. It must not win and then be clamped into a different rectangle.
    XCTAssertEqual(fit.crop.centerX * 800, 407, accuracy: 2)
    XCTAssertEqual(fit.crop.centerY * 533, 267, accuracy: 2)
  }

  func testRollSizeRejectsStrongerFixtureStripes() throws {
    // True exposure aperture: 675 x 500. Bright/dark stripes outside the film
    // create stronger local gradients, but have neither a stable outside band
    // nor the same outside density as the film base on the other sides.
    var seeds = [AutoCropSeed]()
    var analyses = [AutoCropAnalysis]()
    for frame in 0..<7 {
      let w = 800, h = 533, shift = Double(frame % 3 - 1)
      var samples = [UInt16](repeating: 0, count: w * h * 3)
      for y in 0..<h { for x in 0..<w {
        let u = Double(x) - shift, v = Double(y)
        var density = 2.3
        if u >= 60 && u < 735 && v >= 16 && v < 516 {
          density = frame < 5 || u < 400 ? 2.7 + 0.15 * sin(Double(y) / 35) : 2.31
        }
        if x < 28 { density = x < 22 ? 1 : 4 }
        if x > 760 { density = x < 771 ? 4 : (x < 775 ? 0.5 : 6) }
        // Per-frame scanner exposure changes absolute density, not aperture size.
        let value = UInt16((65535 * exp(-density - Double(frame) * 0.1)).rounded())
        let i = (y * w + x) * 3
        samples[i] = value; samples[i + 1] = value; samples[i + 2] = value
      } }
      let image = LinearImage(width: w, height: h, samples: samples)
      let analysis = try AutoCropAnalyzer.prepare(image)
      XCTAssertGreaterThan(analysis.seedEdges[1], 760, "Fixture must actually fool the original strongest-edge seed")
      seeds.append(analysis.seed)
      analyses.append(analysis)
      let reloaded = try AutoCropAnalyzer.prepare(image, seed: analysis.seed)
      let once = try AutoCropAnalyzer.template(fromSeeds: [analysis.seed])
      let twice = try AutoCropAnalyzer.template(fromSeeds: [reloaded.seed])
      XCTAssertEqual(once.width, twice.width)
      XCTAssertEqual(once.height, twice.height)
    }
    let template = try AutoCropAnalyzer.template(fromSeeds: seeds)
    XCTAssertEqual(template.width, 675, accuracy: 1.5)
    XCTAssertEqual(template.height, 500, accuracy: 1.5)
    for (frame, analysis) in analyses.enumerated() {
      let fit = try AutoCropAnalyzer.fit(analysis, template: template, sourceWidth: 800, sourceHeight: 533)
      XCTAssertEqual(fit.crop.centerX * 800, 397.5 + Double(frame % 3 - 1), accuracy: 1.5)
      XCTAssertEqual(fit.crop.centerY * 533, 266, accuracy: 1.5)
      XCTAssertEqual(fit.crop.angleDegrees, 0, accuracy: 0.15)
    }
    let reversed = try AutoCropAnalyzer.template(fromSeeds: seeds.reversed())
    XCTAssertEqual(template.width, reversed.width)
    XCTAssertEqual(template.height, reversed.height)
  }

  /// Cached proxies only; user projects and source photos are never opened for writing.
  func testFilmBaseOuterEdgeRollSize() throws {
    guard let root = ProcessInfo.processInfo.environment["PRINTROOM_AUTOCROP_SIZE_STUDY"] else {
      throw XCTSkip("Set PRINTROOM_AUTOCROP_SIZE_STUDY to a scratch folder containing the 15-frame inputs.json")
    }
    struct Input: Decodable { let name: String; let proxy: String; let width: Int; let height: Int }
    let folder = URL(fileURLWithPath: root)
    let inputs = try JSONDecoder().decode([Input].self, from: Data(contentsOf: folder.appendingPathComponent("inputs.json")))
    XCTAssertEqual(inputs.count, 15)
    var seeds = [AutoCropSeed]()
    for input in inputs {
      seeds.append(try AutoCropAnalyzer.prepare(TIFFCodec.read(url: URL(fileURLWithPath: input.proxy))).seed)
    }
    let template = try AutoCropAnalyzer.template(fromSeeds: seeds)
    // Independent visual boundary measurements at width 800: left ≈60, right
    // ≈735, height ≈515. The old mixed fixture/film template was 701.5 wide.
    XCTAssertEqual(template.width, 675, accuracy: 2)
    XCTAssertEqual(template.height, 515, accuracy: 2)
    var rows = [[String: Any]]()
    for (i, input) in inputs.enumerated() {
      let analysis = try AutoCropAnalyzer.prepare(TIFFCodec.read(url: URL(fileURLWithPath: input.proxy)), seed: seeds[i])
      let fit = try AutoCropAnalyzer.fit(analysis, template: template, sourceWidth: input.width,
        sourceHeight: input.height, requiresAllEdges: i == 0 || i == inputs.count - 1)
      if [7, 8, 10].contains(i) {
        // The visible inner edges are around x=62 and x=737 on this grid.
        // A fixture-anchored fit had center x≈433; it must now use the aperture.
        XCTAssertEqual(fit.crop.centerX * 800, 399.5, accuracy: 2)
        XCTAssertEqual(fit.crop.angleDegrees, 0.2, accuracy: 0.3)
      }
      rows.append(["name": input.name, "crop": try JSONSerialization.jsonObject(with: JSONEncoder().encode(fit.crop)),
                   "needsReview": fit.needsReview, "evidence": fit.evidence])
    }
    let report: [String: Any] = ["version": AutoCropAnalyzer.version, "width": template.width,
      "height": template.height, "seeds": template.seedCount, "frames": rows]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      .write(to: folder.appendingPathComponent("native-v3.json"))
  }

  func testRotatedSyntheticFrameAndCorrectionSign() throws {
    let w = 800, h = 533, angle = 1.3 * Double.pi / 180
    var samples = [UInt16](repeating: 0, count: w * h * 3)
    for y in 0..<h { for x in 0..<w {
      let dx = Double(x) - 400, dy = Double(y) - 266.5
      let u = cos(angle) * dx + sin(angle) * dy
      let v = -sin(angle) * dx + cos(angle) * dy
      let inside = abs(u - 3) < 355 && abs(v + 2) < 239
      for c in 0..<3 { samples[(y * w + x) * 3 + c] = inside ? 6500 : 44000 }
    } }
    let analysis = try AutoCropAnalyzer.prepare(LinearImage(width: w, height: h, samples: samples))
    let template = try AutoCropAnalyzer.template(fromSeeds: [analysis.seed])
    let result = try AutoCropAnalyzer.fit(analysis, template: template, sourceWidth: w, sourceHeight: h)
    XCTAssertFalse(result.needsReview)
    XCTAssertEqual(template.width, 710, accuracy: 2)
    XCTAssertEqual(template.height, 478, accuracy: 2)
    XCTAssertEqual(result.crop.angleDegrees, -1.3, accuracy: 0.12)
    XCTAssertEqual(result.crop.centerX * 800, 403, accuracy: 1.5)
    XCTAssertEqual(result.crop.centerY * 533, 264.5, accuracy: 1.5)
    XCTAssertEqual(result.crop.aspect, .free)
    let geometry = try CropGeometry(crop: result.crop, sourceWidth: w, sourceHeight: h)
    let tl = geometry.sourcePoint(outputX: 0, outputY: 0)
    let tr = geometry.sourcePoint(outputX: Double(geometry.outputWidth), outputY: 0)
    XCTAssertGreaterThan(tr.y, tl.y, "Detected clockwise tilt must map to negative correction angle")
    let reload = try AutoCropAnalyzer.prepare(LinearImage(width: w, height: h, samples: samples), seed: analysis.seed)
    let refit = try AutoCropAnalyzer.fit(reload, template: template, sourceWidth: w, sourceHeight: h)
    XCTAssertEqual(result.crop, refit.crop)
  }

  func testFlatImageRemainsReviewable() throws {
    let analysis = try AutoCropAnalyzer.prepare(LinearImage(width: 800, height: 533,
      samples: [UInt16](repeating: 30000, count: 800 * 533 * 3)))
    let result = try AutoCropAnalyzer.fit(analysis, template: AutoCropAnalyzer.template(from: [analysis]),
      sourceWidth: 800, sourceHeight: 533)
    XCTAssertTrue(result.needsReview)
    XCTAssertLessThan(result.evidence.max()!, 0.00001)
  }

  func testRollEndpointsRequireEvidenceOnAllFourEdges() throws {
    func frame(hasLeftEdge: Bool) -> LinearImage {
      let w = 800, h = 533
      var samples = [UInt16](repeating: 0, count: w * h * 3)
      for y in 0..<h { for x in 0..<w {
        let inside = y >= 28 && y < 506 && x < 755 && (!hasLeftEdge || x >= 45)
        let value: UInt16 = inside ? 6500 : 44000
        let i = (y * w + x) * 3
        samples[i] = value; samples[i + 1] = value; samples[i + 2] = value
      } }
      return LinearImage(width: w, height: h, samples: samples)
    }
    let complete = try AutoCropAnalyzer.prepare(frame(hasLeftEdge: true))
    let template = try AutoCropAnalyzer.template(fromSeeds: [complete.seed])
    let missingLeft = try AutoCropAnalyzer.prepare(frame(hasLeftEdge: false))
    let normal = try AutoCropAnalyzer.fit(missingLeft, template: template,
      sourceWidth: 800, sourceHeight: 533)
    let endpoint = try AutoCropAnalyzer.fit(missingLeft, template: template,
      sourceWidth: 800, sourceHeight: 533, requiresAllEdges: true)
    XCTAssertFalse(normal.needsReview, "A middle frame may still pass with three strong edges")
    XCTAssertTrue(endpoint.needsReview, "A roll endpoint must identify all four edges")
    XCTAssertEqual(normal.crop, endpoint.crop, "The stricter endpoint rule only changes review status")
    XCTAssertLessThan(endpoint.evidence[0], 0.22)
  }

  /// Explicit opt-in uses only immutable existing proxy samples; writes measurements into scratch.
  func testAcceptedRollExperimentParity() throws {
    guard let root = ProcessInfo.processInfo.environment["PRINTROOM_AUTOCROP_STUDY"] else {
      throw XCTSkip("Set PRINTROOM_AUTOCROP_STUDY to scratch/autocrop-study for the 76-frame regression")
    }
    struct Input: Decodable { let name: String; let proxy: String; let width: Int; let height: Int }
    struct Report: Decodable {
      struct Template: Decodable { let width: Double; let height: Double }
      struct Frame: Decodable { let name: String; let center: [Double]; let theta: Double; let status: String }
      let template: Template; let frames: [Frame]
    }
    var measurements = [[String: Any]]()
    for folder in [root, root + "/roll-2"] {
      let inputs = try JSONDecoder().decode([Input].self, from: Data(contentsOf: URL(fileURLWithPath: folder + "/inputs.json")))
      let reference = try JSONDecoder().decode(Report.self, from: Data(contentsOf: URL(fileURLWithPath: folder + "/results.json")))
      var seeds = [AutoCropSeed]()
      let start = Date()
      for input in inputs {
        seeds.append(try AutoCropAnalyzer.prepare(TIFFCodec.read(url: URL(fileURLWithPath: input.proxy))).seed)
      }
      let template = try AutoCropAnalyzer.template(fromSeeds: seeds)
      XCTAssertEqual(template.width, reference.template.width, accuracy: 1)
      XCTAssertEqual(template.height, reference.template.height, accuracy: 1)
      var passed = 0, statusChanges = 0, maxPosition = 0.0, maxAngle = 0.0
      for (i, input) in inputs.enumerated() {
        let analysis = try AutoCropAnalyzer.prepare(TIFFCodec.read(url: URL(fileURLWithPath: input.proxy)), seed: seeds[i])
        let fit = try AutoCropAnalyzer.fit(analysis, template: template, sourceWidth: input.width, sourceHeight: input.height)
        let expected = reference.frames[i]
        XCTAssertEqual(expected.name, input.name)
        let positionError = max(abs(fit.crop.centerX * 800 - expected.center[0]), abs(fit.crop.centerY * 533 - expected.center[1]))
        let angleError = abs(fit.crop.angleDegrees + expected.theta)
        maxPosition = max(maxPosition, positionError); maxAngle = max(maxAngle, angleError)
        if !fit.needsReview { passed += 1 }
        if fit.needsReview != (expected.status != "auto") { statusChanges += 1 }
        measurements.append(["name":input.name,"centerErrorAnalysisPixels":positionError,"angleErrorDegrees":angleError,
          "needsReview":fit.needsReview,"referenceStatus":expected.status,
          "crop": try JSONSerialization.jsonObject(with: JSONEncoder().encode(fit.crop))])
        // The old experiment was not ground truth for these two ambiguous
        // frames (weak top edge / light-leaked first frame). V3 was visually
        // checked against the aperture; keep an independent coarse envelope
        // and mandatory review instead of freezing the old displaced center.
        let reviewedCenters: [String: SIMD2<Double>] = [
          "DSC07099.ARW": SIMD2(407, 266), "DSC07115.ARW": SIMD2(406, 271)
        ]
        if let center = reviewedCenters[input.name] {
          XCTAssertEqual(fit.crop.centerX * 800, center.x, accuracy: 3, input.name)
          XCTAssertEqual(fit.crop.centerY * 533, center.y, accuracy: 3, input.name)
          XCTAssertTrue(fit.needsReview, input.name)
        } else {
          XCTAssertLessThan(positionError, 4, input.name)
        }
        XCTAssertLessThan(angleError, 0.25, input.name)
      }
      print("AUTOCROP PARITY \(folder): \(passed)/\(inputs.count) auto; changed statuses \(statusChanges); max center error \(maxPosition), angle \(maxAngle); seconds \(Date().timeIntervalSince(start))")
      XCTAssertLessThanOrEqual(statusChanges, 2)
    }
    try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys]).write(
      to: URL(fileURLWithPath: root + "/native-parity.json"))
  }
}
