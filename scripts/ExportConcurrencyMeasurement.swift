import CryptoKit
import Foundation
import PrintroomCore

/// Read-only project input; writes exports and a JSON report into a fresh scratch directory.
@main struct ExportConcurrencyMeasurement {
  struct Report: Encodable {
    struct File: Encodable {
      let source: String
      let destination: String
      let bytes: Int
      let sha256: String
    }
    let concurrency: Int
    let elapsedSeconds: Double
    let profile: String
    let compression: String
    let projectSHA256: String
    let outputs: [File]
  }

  static func main() async throws {
    let args = CommandLine.arguments
    guard args.count == 6, let concurrency = Int(args[3]), (1...4).contains(concurrency),
      let first = Int(args[4]), first > 0, let count = Int(args[5]), count > 0 else {
      fatalError("Usage: measure-export-concurrency.sh ROLL OUTPUT CONCURRENCY FIRST_FRAME COUNT")
    }
    let folder = URL(fileURLWithPath: args[1])
    let output = URL(fileURLWithPath: args[2])
    guard !FileManager.default.fileExists(atPath: output.path) else {
      fatalError("OUTPUT must be a new directory")
    }
    let projectURL = folder.appendingPathComponent(".printroom.json")
    let before = try Data(contentsOf: projectURL)
    let project = try ProjectStore.open(folder: folder)
    guard first - 1 + count <= project.frames.count else { fatalError("Frame range exceeds roll") }
    let targets = Set(project.frames[(first - 1)..<(first - 1 + count)].map(\.id))
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let request = try ExportRequest(project: project, targetIDs: targets, destinationDirectory: output)
    let lut = try CubeLUT(url: URL(fileURLWithPath: CineonLogLUT.kodak2383.path))
    let fuji = try CubeLUT(url: URL(fileURLWithPath: CineonLogLUT.fujifilm3513DI.path))
    let profile = try Data(contentsOf: URL(fileURLWithPath: ProjectAssetIdentity.expectedICCPath))
    let result = try await ExportEngine(maximumConcurrentExports: concurrency).run(
      request, lut: lut, p3Profile: profile, fujifilmLUT: fuji)
    guard result.completedCount == count, !result.wasCancelled else {
      fatalError("Export failed: \(result.results.map { $0.error ?? $0.status.rawValue })")
    }
    let outputs = try result.results.map { item -> Report.File in
      let url = item.destination!
      let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
      return Report.File(source: item.sourceName, destination: url.path, bytes: bytes.count,
        sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }
    guard try Data(contentsOf: projectURL) == before else { fatalError("Project changed during measurement") }
    let report = Report(concurrency: concurrency, elapsedSeconds: result.elapsedSeconds,
      profile: project.exportSettings.profile.rawValue, compression: project.exportSettings.compression.rawValue,
      projectSHA256: SHA256.hash(data: before).map { String(format: "%02x", $0) }.joined(), outputs: outputs)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(report)
    try data.write(to: output.appendingPathComponent("measurement.json"))
    print(String(decoding: data, as: UTF8.self))
  }
}
