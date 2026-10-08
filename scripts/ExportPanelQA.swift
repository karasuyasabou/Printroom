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
    app.finishLaunching()
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
  weak var hostWindow: NSWindow?

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
    hostWindow = window
    window.title = "Printroom · Export panel QA · synthetic input"
    window.appearance = NSAppearance(named: .aqua)
    // Host the production export sheet in an isolated window; a full EditorView
    // also presents export-result sheets and would race the next test scenario.
    window.contentView = NSView(frame: window.contentLayoutRect)
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
      try await exercise(name: name, initial: before,
        chosen: .init(profile: .sRGB, compression: .none), confirm: false, entry: entry)
      try require(model.exportSettings == before, "\(name): cancel changed in-memory preferences")
      try require(try Data(contentsOf: roll.appendingPathComponent(ProjectStore.filename)) == sidecar,
        "\(name): cancel wrote project")
      try require(!model.isExporting && model.exportSummary == nil, "\(name): cancel started an export")
      try require(try fm.contentsOfDirectory(atPath: exports.path).isEmpty, "\(name): cancel created output")
      record("PASS \(name): independent settings sheet visible; 5 ICC × 2 ZIP states; cancel preserves project bytes and creates no export")
    }

    model.select(frames[1].id)
    model.select(frames[0].id, command: true)
    let confirms: [(String, ProjectExportSettings, Set<UUID>, () -> Void)] = [
      ("04-current-display-p3", .init(profile: .displayP3, compression: .none), [frames[1].id], { self.model.exportPanel() }),
      ("05-current-srgb", .init(profile: .sRGB, compression: .deflate), [frames[1].id], { self.model.exportPanel() }),
      ("06-selected-adobe", .init(profile: .adobeRGB, compression: .none), selectedIDs,
        { self.model.batchExportPanel(allFrames: false) }),
      ("07-roll-prophoto", .init(profile: .proPhoto, compression: .deflate), Set(frames.map(\.id)),
        { self.model.batchExportPanel(allFrames: true) }),
    ]
    for (name, choice, expectedIDs, entry) in confirms {
      window.appearance = NSAppearance(named: name == "06-selected-adobe" ? .darkAqua : .aqua)
      var settings = choice
      settings.destinationPath = exports.path
      settings.filenamePrefix = name
      // Wait for the settings sheet dismissal before the next scenario.
      try await Task.sleep(for: .milliseconds(400))
      try await wait("previous sheet dismissed", until: { window.attachedSheet == nil })
      NSApp.activate(ignoringOtherApps: true)
      window.makeKeyAndOrderFront(nil)
      try await wait("host window key", until: { NSApp.keyWindow === window })
      try await exercise(name: name, initial: model.exportSettings,
        chosen: settings, confirm: true, entry: entry)
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
        let rollNumber = frames.firstIndex { $0.id == result.id }! + 1
        try require(url.lastPathComponent == name + String(format: "-%02d.tiff", rollNumber),
          "Original roll number must survive subset export")
        try verifyTIFF(url, settings: settings, p3: assets.profile)
        record("READBACK \(url.lastPathComponent): \(settings.profile.label), compression=\(settings.compression.rawValue), RGB 16-bit, exact ICC bytes, 24×16")
      }
      record("PASS \(name): native dialog confirmation → persisted settings → existing export snapshot; \(expectedIDs.count) frames")
    }
    for (url, original) in originals {
      try require(try Data(contentsOf: url) == original, "Synthetic source changed: \(url.lastPathComponent)")
    }
    try require(try fm.contentsOfDirectory(atPath: exports.path).filter { $0.hasSuffix(".tiff") }.count == 7,
      "Expected 7 distinct exports with original roll numbering")
    model.select(frames[2].id)
    var extra = ProjectExportSettings()
    extra.destinationPath = exports.path
    extra.filenamePrefix = "08-cancel-running"
    try await exercise(name: extra.filenamePrefix!, initial: model.exportSettings, chosen: extra,
      confirm: true, cancelRunning: true, expectedResult: "导出已取消", entry: { self.model.exportPanel() })
    try require(model.exportSummary?.wasCancelled == true, "Running cancellation missing")
    try require(model.exportSummary?.completedCount == 0, "Immediate cancellation wrote files")
    let missing = roll.appendingPathComponent(frames[2].filename)
    let original = try Data(contentsOf: missing)
    let originalAttributes = try fm.attributesOfItem(atPath: missing.path)
    try fm.removeItem(at: missing)
    defer {
      try? original.write(to: missing)
      try? fm.setAttributes([.modificationDate: originalAttributes[.modificationDate]!], ofItemAtPath: missing.path)
    }
    extra.filenamePrefix = "09-failed-source"
    try await exercise(name: extra.filenamePrefix!, initial: model.exportSettings, chosen: extra,
      confirm: true, expectedResult: "导出失败", entry: { self.model.exportPanel() })
    try require(model.exportSummary?.failedCount == 1, "Missing source must fail")
    try require(model.errorMessage == nil, "Export failure must stay inline")
    try original.write(to: missing)
    try fm.setAttributes([.modificationDate: originalAttributes[.modificationDate]!], ofItemAtPath: missing.path)
    extra.filenamePrefix = "10-jpeg"
    extra.format = .jpeg
    window.appearance = NSAppearance(named: .darkAqua)
    try await exercise(name: extra.filenamePrefix!, initial: model.exportSettings, chosen: extra,
      confirm: true, entry: { self.model.exportPanel() })
    let jpeg = try requireJPEG()
    try require(jpeg.bitsPerComponent == 8 && jpeg.width == 24 && jpeg.height == 16, "JPG readback")
    record("PASS: same-sheet progress/result in light and dark, 3 draft cancels, 4 TIFF successes, running cancel, inline failure, JPG success; no result sheet")
  }

  func exercise(name: String, initial: ProjectExportSettings, chosen: ProjectExportSettings,
    confirm: Bool, cancelRunning: Bool = false, expectedResult: String = "导出成功", entry: () -> Void
  ) async throws {
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    func presentedOptions() -> ExportOptionsView? {
      NSApp.windows.filter { $0.isVisible && $0.sheetParent != nil }.compactMap { window in
        window.contentView.flatMap { descendants($0).compactMap { $0 as? ExportOptionsView }.first }
      }.first
    }
    NSApp.activate(ignoringOtherApps: true)
    hostWindow?.makeKeyAndOrderFront(nil)
    try await wait("host window key", until: { NSApp.keyWindow === self.hostWindow })
    try require(NSApp.keyWindow != nil, "Export sheet requires a key host window")
    entry()
    try await wait("\(name) settings sheet", until: { presentedOptions() != nil })
    guard let options = presentedOptions(), let panel = options.window, let content = panel.contentView else {
      throw QAError("Settings sheet unavailable")
    }
    content.layoutSubtreeIfNeeded()
    try require(options.settings == initial, "\(name): saved options not restored")
    try require(options.filenamePrefix == (initial.filenamePrefix ?? "roll"), "Saved/default prefix")
    for control in [options.profilePopUp, options.compressionCheckbox, options.applyCropCheckbox] as [NSView] {
      try require(!control.isHiddenOrHasHiddenAncestor && !control.visibleRect.isEmpty,
        "\(name): option control clipped/hidden")
    }
    try require(options.profilePopUp.itemTitles == OutputColorProfile.selectable.map(\.label), "Five ICC choices")
    for index in OutputColorProfile.selectable.indices {
      for compression in TIFFCompression.allCases {
        options.profilePopUp.selectItem(at: index)
        options.compressionCheckbox.state = compression == .deflate ? .on : .off
        try require(options.settings.profile == OutputColorProfile.selectable[index]
          && options.settings.compression == compression, "Option selection mapping")
      }
    }
    options.applyCropCheckbox.performClick(nil)
    try require(options.settings.applyCrop != initial.applyCrop, "Crop checkbox mapping")
    options.applyCropCheckbox.state = chosen.applyCrop ? .on : .off
    options.profilePopUp.selectItem(at: OutputColorProfile.selectable.firstIndex(of: chosen.profile)!)
    options.compressionCheckbox.state = chosen.compression == .deflate ? .on : .off
    options.formatPopUp.selectItem(at: chosen.format == .tiff ? 0 : 1)
    options.formatChanged()
    // Set a disposable destination directly; folder chooser interaction is separate QA.
    options.destinationURL = output.appendingPathComponent("roll/Printroom Exports")
    options.prefixField.stringValue = name
    options.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: options.prefixField))
    options.refreshValidity()
    if confirm { try require(options.settings == chosen, "\(name): draft settings mismatch") }
    try capture(panel, name: name)
    let title = confirm ? "导出" : "取消"
    guard let button = descendants(content).compactMap({ $0 as? NSButton }).first(where: { $0.title == title }) else {
      throw QAError("Missing sheet button: \(title)")
    }
    try require(button.isEnabled, "Sheet button disabled")
    button.performClick(nil)
    if confirm {
      try require(panel.sheetParent != nil && model.isExporting, "Export must keep the original sheet open")
      try require(!options.prefixField.isEnabled && !options.formatPopUp.isEnabled
        && !options.profilePopUp.isEnabled && !options.applyCropCheckbox.isEnabled,
        "Running export settings must be locked")
      try require(!options.progressIndicator.isHiddenOrHasHiddenAncestor, "Inline progress must be visible")
      content.layoutSubtreeIfNeeded()
      try require(!options.progressIndicator.visibleRect.isEmpty && !options.statusField.visibleRect.isEmpty,
        "Inline progress must not be clipped")
      try capture(panel, name: name + "-running")
      if cancelRunning {
        guard let cancel = descendants(content).compactMap({ $0 as? NSButton }).first(where: { $0.title == "取消导出" }) else {
          throw QAError("Missing running cancel button")
        }
        cancel.performClick(nil)
        try require(!cancel.isEnabled && panel.sheetParent != nil, "Cancellation must wait in the original sheet")
      }
      try await wait("\(name) export complete", until: { !self.model.isExporting })
      try require(panel.sheetParent != nil, "Result must stay in the original sheet")
      try require(options.statusField.stringValue.hasPrefix(expectedResult), "Inline result message missing: \(options.statusField.stringValue)")
      try require(options.progressIndicator.isHidden, "Completed export still shows progress")
      try capture(panel, name: name + "-result")
      guard let close = descendants(content).compactMap({ $0 as? NSButton }).first(where: { $0.title == "关闭" }) else {
        throw QAError("Missing inline result close button")
      }
      close.performClick(nil)
      try await wait("\(name) settings commit", until: { self.model.exportSettings == chosen })
    }
    try await wait("\(name) dismiss", until: { panel.sheetParent == nil && !self.model.showExportDialog })
    record("DIALOG \(name): actual settings sheet and \(title) action; destination assigned to synthetic fixture")
  }

  func capture(_ window: NSWindow, name: String) throws {
    window.displayIfNeeded()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", "-o", "-l", String(window.windowNumber), output.appendingPathComponent(name + ".png").path]
    try process.run()
    process.waitUntilExit()
    try require(process.terminationStatus == 0, "Native sheet screenshot failed")
  }

  func requireJPEG() throws -> CGImage {
    guard let url = model.exportSummary?.results.first?.destination,
      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw QAError("JPG readback failed") }
    return image
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
