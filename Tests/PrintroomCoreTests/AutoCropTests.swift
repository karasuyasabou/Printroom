import Foundation
import XCTest
@testable import PrintroomCore

final class AutoCropTests: XCTestCase {
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
          "needsReview":fit.needsReview,"referenceStatus":expected.status])
        XCTAssertLessThan(positionError, 4, input.name)
        XCTAssertLessThan(angleError, 0.25, input.name)
      }
      print("AUTOCROP PARITY \(folder): \(passed)/\(inputs.count) auto; changed statuses \(statusChanges); max center error \(maxPosition), angle \(maxAngle); seconds \(Date().timeIntervalSince(start))")
      XCTAssertLessThanOrEqual(statusChanges, 2)
    }
    try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys]).write(
      to: URL(fileURLWithPath: root + "/native-parity.json"))
  }
}
