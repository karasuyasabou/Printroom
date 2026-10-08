import AppKit
import CryptoKit
import Darwin
import Foundation
import PrintroomCore

@_silgen_name("proc_listchildpids")
private func childPIDs(_ parent: pid_t, _ buffer: UnsafeMutableRawPointer?, _ size: Int32) -> Int32

private final class Observations: @unchecked Sendable {
  let lock = NSLock()
  var stop = false
  var peak = 0
  var regular = 0
  var accessory = 0
  var processes = Set<pid_t>()
  var errors: [String] = []
  var proxies: [[String: Any]] = []
  func shouldStop() -> Bool { lock.lock(); defer { lock.unlock() }; return stop }
  func finish() { lock.lock(); defer { lock.unlock() }; stop = true }
  func record(_ applications: [NSRunningApplication]) {
    lock.lock(); defer { lock.unlock() }
    var activeCount = 0
    for app in applications {
      // A process can exit between querying its PID and reading AppKit's object.
      let pid = app.processIdentifier
      guard pid > 0, !app.isTerminated else { continue }
      activeCount += 1
      processes.insert(pid)
      if app.activationPolicy == .regular { regular += 1 }
      if app.activationPolicy == .accessory { accessory += 1 }
    }
    peak = max(peak, activeCount)
  }
  func proxy(_ value: [String: Any]) { lock.lock(); defer { lock.unlock() }; proxies.append(value) }
  func fail(_ message: String) { lock.lock(); defer { lock.unlock() }; errors.append(message) }
}

@main struct AdobeServiceFourQA {
  static func sampleHash(_ image: LinearImage) -> String {
    image.samples.withUnsafeBytes { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
  }
  static func main() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let work = root.appendingPathComponent("scratch/adobe-service-four-\(UUID())")
    let roll = work.appendingPathComponent("roll")
    try FileManager.default.createDirectory(at: roll, withIntermediateDirectories: true)
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("docs/raw-adobe-study-2026-09-09.json"))) as! [String: Any]
    let frames: [(String, String)] = (json["comparisons"] as! [[String: Any]]).map { ($0["frame"] as! String, $0["rgb_hash"] as! String) }
    for (frame, _) in frames {
      try FileManager.default.copyItem(at: root.appendingPathComponent("TEST/RAW/\(frame).ARW"), to: roll.appendingPathComponent("\(frame).ARW"))
    }
    let service = SourceProxyService(cacheRoot: work.appendingPathComponent("cache"))
    let observations = Observations(), watcher = DispatchGroup(), consumers = DispatchGroup()
    watcher.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      defer { watcher.leave() }
      while !observations.shouldStop() {
        // Query this driver's child PIDs directly. NSWorkspace's running-app
        // snapshot can stay stale while a command-line main thread is waiting.
        var pids = [pid_t](repeating: 0, count: 64)
        _ = pids.withUnsafeMutableBytes { childPIDs(getpid(), $0.baseAddress, Int32($0.count)) }
        let apps = pids.filter { $0 > 0 }.compactMap { NSRunningApplication(processIdentifier: $0) }
          .filter { $0.bundleURL?.lastPathComponent == "Adobe DNG Converter.app" }
        observations.record(apps)
        Thread.sleep(forTimeInterval: 0.005)
      }
    }
    let started = Date()
    // Eight concurrent consumers exercise the production service's four workers.
    // Consumer count must not itself cap/hide an accidentally unlimited service.
    for (frame, _) in frames {
      consumers.enter()
      DispatchQueue.global(qos: .userInitiated).async {
        defer { consumers.leave() }
        do {
          let begin = Date()
          let preview = try service.preview(url: roll.appendingPathComponent("\(frame).ARW"))
          let serviceCompletion = Date().timeIntervalSince(started)
          let serviceWait = Date().timeIntervalSince(begin)
          let reference = try TIFFCodec.readPreview(url: root.appendingPathComponent("scratch/raw-adobe-study/reference/\(frame).ARW.tiff"), maxDimension: 1600)
          let matches = preview.width == reference.width && preview.height == reference.height && preview.samples == reference.samples
          observations.proxy(["frame": frame, "serviceWaitSeconds": serviceWait, "serviceCompletionSeconds": serviceCompletion, "samplesMatchReference": matches])
          if !matches { observations.fail("\(frame) proxy mismatch") }
        } catch { observations.fail("\(frame): \(error)") }
      }
    }
    consumers.wait(); observations.finish(); watcher.wait()
    let proxySeconds = Date().timeIntervalSince(started)
    var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
    let proxyPeakRSS = usage.ru_maxrss
    var images: [[String: Any]] = []
    let fullStarted = Date()
    for (frame, expected) in frames {
      try autoreleasepool {
        let image = try service.read(url: roll.appendingPathComponent("\(frame).ARW"))
        let actual = sampleHash(image)
        images.append(["frame": frame, "width": image.width, "height": image.height,
                       "rgbSHA256": actual, "matchesReference": actual == expected])
        if actual != expected { observations.fail("\(frame) full RGB mismatch") }
      }
    }
    getrusage(RUSAGE_SELF, &usage)
    if observations.peak != 4 { observations.fail("Expected peak 4 Adobe processes; saw \(observations.peak)") }
    if observations.regular != 0 || observations.accessory == 0 { observations.fail("Expected accessory only Adobe processes") }
    let lastServiceCompletion = observations.proxies.compactMap { $0["serviceCompletionSeconds"] as? Double }.max() ?? 0
    let report: [String: Any] = ["output": work.path, "proxyPreparationAndComparisonSeconds": proxySeconds, "proxyServiceCompletionSeconds": lastServiceCompletion,
      "serialFullPreparationAndHashSeconds": Date().timeIntervalSince(fullStarted),
      "observedPeakAdobeProcesses": observations.peak, "observedAdobePIDs": observations.processes.sorted(),
      "regularSamples": observations.regular, "accessorySamples": observations.accessory,
      "proxyPhasePeakRSSBytes": proxyPeakRSS, "totalPeakRSSBytes": usage.ru_maxrss,
      "proxies": observations.proxies.sorted { ($0["frame"] as! String) < ($1["frame"] as! String) },
      "fullImages": images, "failures": observations.errors]
    let destination = root.appendingPathComponent("scratch/adobe-service-four-results.json")
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: destination)
    print(destination.path)
    if !observations.errors.isEmpty { throw PrintroomError.invalid(observations.errors.joined(separator: "\n")) }
  }
}
