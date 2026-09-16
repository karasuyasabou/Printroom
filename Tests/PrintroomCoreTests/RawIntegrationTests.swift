import CryptoKit
import Foundation
import Darwin
import XCTest
@testable import PrintroomCore

/// Opt in with scripts/test-raw-integration.sh. Never writes TEST/ or studies.
final class RawIntegrationTests: XCTestCase, @unchecked Sendable {
  private var root: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  }
  private func hash(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
    var digest = SHA256()
    while let data = try handle.read(upToCount: 8 * 1024 * 1024), !data.isEmpty { digest.update(data: data) }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
  }
  private func sampleHash(_ image: LinearImage) -> String {
    image.samples.withUnsafeBytes { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
  }
  func testRealFullRollExportPerformance() async throws {
    guard ProcessInfo.processInfo.environment["PRINTROOM_RAW_FULL_ROLL"] == "1" else {
      throw XCTSkip("Set PRINTROOM_RAW_FULL_ROLL=1 after the real source integration test.")
    }
    let previous = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("scratch/raw-integration-results.json"))) as! [String: Any]
    let work = URL(fileURLWithPath: previous["output"] as! String)
    let roll = work.appendingPathComponent("roll")
    let output = work.appendingPathComponent("full-roll-\(UUID())")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    var project = try ProjectStore.open(folder: roll)
    XCTAssertEqual(project.frames.count, 8)
    for i in project.frames.indices {
      project.frames[i].adjustments = FrameAdjustments(timing: .init(master: 8, red: 3, green: -2, blue: 1), contrast: .init(master: 1.03))
      project.frames[i].crop = nil
    }
    let lut = try CubeLUT(url: root.appendingPathComponent("LUT/DCI-P3 Kodak 2383 D65.cube"))
    let profile = try Data(contentsOf: root.appendingPathComponent("ICC/DCIP3_D65.icc"))
    let request = try ExportRequest(project: project, targetIDs: Set(project.frames.map(\.id)), destinationDirectory: output)
    let result = try await ExportEngine(useCPUReference: true).run(request, lut: lut, p3Profile: profile)
    var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
    XCTAssertEqual(result.completedCount, 8); XCTAssertEqual(result.failedCount, 0)
    var outputs: [[String: Any]] = []
    for frame in result.results {
      let url = try XCTUnwrap(frame.destination)
      let m = try TIFFCodec.metadata(url: url)
      XCTAssertEqual(m.width, 7008); XCTAssertEqual(m.height, 4672)
      let exactICC = try autoreleasepool { try Data(contentsOf: url, options: .mappedIfSafe).range(of: profile) != nil }
      XCTAssertTrue(exactICC)
      outputs.append(["frame": frame.sourceName, "width": m.width, "height": m.height, "exactP3ICC": exactICC])
    }
    let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("studio.printroom.local.v3.3/raw-v1")
    let items = FileManager.default.enumerator(at: cacheRoot, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
    var cacheBytes: Int64 = 0
    while let url = items?.nextObject() as? URL {
      let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
      if values.isRegularFile == true { cacheBytes += Int64(values.fileSize ?? 0) }
    }
    let report: [String: Any] = ["frames": outputs, "fullRollExportSeconds": result.elapsedSeconds,
                                "peakTestProcessRSSBeforeVerificationBytes": usage.ru_maxrss,
                                "cacheBytes": cacheBytes, "cacheLimitBytes": RAWSourceService.defaultCacheLimit,
                                "cacheState": "proxy cache only; each export decodes transient full-size pixels",
                                "concurrency": 1, "renderer": "CPU reference", "compression": "none", "output": output.path]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      .write(to: root.appendingPathComponent("scratch/raw-full-roll-results.json"))
    print("RAW full roll report: \(output.path)")
  }
  func testRealAdobeSourceProxyPrecisionAndExports() async throws {
    guard ProcessInfo.processInfo.environment["PRINTROOM_RAW_INTEGRATION"] == "1" else {
      throw XCTSkip("Set PRINTROOM_RAW_INTEGRATION=1 with real Adobe and study reference TIFFs.")
    }
    let work = root.appendingPathComponent("scratch/raw-integration-\(UUID())")
    let roll = work.appendingPathComponent("roll")
    let exports = work.appendingPathComponent("exports")
    try FileManager.default.createDirectory(at: roll, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("docs/raw-adobe-study-2026-09-09.json"))) as! [String: Any]
    let rows = json["comparisons"] as! [[String: Any]]
    let lut = try CubeLUT(url: root.appendingPathComponent("LUT/DCI-P3 Kodak 2383 D65.cube"))
    let profile = try Data(contentsOf: root.appendingPathComponent("ICC/DCIP3_D65.icc"))
    let adjustments = FrameAdjustments(timing: .init(master: 8, red: 3, green: -2, blue: 1), contrast: .init(master: 1.03))
    let calibration = FilmCalibration()
    var metrics: [[String: Any]] = []
    for row in rows {
      let frame = row["frame"] as! String
      let original = root.appendingPathComponent("TEST/RAW/\(frame).ARW")
      let before = try hash(original)
      let source = roll.appendingPathComponent("\(frame).ARW")
      try FileManager.default.copyItem(at: original, to: source)
      let reference = root.appendingPathComponent("scratch/raw-adobe-study/reference/\(frame).ARW.tiff")
      let measurement: [String: Any] = try autoreleasepool {
        let start = Date()
        let proxy = try SourceImageIO.readPreview(url: source, maxDimension: 1600)
        let firstProxy = Date().timeIntervalSince(start)
        let hitStart = Date()
        let cached = try SourceImageIO.readPreview(url: source, maxDimension: 1600)
        let hit = Date().timeIntervalSince(hitStart)
        XCTAssertEqual(proxy.samples, cached.samples)
        let expectedProxy = try TIFFCodec.readPreview(url: reference, maxDimension: 1600)
        XCTAssertEqual(proxy.width, expectedProxy.width); XCTAssertEqual(proxy.height, expectedProxy.height)
        XCTAssertEqual(proxy.samples, expectedProxy.samples, frame)
        let roi = PixelRect(x: 3293, y: 2047, width: 13, height: 11)
        let exactStart = Date()
        let region = try SourceImageIO.readRegion(url: source, rect: roi)
        let precision = Date().timeIntervalSince(exactStart)
        var regionSamples = [UInt16]()
        for y in roi.y..<(roi.y + roi.height) {
          for x in roi.x..<(roi.x + roi.width) {
            let i = ((y * expectedProxy.height / 4672) * expectedProxy.width + x * expectedProxy.width / 7008) * 3
            regionSamples.append(contentsOf: expectedProxy.samples[i..<(i + 3)])
          }
        }
        let referenceRegion = LinearImage(width: roi.width, height: roi.height, samples: regionSamples)
        XCTAssertEqual(region.samples, referenceRegion.samples)
        let fullStart = Date()
        let full = try SourceImageIO.read(url: source)
        let fullSeconds = Date().timeIntervalSince(fullStart)
        XCTAssertEqual(full.width, 7008); XCTAssertEqual(full.height, 4672)
        let actualHash = sampleHash(full)
        XCTAssertEqual(actualHash, row["rgb_hash"] as? String, frame)
        // Small exact original-resolution ROI: both CPU and actual Metal receive
        // matching samples and the same current density/LUT contract.
        let a = region.preview(maxDimension: 13), b = referenceRegion.preview(maxDimension: 13)
        let cpu = try Pipeline.render(a, calibration: calibration, adjustments: adjustments, lut: lut)
        let referenceCPU = try Pipeline.render(b, calibration: calibration, adjustments: adjustments, lut: lut)
        XCTAssertEqual(cpu.pixels, referenceCPU.pixels)
        let gpu = try MetalPipeline()
        let metal = try gpu.render(a, calibration: calibration, adjustments: adjustments, lut: lut)
        let referenceMetal = try gpu.render(b, calibration: calibration, adjustments: adjustments, lut: lut)
        XCTAssertEqual(metal.pixels, referenceMetal.pixels)
        for (p,q) in zip(cpu.pixels, metal.pixels) {
          for c in 0..<3 { XCTAssertLessThanOrEqual(abs(p[c]-q[c]), 0.0001) }
        }
        return ["frame": frame, "firstProxySeconds": firstProxy, "cachedProxySeconds": hit,
                "firstPrecisionSeconds": precision, "cachedFullReadSeconds": fullSeconds,
                "rgbSHA256": actualHash, "rgbMatchesReference": actualHash == row["rgb_hash"] as? String]
      }
      XCTAssertEqual(try hash(original), before, "Original RAW changed")
      metrics.append(measurement)
    }
    // Eight-frame queue, immutable source snapshot, crop + user orientation.
    var project = try ProjectStore.open(folder: roll)
    for i in project.frames.indices {
      project.frames[i].adjustments = adjustments
      project.frames[i].crop = FrameCrop(aspect: .square, width: 0.025, angleDegrees: 1.5)
    }
    let request = try ExportRequest(project: project, targetIDs: Set(project.frames.map(\.id)), destinationDirectory: exports)
    project.frames[0].adjustments.timing.master += 100
    let engine = ExportEngine(useCPUReference: true)
    let summary = try await engine.run(request, lut: lut, p3Profile: profile)
    XCTAssertEqual(summary.completedCount, 8); XCTAssertEqual(summary.failedCount, 0)
    for result in summary.results {
      let actualURL = try XCTUnwrap(result.destination)
      let reference = root.appendingPathComponent("scratch/raw-adobe-study/reference/\(result.sourceName).tiff")
      let expectedURL = exports.appendingPathComponent("reference-\(result.sourceName).tiff")
      let expected = try ExportRequest(source: reference, destination: expectedURL, calibration: calibration,
                                      adjustments: adjustments, crop: FrameCrop(aspect: .square, width: 0.025, angleDegrees: 1.5))
      let rendered = try await engine.run(expected, lut: lut, p3Profile: profile)
      XCTAssertEqual(rendered.completedCount, 1)
      XCTAssertEqual(try TIFFCodec.read(url: actualURL).samples, try TIFFCodec.read(url: expectedURL).samples)
    }
    let fullOutput = exports.appendingPathComponent("full-size.tiff")
    let fullRequest = try ExportRequest(source: roll.appendingPathComponent("DSC07119.ARW"), destination: fullOutput,
                                       calibration: calibration, adjustments: adjustments)
    let fullResult = try await engine.run(fullRequest, lut: lut, p3Profile: profile)
    XCTAssertEqual(fullResult.completedCount, 1)
    let dimensions = try TIFFCodec.metadata(url: fullOutput)
    XCTAssertEqual(dimensions.width, 7008); XCTAssertEqual(dimensions.height, 4672)
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    XCTAssertNotNil(try Data(contentsOf: fullOutput, options: .mappedIfSafe).range(of: profile), "Output embeds exact P3 ICC bytes")
    let report: [String: Any] = ["peakTestProcessRSSBytes": usage.ru_maxrss, "frames": metrics, "batchCroppedExportSeconds": summary.elapsedSeconds,
                                "fullSizeExportSeconds": fullResult.elapsedSeconds,
                                "libRawVersion": RawDecoder.version, "output": work.path]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      .write(to: root.appendingPathComponent("scratch/raw-integration-results.json"))
    print("RAW integration report: \(work.path)")
  }
}
