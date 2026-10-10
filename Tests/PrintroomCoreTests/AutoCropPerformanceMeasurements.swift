import Foundation
import XCTest
@testable import PrintroomCore

final class AutoCropPerformanceMeasurements: XCTestCase {
  func testExistingProxies() throws {
    let env = ProcessInfo.processInfo.environment
    guard let root = env["PRINTROOM_AUTOCROP_BENCH"] else { throw XCTSkip("Opt-in existing proxy benchmark") }
    struct Input: Decodable { let name: String; let proxy: String; let width: Int; let height: Int }
    let all = try JSONDecoder().decode([Input].self, from: Data(contentsOf: URL(fileURLWithPath: root + "/inputs.json")))
    let count = Int(env["PRINTROOM_AUTOCROP_COUNT"] ?? "6") ?? 6
    let inputs = Array(all.prefix(count))
    PerformanceTrace.reset()
    let start = Date()
    var seeds = [AutoCropSeed](), cached = [AutoCropAnalysis]()
    let reuse = env["PRINTROOM_AUTOCROP_REUSE"] == "1"
    for input in inputs {
      let image = try PerformanceTrace.measure("autocrop.read.first") { try TIFFCodec.read(url: URL(fileURLWithPath: input.proxy)) }
      let analysis = try AutoCropAnalyzer.prepare(image, sourceWidth: input.width, sourceHeight: input.height)
      seeds.append(analysis.seed)
      if reuse { cached.append(analysis) }
    }
    let template = try AutoCropAnalyzer.template(fromSeeds: seeds, aspectRatio: 1.5)
    var frames = [[String: Any]]()
    for (i, input) in inputs.enumerated() {
      let analysis: AutoCropAnalysis
      if reuse { analysis = cached[i] } else {
        analysis = try PerformanceTrace.measure("autocrop.second") {
          let image = try PerformanceTrace.measure("autocrop.read.second") { try TIFFCodec.read(url: URL(fileURLWithPath: input.proxy)) }
          return try AutoCropAnalyzer.prepare(image, seed: seeds[i], sourceWidth: input.width, sourceHeight: input.height)
        }
      }
      let fit = try AutoCropAnalyzer.fit(analysis, template: template, sourceWidth: input.width, sourceHeight: input.height,
        requiresAllEdges: i == 0 || i == inputs.count - 1)
      frames.append(["name":input.name, "crop":try JSONSerialization.jsonObject(with: JSONEncoder().encode(fit.crop)), "needsReview":fit.needsReview])
    }
    let report: [String: Any] = ["seconds":Date().timeIntervalSince(start), "frames":frames,
      "stages":try JSONSerialization.jsonObject(with: JSONEncoder().encode(PerformanceTrace.snapshot())),
      "templateWidth":template.width, "templateHeight":template.height]
    let tag = env["PRINTROOM_AUTOCROP_TAG"] ?? "run"
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: root + "/" + tag + ".json"))
    print("AUTOCROP BENCH \(tag): \(report["seconds"]!) seconds; \(inputs.count) frames")
  }
}
