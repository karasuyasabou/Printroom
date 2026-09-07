// Real modal export entry points, synthetic inputs only, window-scoped screenshots.
import AppKit
import ImageIO
import PrintroomCore
import SwiftUI

private struct QAError: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
  if try !condition() { throw QAError(message) }
}

@main struct ExportPanelQA {
  @MainActor static func main() {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    Task { @MainActor in
      do {
        try await ExportPanelRun().run()
        app.terminate(nil)
      } catch {
        print("FAIL: \(error)")
        exit(1)
      }
    }
    app.run()
  }
}

@MainActor private final class ExportPanelRun {
  let model = EditorModel()
  let fm = FileManager.default
  let output: URL
  var evidence: [String] = []

  init() {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("scratch/export-panel-qa", isDirectory: true)
    output = root.appendingPathComponent("run-\(UUID().uuidString)", isDirectory: true)
  }

  func record(_ text: String) {
    evidence.append(text)
    print(text)
    fflush(stdout)
  }

  func run() async throws {
    try fm.createDirectory(at: output, withIntermediateDirectories: true)
    defer {
      try? (evidence.joined(separator: "\n") + "\n").write(
        to: output.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
    }
    do { try await scenarios() } catch {
      record("FAIL: \(error)")
      throw error
    }
  }

  func scenarios() async throws {
    guard let assets = model.assets else { throw QAError(model.errorMessage ?? "Missing assets") }
    let roll = output.appendingPathComponent("roll", isDirectory: true)
    let exports = roll.appendingPathComponent("Printroom Exports", isDirectory: true)
    try fm.createDirectory(at: exports, withIntermediateDirectories: true)
    var originals: [URL: Data] = [:]
    for (index, name) in ["A.tiff", "B.tiff", "C.tiff"].enumerated() {
      let url = roll.appendingPathComponent(name)
      try TIFFCodec.write(url: url, width: 24, height: 16, profile: assets.profile) { rows in
        var samples: [UInt16] = []
        for y in rows {
          for x in 0..<24 {
            samples.append(UInt16(12000 + index * 2500 + x * 600))
            samples.append(UInt16(16000 + y * 700))
            samples.append(UInt16(22000 + x * 250))
          }
        }
        return samples
      }
      originals[url] = try Data(contentsOf: url)
    }
    record("OUTPUT: \(output.path)")
    record("INPUT: 3 generated 24×16 RGB UInt16 TIFFs; no reference TIFFs read")
    let window = NSWindow(
      contentRect: NSRect(x: 100, y: 100, width: 1120, height: 760),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = "Printroom · Export panel QA · synthetic input"
    window.contentView = NSHostingView(rootView: EditorView(model: model))
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    defer { window.orderOut(nil) }
    model.open(roll)
    try await wait("synthetic preview", until: { !self.model.isLoading && self.model.previewImage != nil })
    guard let frames = model.project?.frames, frames.count == 3 else { throw QAError("Fixture frame count") }
    model.select(frames[0].id)
    model.select(frames[1].id, command: true)
    let selectedIDs = Set([frames[0].id, frames[1].id])
    try require(model.selection.selectedFrameIDs == selectedIDs, "Two selected frames required")
    model.setExportSettings(.init(profile: .adobeRGB, compression: .deflate))
    try require(model.flushSave(), "Initial project save failed")

    let entries: [(String, () -> Void)] = [
      ("01-current-cancel", { self.model.exportPanel() }),
      ("02-selected-cancel", { self.model.batchExportPanel(allFrames: false) }),
      ("03-roll-cancel", { self.model.batchExportPanel(allFrames: true) }),
    ]
    for (name, entry) in entries {
      let before = model.exportSettings
      let sidecar = try Data(contentsOf: roll.appendingPathComponent(ProjectStore.filename))
      let driver = PanelDriver(name: name, output: output, initial: before,
        chosen: .init(profile: .sRGB, compression: .none), confirm: false)
      try exercise(driver, entry: entry)
      try require(model.exportSettings == before, "\(name): cancel changed in-memory preferences")
      try require(try Data(contentsOf: roll.appendingPathComponent(ProjectStore.filename)) == sidecar,
        "\(name): cancel wrote project")
      try require(!model.isExporting && model.exportSummary == nil, "\(name): cancel started an export")
      try require(try fm.contentsOfDirectory(atPath: exports.path).isEmpty, "\(name): cancel created output")
      record("PASS \(name): accessory visible on presentation; 4 ICC × 2 compression choices; cancel preserves project bytes and creates no export")
    }

    let confirms: [(String, ProjectExportSettings, Set<UUID>, () -> Void)] = [
      ("04-current-p3", .init(profile: .p3, compression: .none), [frames[1].id], { self.model.exportPanel() }),
      ("05-current-srgb", .init(profile: .sRGB, compression: .deflate), [frames[1].id], { self.model.exportPanel() }),
      ("06-selected-adobe", .init(profile: .adobeRGB, compression: .none), selectedIDs,
        { self.model.batchExportPanel(allFrames: false) }),
      ("07-roll-prophoto", .init(profile: .proPhoto, compression: .deflate), Set(frames.map(\.id)),
        { self.model.batchExportPanel(allFrames: true) }),
    ]
    for (name, settings, expectedIDs, entry) in confirms {
      model.showExportSummary = false
      let driver = PanelDriver(name: name, output: output, initial: model.exportSettings,
        chosen: settings, confirm: true)
      try exercise(driver, entry: entry)
      try require(model.exportSettings == settings, "\(name): confirmed settings missing from model")
      let reopened = try ProjectStore.open(folder: roll)
      try require(reopened.exportSettings == settings, "\(name): confirmed settings not persisted")
      try await wait("\(name) export", until: { !self.model.isExporting })
      guard let summary = model.exportSummary else { throw QAError("\(name): missing summary") }
      try require(summary.failedCount == 0 && summary.completedCount == expectedIDs.count,
        "\(name): unexpected export results \(summary.results.map { $0.error ?? $0.status.rawValue })")
      try require(Set(summary.results.map(\.id)) == expectedIDs, "\(name): wrong target set")
      for result in summary.results {
        guard let url = result.destination else { throw QAError("\(name): output URL missing") }
        try verifyTIFF(url, settings: settings, p3: assets.profile)
        record("READBACK \(url.lastPathComponent): \(settings.profile.label), compression=\(settings.compression.rawValue), RGB 16-bit, exact ICC bytes, 24×16")
      }
      model.showExportSummary = false
      record("PASS \(name): native dialog confirmation → persisted settings → existing export snapshot; \(expectedIDs.count) frames")
    }
    for (url, original) in originals {
      try require(try Data(contentsOf: url) == original, "Synthetic source changed: \(url.lastPathComponent)")
    }
    try require(try fm.contentsOfDirectory(atPath: exports.path).filter { $0.hasSuffix(".tiff") }.count == 7,
      "Expected 7 distinct exports, including automatic collision suffixes")
    record("PASS: 3 cancelled real dialogs, 4 confirmed real dialogs, 7 TIFF readbacks, sources unchanged, collision suffixes preserved")
  }

  func exercise(_ driver: PanelDriver, entry: () -> Void) throws {
    let timer = Timer(timeInterval: 0.15, target: driver, selector: #selector(PanelDriver.tick(_:)),
      userInfo: nil, repeats: true)
    RunLoop.main.add(timer, forMode: .common)
    RunLoop.main.add(timer, forMode: .modalPanel)
    defer { timer.invalidate() }
    entry()
    if let failure = driver.failure { throw failure }
    try require(driver.completed, "\(driver.name): real modal dialog was not exercised")
    for line in driver.evidence { record(line) }
  }

  func wait(_ message: String, until ready: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(20)
    while !ready() && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
    try require(ready(), "Timed out: \(message); \(model.errorMessage ?? "")")
  }

  func verifyTIFF(_ url: URL, settings: ProjectExportSettings, p3: Data) throws {
    // Independent IFD inspection of these classic little-endian output files.
    let bytes = try Data(contentsOf: url)
    func u16(_ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
    func u32(_ offset: Int) -> Int { u16(offset) | u16(offset + 2) << 16 }
    try require(bytes.count >= 8 && bytes[0] == 73 && bytes[1] == 73 && u16(2) == 42, "Classic TIFF header")
    let ifd = u32(4)
    try require(ifd + 2 <= bytes.count, "IFD bounds")
    let count = u16(ifd)
    try require(ifd + 2 + count * 12 <= bytes.count, "IFD entries bounds")
    var tags: [Int: Data] = [:]
    for i in 0..<count {
      let entry = ifd + 2 + i * 12
      let type = u16(entry + 2)
      let size = u32(entry + 4) * (type == 3 ? 2 : type == 4 ? 4 : 1)
      let offset = size <= 4 ? entry + 8 : u32(entry + 8)
      try require(offset >= 0 && offset + size <= bytes.count, "TIFF tag bounds")
      tags[u16(entry)] = bytes.subdata(in: offset..<(offset + size))
    }
    try require(tags[258] == Data([16, 0, 16, 0, 16, 0]), "16-bit RGB tags")
    try require(tags[259] == Data([settings.compression == .none ? 1 : 8, 0]), "Compression tag")
    try require(tags[34675] == settings.profile.profileData(p3: p3), "Embedded ICC bytes")
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw QAError("ImageIO could not independently decode output") }
    try require(image.width == 24 && image.height == 16 && image.bitsPerComponent == 16, "ImageIO dimensions/depth")
    let decoded = try TIFFCodec.read(url: url)
    try require(decoded.samples.count == 24 * 16 * 3, "TIFF sample count")
  }
}

@MainActor private final class PanelDriver: NSObject {
  let name: String
  let output: URL
  let initial: ProjectExportSettings
  let chosen: ProjectExportSettings
  let confirm: Bool
  let started = Date()
  var appeared: Date?
  var phase = 0
  var completed = false
  var failure: Error?
  var evidence: [String] = []

  init(name: String, output: URL, initial: ProjectExportSettings, chosen: ProjectExportSettings, confirm: Bool) {
    self.name = name
    self.output = output
    self.initial = initial
    self.chosen = chosen
    self.confirm = confirm
  }

  @objc func tick(_ timer: Timer) {
    guard failure == nil else { return }
    let panel = NSApp.modalWindow as? NSSavePanel
      ?? NSApp.windows.compactMap { $0 as? NSSavePanel }.first(where: { $0.isVisible })
    do {
      try require(Date().timeIntervalSince(started) < 20, "\(name): panel timed out (phase \(phase))")
      guard !completed else { return }
      guard let panel, panel.isVisible, let options = panel.accessoryView as? ExportOptionsView else { return }
      if appeared == nil { appeared = Date() }
      guard Date().timeIntervalSince(appeared!) > 0.8 else { return }
      if phase == 0 {
        if let open = panel as? NSOpenPanel {
          try require(open.isAccessoryViewDisclosed, "\(name): accessory collapsed on presentation")
        }
        try require(options.window != nil && !options.isHiddenOrHasHiddenAncestor && !options.visibleRect.isEmpty,
          "\(name): accessory not visibly hosted")
        for control in [options.profilePopUp, options.compressionPopUp] {
          try require(!control.isHiddenOrHasHiddenAncestor && !control.visibleRect.isEmpty,
            "\(name): option control clipped/hidden")
        }
        try require(options.settings == initial, "\(name): initial preferences not loaded")
        try require(options.profilePopUp.itemTitles == OutputColorProfile.allCases.map(\.label), "Four ICC choices")
        try require(options.compressionPopUp.itemTitles == ["无压缩", "Deflate"], "Two compression choices")
        try capture(panel, suffix: "initial")
        for profileIndex in OutputColorProfile.allCases.indices {
          for compressionIndex in TIFFCompression.allCases.indices {
            options.profilePopUp.selectItem(at: profileIndex)
            options.compressionPopUp.selectItem(at: compressionIndex)
            try require(options.settings.profile == OutputColorProfile.allCases[profileIndex]
              && options.settings.compression == TIFFCompression.allCases[compressionIndex], "Option selection mapping")
          }
        }
        options.profilePopUp.selectItem(at: OutputColorProfile.allCases.firstIndex(of: chosen.profile)!)
        options.compressionPopUp.selectItem(at: TIFFCompression.allCases.firstIndex(of: chosen.compression)!)
        try require(options.settings == chosen, "\(name): draft settings mismatch")
        if confirm && !(panel is NSOpenPanel) {
          // The presented save panel's filename field lives in the system service.
          // Send real key events to its initial filename focus instead of changing
          // configuration properties after runModal() has begun.
          postKey("a", code: 0, modifiers: .command, to: panel)
          postKey(name + ".tiff", code: 0, to: panel)
        }
        phase = 1
        appeared = Date()
      } else {
        try capture(panel, suffix: "draft")
        evidence.append("DIALOG \(name): \(type(of: panel)), window=\(panel.windowNumber), accessory=\(options.frame), ICC=\(options.profilePopUp.title), compression=\(options.compressionPopUp.title)")
        completed = true
        if confirm {
          // Public ok(nil) does not reliably commit the remote macOS save panel;
          // Return follows the same event route as its default Export button.
          postKey("\r", code: 36, to: panel)
        } else { panel.cancel(nil) }
      }
    } catch {
      failure = error
      timer.invalidate()
      let message = "FAIL \(name): \(error)"
      print(message)
      fflush(stdout)
      try? (evidence.joined(separator: "\n") + "\n" + message + "\n").write(
        to: output.appendingPathComponent(name + "-failure.txt"), atomically: true, encoding: .utf8)
      // A failed remote panel can enter a second alert loop. Do not leave an
      // automated QA process/window waiting indefinitely for manual dismissal.
      exit(1)
    }
  }

  func postKey(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [], to panel: NSSavePanel) {
    for type in [NSEvent.EventType.keyDown, .keyUp] {
      if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
        context: nil, characters: characters, charactersIgnoringModifiers: characters,
        isARepeat: false, keyCode: code)
      { NSApp.postEvent(event, atStart: false) }
    }
  }

  func capture(_ panel: NSSavePanel, suffix: String) throws {
    // Never capture a display/desktop or another application's window.
    let windowID = CGWindowID(panel.windowNumber)
    guard let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
      let own = info.first,
      own[kCGWindowOwnerPID as String] as? Int == Int(ProcessInfo.processInfo.processIdentifier)
    else { throw QAError("\(name): refused screenshot of a window not owned by this QA application") }
    let url = output.appendingPathComponent("\(name)-\(suffix).png")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", "-o", "-l", String(windowID), url.path]
    try process.run()
    process.waitUntilExit()
    try require(process.terminationStatus == 0, "\(name): window screenshot failed")
    evidence.append("SCREENSHOT \(url.lastPathComponent)")
  }
}
