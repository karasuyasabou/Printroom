import AppKit
import CryptoKit
import Foundation
import PrintroomCore

// Compile the production shadow helper next to this standalone driver.
typealias AdobeRAWInstallation = PrintroomCore.AdobeRAWInstallation
typealias PrintroomError = PrintroomCore.PrintroomError

private final class Results: @unchecked Sendable {
  let lock = NSLock()
  var rows: [[String: Any]] = []
  var failures: [String] = []
  func record(_ row: [String: Any]) { lock.lock(); defer { lock.unlock() }; rows.append(row) }
  func fail(_ text: String) { lock.lock(); defer { lock.unlock() }; failures.append(text) }
}

@main struct AdobeShadowQA {
  static func main() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let work = root.appendingPathComponent("scratch/adobe-shadow-\(UUID())")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let adobe = URL(fileURLWithPath: "/Applications/Adobe DNG Converter.app/Contents")
    let plistURL = adobe.appendingPathComponent("Info.plist")
    let originalInfo = try Data(contentsOf: plistURL)
    let plist = try PropertyListSerialization.propertyList(from: originalInfo, format: nil) as! [String: Any]
    let installation = AdobeRAWInstallation(executable: adobe.appendingPathComponent("MacOS/Adobe DNG Converter"),
      version: "\(plist["CFBundleShortVersionString"] ?? "?") (\(plist["CFBundleVersion"] ?? "?"))")
    let executable = try AdobeShadowBundle.executable(for: installation)
    let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")), format: nil) as! [String: Any]
    guard info["LSUIElement"] as? Bool == true else { throw PrintroomError.invalid("LSUIElement missing") }
    let evidence = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("docs/raw-adobe-study-2026-09-09.json"))) as! [String: Any]
    let refs = evidence["comparisons"] as! [[String: Any]]
    let count = CommandLine.arguments.contains("--single") ? 1 : 8
    let parallelism = count == 1 ? 1 : 4
    let semaphore = DispatchSemaphore(value: parallelism)
    let group = DispatchGroup(), results = Results()
    let started = Date()
    for reference in refs.prefix(count) {
      let frame = reference["frame"] as! String, expectedHash = reference["rgb_hash"] as! String
      semaphore.wait(); group.enter()
      DispatchQueue.global(qos: .userInitiated).async {
        defer { semaphore.signal(); group.leave() }
        do {
          let source = root.appendingPathComponent("TEST/RAW/\(frame).ARW")
          let folder = work.appendingPathComponent(frame)
          try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
          let destination = folder.appendingPathComponent("source.dng")
          let process = Process(); process.executableURL = executable
          process.arguments = ["-u", "-l", "-p0", "-dng1.1", "-d", folder.path, "-o", destination.lastPathComponent, source.path]
          process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
          try process.run()
          var regular = 0, accessory = 0, prohibited = 0, observedBundle = ""
          while process.isRunning {
            if let running = NSRunningApplication(processIdentifier: process.processIdentifier) {
              observedBundle = running.bundleURL?.path ?? observedBundle
              switch running.activationPolicy {
              case .regular: regular += 1
              case .accessory: accessory += 1
              case .prohibited: prohibited += 1
              @unknown default: break
              }
            }
            Thread.sleep(forTimeInterval: 0.005)
          }
          process.waitUntilExit()
          guard process.terminationStatus == 0 else { throw PrintroomError.invalid("Adobe exit \(process.terminationStatus)") }
          // Decode after Adobe; still at most four current buffers, never eight.
          let decoded = try RawDecoder.decode(linearDNG: destination)
          let hash = decoded.samples.withUnsafeBytes { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
          let row: [String: Any] = ["frame": frame, "pid": process.processIdentifier, "accessorySamples": accessory,
            "regularSamples": regular, "prohibitedSamples": prohibited, "observedBundle": observedBundle,
            "rgbSHA256": hash, "rgbMatchesReference": hash == expectedHash, "width": decoded.width, "height": decoded.height]
          results.record(row)
          if regular != 0 || accessory == 0 || hash != expectedHash { results.fail("\(frame): policy or RGB mismatch") }
        } catch { results.fail("\(frame): \(error)") }
      }
    }
    group.wait()
    guard try Data(contentsOf: plistURL) == originalInfo else { throw PrintroomError.invalid("Installed Adobe plist changed") }
    let report: [String: Any] = ["parallelism": parallelism, "seconds": Date().timeIntervalSince(started),
      "frames": results.rows.sorted { ($0["frame"] as! String) < ($1["frame"] as! String) },
      "failures": results.failures, "installedAdobeInfoUnchanged": true, "shadowExecutable": executable.path,
      "adobeVersion": installation.version, "output": work.path]
    let reportURL = root.appendingPathComponent("scratch/adobe-shadow-\(count)-results.json")
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL)
    print(reportURL.path)
    if !results.failures.isEmpty { throw PrintroomError.invalid(results.failures.joined(separator: "\n")) }
  }
}
