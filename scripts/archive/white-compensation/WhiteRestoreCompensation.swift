import Foundation
import CryptoKit
import AppKit
import PrintroomCore

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
        if digest(bytes) != plan.replacementHash { print("NOTICE: Project changed after the verified write; checking current project and original backup without overwriting subsequent edits.") }
        let expected = try JSONDecoder().decode(RollProject.self, from: bytes)
        let loaded = try ProjectStore.open(folder: folder)
        guard loaded.id == plan.projectID, loaded.algorithmVersion == "printroom-density-v6",
          loaded.frames == expected.frames, loaded.calibration == expected.calibration else { fatalError("Project validation differs") }
        let backups = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
          .filter { $0.lastPathComponent.hasPrefix(".printroom-before-white-restore-") }
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
        let candidate = try JSONDecoder().decode(RollProject.self, from: Data(contentsOf: work.appendingPathComponent(plan.replacement)))
        guard candidate.id == plan.projectID, candidate.algorithmVersion == "printroom-density-v6" else { fatalError("Invalid candidate identity") }
        for frame in candidate.frames { try Pipeline.validate(frame.adjustments) }
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
            let backup = folder.appendingPathComponent(".printroom-before-white-restore-\(UUID().uuidString).json")
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
    fatalError("Use the reviewed prepared plan; only apply and verify are supported")
  }
}
