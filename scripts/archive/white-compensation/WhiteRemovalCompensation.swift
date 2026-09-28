import Foundation
import CryptoKit
import AppKit
import PrintroomCore

// One-off, explicitly selected project compensation. Never called by the app.
// Frozen v4 white shifts, expressed in CV; no LUT inversion or automatic correction.
func shift(_ lut: CineonLogLUT) -> SIMD3<Float> {
  lut == .kodak2383 ? SIMD3(-32.8224, 30.846088, -34.341156)
    : SIMD3(-22.539433, 39.858635, -73.51751)
}
func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
struct Plan: Codable {
  var folder: String
  var projectID: UUID
  var originalHash: String
  var replacementHash: String
  var original: String
  var replacement: String
}
@main struct Compensation {
  static func main() throws {
    let args = CommandLine.arguments
    guard args.count >= 4 else { fatalError("Usage: probe prepare|apply|verify work-directory roll-folder...") }
    let mode = args[1], work = URL(fileURLWithPath: args[2])
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    if mode == "verify" {
      let plans = try JSONDecoder().decode([Plan].self, from: Data(contentsOf: work.appendingPathComponent("plan.json")))
      guard Set(plans.map(\.folder)) == Set(args.dropFirst(3)) else { fatalError("Plan paths differ") }
      for plan in plans {
        let folder = URL(fileURLWithPath: plan.folder)
        let bytes = try Data(contentsOf: folder.appendingPathComponent(".printroom.json"))
        guard digest(bytes) == plan.replacementHash else { fatalError("Readback differs") }
        let expected = try JSONDecoder().decode(RollProject.self, from: bytes)
        let loaded = try ProjectStore.open(folder: folder)
        guard loaded.id == plan.projectID, loaded.algorithmVersion == "printroom-density-v5",
          loaded.frames == expected.frames, loaded.calibration == expected.calibration else { fatalError("Project validation differs") }
        let backups = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
          .filter { $0.lastPathComponent.hasPrefix(".printroom-before-white-removal-") }
        guard try backups.contains(where: { digest(try Data(contentsOf: $0)) == plan.originalHash }) else { fatalError("Missing exact backup") }
        print("VERIFIED \(plan.folder): \(loaded.frames.count) frames; production open and exact backup OK")
      }
      return
    }
    if mode == "apply" {
      guard !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "studio.printroom.local.v3.3" }) else {
        throw NSError(domain: "Compensation", code: 1, userInfo: [NSLocalizedDescriptionKey: "Quit Printroom before applying settings."])
      }
      let plans = try JSONDecoder().decode([Plan].self, from: Data(contentsOf: work.appendingPathComponent("plan.json")))
      guard Set(plans.map(\.folder)) == Set(args.dropFirst(3)) else { fatalError("Plan paths differ from requested paths") }
      // Validate all inputs and all prepared payloads before changing either project.
      for plan in plans {
        guard digest(try Data(contentsOf: URL(fileURLWithPath: plan.folder).appendingPathComponent(".printroom.json"))) == plan.originalHash,
          digest(try Data(contentsOf: work.appendingPathComponent(plan.original))) == plan.originalHash,
          digest(try Data(contentsOf: work.appendingPathComponent(plan.replacement))) == plan.replacementHash else { fatalError("Project or plan changed; prepare again") }
      }
      for plan in plans {
        let folder = URL(fileURLWithPath: plan.folder), target = folder.appendingPathComponent(".printroom.json")
        var coordinationError: NSError?, result: Result<Void, Error>?
        NSFileCoordinator().coordinate(writingItemAt: target, options: .forReplacing, error: &coordinationError) { url in
          result = Result {
            let original = try Data(contentsOf: url)
            guard digest(original) == plan.originalHash else { throw NSError(domain: "CompensationConflict", code: 1) }
            let backup = folder.appendingPathComponent(".printroom-before-white-removal-\(UUID().uuidString).json")
            try original.write(to: backup, options: .withoutOverwriting)
            try Data(contentsOf: work.appendingPathComponent(plan.replacement)).write(to: url, options: .atomic)
            guard digest(try Data(contentsOf: url)) == plan.replacementHash else { throw NSError(domain: "CompensationReadback", code: 1) }
            print("APPLIED \(plan.folder) backup=\(backup.lastPathComponent)")
          }
        }
        if let coordinationError { throw coordinationError }
        try result!.get()
      }
      return
    }
    guard mode == "prepare" else { fatalError("Unknown mode") }
    let cache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/studio.printroom.local.v3.3/raw-v1")
    var proxies: [String: URL] = [:]
    for folder in try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil) {
      guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
        let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let identity = manifest["identity"] as? [String: Any], let revision = identity["sourceRevision"] as? String else { continue }
      proxies[revision] = folder.appendingPathComponent("proxy.tiff")
    }
    var plans: [Plan] = [], reports: [[String: Any]] = []
    let gpu = try MetalPipeline()
    for (index, path) in args.dropFirst(3).enumerated() {
      let source = URL(fileURLWithPath: path).appendingPathComponent(".printroom.json")
      let original = try Data(contentsOf: source)
      var object = try JSONSerialization.jsonObject(with: original) as! [String: Any]
      let project = try JSONDecoder().decode(RollProject.self, from: original)
      guard project.algorithmVersion == "printroom-density-v4" else { fatalError("Only unconverted v4 projects may be compensated") }
      var frames = object["frames"] as! [[String: Any]]
      var rollMax: Float = 0, rollD3: Float = 0
      for (i, frame) in project.frames.enumerated() {
        let old = frame.adjustments, c = old.contrast
        let effective = SIMD3(c.red, c.green, c.blue) * c.master
        let delta = shift(old.cineonLogLUT) / effective
        var replacement = old
        replacement.timing.red += Int(delta.x.rounded())
        replacement.timing.green += Int(delta.y.rounded())
        replacement.timing.blue += Int(delta.z.rounded())
        try Pipeline.validate(replacement)
        let applied = SIMD3(Float(replacement.timing.red - old.timing.red), Float(replacement.timing.green - old.timing.green), Float(replacement.timing.blue - old.timing.blue))
        let residual = applied * effective - shift(old.cineonLogLUT)
        let residualMax = max(abs(residual.x), abs(residual.y), abs(residual.z))
        rollD3 = max(rollD3, residualMax)
        var adjustmentObject = frames[i]["adjustments"] as! [String: Any]
        adjustmentObject["timing"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(replacement.timing))
        frames[i]["adjustments"] = adjustmentObject
        guard let identity = frame.rawProcessing, let proxy = proxies[identity.sourceRevision] else { fatalError("Missing existing proxy for \(frame.filename)") }
        let decoded = try TIFFCodec.readPreview(url: proxy, maxDimension: 320)
        let pixels: [SIMD4<Float>] = stride(from: 0, to: decoded.samples.count, by: 3).map { k in
          SIMD4(Float(decoded.samples[k]) / 65535, Float(decoded.samples[k+1]) / 65535, Float(decoded.samples[k+2]) / 65535, 1)
        }
        let input = PixelBuffer(width: decoded.width, height: decoded.height, pixels: pixels)
        let lut = try CubeLUT(url: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(old.cineonLogLUT.path))
        let oldD3 = try Pipeline.render(input, calibration: project.calibration, adjustments: old, stage: .d3)
        let newOutput = try Pipeline.render(input, calibration: project.calibration, adjustments: replacement, lut: lut)
        let metal = try gpu.render(input, calibration: project.calibration, adjustments: replacement, lut: lut)
        var maximum: Float = 0, squared = 0.0, gpuMax: Float = 0
        for k in oldD3.pixels.indices {
          let d = oldD3.pixels[k]
          let expected = lut.sample(SIMD3(d.x, d.y, d.z) + shift(old.cineonLogLUT) / 1024)
          for ch in 0..<3 {
            let error = abs(expected[ch] - newOutput.pixels[k][ch])
            maximum = max(maximum, error); squared += Double(error * error)
            gpuMax = max(gpuMax, abs(metal.pixels[k][ch] - newOutput.pixels[k][ch]))
          }
        }
        guard gpuMax <= 2e-4 else { fatalError("Metal mismatch") }
        rollMax = max(rollMax, maximum)
        reports.append(["roll": path, "filename": frame.filename, "lut": old.cineonLogLUT.rawValue,
          "oldTiming": try JSONSerialization.jsonObject(with: JSONEncoder().encode(old.timing)),
          "newTiming": try JSONSerialization.jsonObject(with: JSONEncoder().encode(replacement.timing)),
          "residualD3CV": [residual.x, residual.y, residual.z], "maxRGBError": maximum,
          "rmsRGBError": sqrt(squared / Double(input.pixels.count * 3)), "gpuMaxError": gpuMax,
          "samplePixels": input.pixels.count])
      }
      object["frames"] = frames; object["algorithmVersion"] = "printroom-density-v5"
      object["updatedAt"] = Date().timeIntervalSinceReferenceDate
      let replacement = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
      let originalName = "roll-\(index)-original.json", replacementName = "roll-\(index)-replacement.json"
      try original.write(to: work.appendingPathComponent(originalName), options: .atomic)
      try replacement.write(to: work.appendingPathComponent(replacementName), options: .atomic)
      plans.append(Plan(folder: path, projectID: project.id, originalHash: digest(original), replacementHash: digest(replacement), original: originalName, replacement: replacementName))
      print("PREPARED \(path): \(frames.count) frames; max D3 residual \(rollD3) CV; max output error \(rollMax)")
    }
    try JSONEncoder().encode(plans).write(to: work.appendingPathComponent("plan.json"), options: .atomic)
    try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys]).write(to: work.appendingPathComponent("report.json"), options: .atomic)
  }
}
