import AppKit
import PrintroomCore
import SwiftUI

// Default: layout captures with an in-memory project, without activation.
// --keyboard: a disposable synthetic TIFF roll and queued events in our window.
@main struct EditorWindowQA {
  struct KeyboardBlocked: LocalizedError {
    let detail: String
    var errorDescription: String? { detail }
  }
  @MainActor static func main() {
    setbuf(stdout, nil)
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    app.finishLaunching()
    Task { @MainActor in
      do { try await run() }
      catch let error as KeyboardBlocked {
        print("EDITOR KEYBOARD QA BLOCKED: \(error.localizedDescription)")
        exit(3)
      }
      catch { print("EDITOR UI QA FAILED: \(error)"); exit(1) }
      app.terminate(nil)
    }
    app.run()
  }
  @MainActor static func run() async throws {
    if CommandLine.arguments.contains("--keyboard") {
      try await keyboard()
      return
    }
    AppAppearance.dark.apply()
    let recentSuite = "Printroom.RecentWindowQA.\(UUID())"
    let recentDefaults = UserDefaults(suiteName: recentSuite)!
    defer { recentDefaults.removePersistentDomain(forName: recentSuite) }
    let history = RecentRolls(defaults: recentDefaults)
    let model = EditorModel(recentRolls: history, timingDefaults: recentDefaults)
    model.errorMessage = nil
    let frames = (1...(CommandLine.arguments.contains("--scrollbars") ? 40 : 4)).map {
      FrameRecord(filename: "frame-\($0).tiff")
    }
    var project = RollProject()
    project.frames = frames
    if CommandLine.arguments.contains("--roll-name") || CommandLine.arguments.contains("--toolbar-alignment") {
      project.name = "京都 · Kodak 250D · 第 12 卷"
    }
    model.project = project
    model.selection.click(frames[0].id, ordered: frames.map(\.id))
    model.sourceWidth = 1200
    model.sourceHeight = 800
    var pixels: [SIMD4<Float>] = []
    for y in 0..<400 {
      for x in 0..<600 {
        let value = Float(x + y) / 1000
        pixels.append(SIMD4<Float>(value * 0.75 + 0.1, value * 0.8 + 0.15, value * 0.65 + 0.2, 1))
      }
    }
    let buffer = PixelBuffer(width: 600, height: 400, pixels: pixels)
    let preview = try DisplayImage.make(buffer, profile: nil, diagnostic: true)
    model.previewImage = preview
    model.histogram = try HistogramStatistics.compute(buffer, stage: .final)
    for frame in frames { model.thumbnails[frame.id] = preview }
    let window = NSWindow(contentRect: CGRect(x: 80, y: 70, width: 1060, height: 720),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = "Printroom · UI QA"
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.toolbarStyle = .unified
    let histogramDefaults = UserDefaults(suiteName: "Printroom.EditorWindowQA.\(UUID())")!
    histogramDefaults.set(true, forKey: "histogramExpanded")
    let controller = NSHostingController(rootView: EditorView(model: model).defaultAppStorage(histogramDefaults))
    window.contentViewController = controller
    let host = controller.view
    window.orderFront(nil)
    defer { window.orderOut(nil) }
    func capture(_ name: String) async throws {
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(350))
      if CommandLine.arguments.contains("--appearance") {
        // Include the real AppKit titlebar and traffic lights, not just SwiftUI content.
        let host = window.contentView?.superview ?? host
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
          throw PrintroomError.invalid("Offscreen bitmap unavailable")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
          throw PrintroomError.invalid("Offscreen PNG unavailable")
        }
        try png.write(to: URL(fileURLWithPath: "scratch/editor-ui-qa/\(name).png"))
        print("Rendered \(name): \(host.bounds.size)")
        return
      }
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
      process.arguments = ["-x", "-o", "-l", String(window.windowNumber),
        "scratch/editor-ui-qa/\(name).png"]
      try process.run()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else { throw PrintroomError.invalid("Screenshot failed") }
      print("Saved \(name): \(host.bounds.size)")
    }
    if CommandLine.arguments.contains("--toolbar-alignment") {
      for appearance in [AppAppearance.light, .dark] {
        appearance.apply()
        for width in [1060, 1360, 1800, 1060] {
          window.setContentSize(NSSize(width: width, height: 720))
          try await capture("toolbar-right-\(appearance.rawValue)-\(width)")
          guard let item = window.toolbar?.items.first(where: {
            $0.itemIdentifier.rawValue.contains("printroom-actions")
          }), let view = item.view else {
            let identifiers = window.toolbar?.items.map { $0.itemIdentifier.rawValue } ?? []
            throw PrintroomError.invalid("Toolbar action item missing: \(identifiers)")
          }
          let rect = view.convert(view.bounds, to: nil)
          let trailing = window.contentLayoutRect.width - rect.maxX
          print("TOOLBAR ALIGNMENT: width=\(width) actions=\(rect) trailing=\(trailing)")
          guard trailing >= 0, trailing <= 28 else {
            throw PrintroomError.invalid("Toolbar actions are not right-aligned: trailing=\(trailing)")
          }
        }
        model.project = nil
        model.previewImage = nil
        try await capture("toolbar-right-home-\(appearance.rawValue)")
        model.project = project
        model.previewImage = preview
      }
      print("TOOLBAR ALIGNMENT QA PASS: light/dark, 1060/1360/1800/1060 resize and home")
      return
    }
    if CommandLine.arguments.contains("--film-base") {
      let directory = URL(fileURLWithPath: "scratch/editor-ui-qa/film-base-\(UUID())", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      defer { model.returnHome(); try? FileManager.default.removeItem(at: directory) }
      let assets = model.assets!
      for index in 0..<2 {
        try TIFFCodec.write(url: directory.appendingPathComponent("frame-\(index).tif"),
          width: 600, height: 400, profile: assets.profile) { rows in
          var samples: [UInt16] = []
          samples.reserveCapacity(rows.count * 600 * 3)
          for y in rows { for x in 0..<600 {
            samples.append(UInt16(14000 + x * 30))
            samples.append(UInt16(26000 + y * 30))
            samples.append(UInt16(36000 + x * 20))
          } }
          return samples
        }
      }
      func ready(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !predicate(), ContinuousClock.now < deadline {
          try await Task.sleep(for: .milliseconds(20))
        }
        guard predicate() else { throw PrintroomError.invalid("Film base QA timed out") }
      }
      func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
      // This branch checks film-base dialogs on an existing roll; onboarding is covered by --roll-name.
      try ProjectStore.save(try ProjectStore.open(folder: directory), folder: directory, expectedModification: nil)
      model.open(directory)
      try await ready { model.hasImage && !model.isRendering && model.thumbnails.count == 2 }
      model.project?.name = "片基预览 QA"
      guard !model.hasFilmBase, model.histogram == nil, !model.canPickNeutral else {
        throw PrintroomError.invalid("New roll must remain in original mode")
      }
      for appearance in [AppAppearance.light, .dark] {
        appearance.apply()
        try await capture("film-base-original-\(appearance.rawValue)")
        model.showMissingFilmBaseDialog = true
        try await ready { window.attachedSheet != nil }
        let content = window.attachedSheet!.contentView!
        content.layoutSubtreeIfNeeded()
        let buttons = descendants(content).compactMap { $0 as? NSButton }
        guard let select = buttons.first(where: { $0.title == "框选片基" }),
          let cancel = buttons.first(where: { $0.title == "取消" }), select.isEnabled,
          descendants(content).compactMap({ ($0 as? NSTextField)?.stringValue }).contains("未框选片基") else {
          throw PrintroomError.invalid("Missing film-base native dialog text or buttons")
        }
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
          throw PrintroomError.invalid("Cannot capture film-base dialog")
        }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(
          to: URL(fileURLWithPath: "scratch/editor-ui-qa/film-base-missing-\(appearance.rawValue).png"))
        let screenCapture = Process()
        screenCapture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        screenCapture.arguments = ["-x", "-o", "-l", String(window.attachedSheet!.windowNumber),
          "scratch/editor-ui-qa/film-base-missing-\(appearance.rawValue)-screen.png"]
        try screenCapture.run()
        screenCapture.waitUntilExit()
        guard screenCapture.terminationStatus == 0 else {
          throw PrintroomError.invalid("Cannot capture the composed native film-base dialog")
        }
        cancel.performClick(nil)
        try await ready { window.attachedSheet == nil }
        guard !model.sampling && !model.hasFilmBase else {
          throw PrintroomError.invalid("Cancel changed film-base state")
        }
        model.showMissingFilmBaseDialog = true
        try await ready { window.attachedSheet != nil }
        guard let primary = descendants(window.attachedSheet!.contentView!).compactMap({ $0 as? NSButton })
          .first(where: { $0.title == "框选片基" }) else {
          throw PrintroomError.invalid("Missing selection button")
        }
        primary.performClick(nil)
        try await ready { window.attachedSheet == nil && model.sampling }
        try await capture("film-base-selection-\(appearance.rawValue)")
        model.sampling = false
      }
      model.sampleBase(.init(x: 520, y: 320, width: 40, height: 40))
      try await ready { model.hasFilmBase && !model.isRendering && model.histogram != nil }
      for appearance in [AppAppearance.light, .dark] {
        appearance.apply()
        try await capture("film-base-calibrated-\(appearance.rawValue)")
      }
      guard !model.showRollTimingDialog && model.canStartRollTiming else {
        throw PrintroomError.invalid("Selection must enable analysis without starting it")
      }
      print("FILM BASE QA PASS: original/selection/calibrated in light and dark; native Cancel/Select buttons")
      return
    }
    if CommandLine.arguments.contains("--sprocket") {
      let assets = model.assets!
      let crop = FrameCrop(aspect: .threeTwo, width: 0.75)
      var calibration = FilmCalibration()
      calibration.baseRGB = SIMD3(repeating: 0.2)
      calibration.gainRGB = SIMD3(repeating: 3.75)
      calibration = try Pipeline.recalibrate(calibration, matrix: .identity)
      model.project?.calibration = calibration
      for i in frames.indices { model.project?.frames[i].crop = crop }
      model.cropPreviewEnabled = false
      var raw: [SIMD4<Float>] = []
      for y in 0..<400 {
        for x in 0..<600 {
          let interior = (75..<525).contains(x) && (50..<350).contains(y)
          let hole = ((24..<47).contains(x) || (553..<576).contains(x)) && (y % 60 >= 15 && y % 60 <= 40)
          let v: Float = hole ? 0.9 : interior ? 0.045 + Float(x + y) / 6000 : 0.2
          raw.append(SIMD4(v, v, v, 1))
        }
      }
      let input = PixelBuffer(width: 600, height: 400, pixels: raw)
      let renderer = PreviewRenderService()
      for theme in [AppAppearance.dark, .light] {
        theme.apply()
        for enabled in [false, true] {
          let settings = SprocketWhiteningSettings(enabled: enabled)
          model.project?.sprocketWhitening = settings
          let image = try await renderer.render(input, calibration: calibration, adjustments: .init(), assets: assets,
            sourceWidth: 1200, sourceHeight: 800, sprocketWhitening: settings, protectedCrop: crop)
          model.previewImage = image.image
          try await capture("sprocket-\(theme.rawValue)-\(enabled)")
        }
        let controls = NSHostingController(rootView: SprocketWhiteningControlsView(model: model)
          .foregroundStyle(InterfaceColors.primaryText).tint(InterfaceColors.accent)
          .background(InterfaceColors.secondaryPanel))
        let panel = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 326, height: 206),
          styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentViewController = controls
        panel.orderFront(nil)
        try await Task.sleep(for: .milliseconds(250))
        let view = controls.view
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
          throw PrintroomError.invalid("Sprocket controls bitmap unavailable")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to:
          URL(fileURLWithPath: "scratch/editor-ui-qa/sprocket-controls-\(theme.rawValue).png"))
        panel.orderOut(nil)
      }
      return
    }
    if CommandLine.arguments.contains("--crop-preview") {
      for appearance in [AppAppearance.dark, .light] {
        appearance.apply()
        for enabled in [true, false] {
          model.cropPreviewEnabled = enabled
          try await capture("crop-preview-\(appearance.rawValue)-\(enabled)")
        }
      }
      return
    }
    if CommandLine.arguments.contains("--roll-name") {
      for appearance in [AppAppearance.dark, .light] {
        appearance.apply()
        for width in [1060, 1360] {
          window.setContentSize(NSSize(width: width, height: 720))
          try await capture("roll-name-\(appearance.rawValue)-\(width)")
        }
      }
      func ready(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !predicate(), ContinuousClock.now < deadline {
          try await Task.sleep(for: .milliseconds(20))
        }
        guard predicate() else { throw PrintroomError.invalid("Roll naming QA timed out") }
      }
      func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
      NSApp.activate(ignoringOtherApps: true)
      window.makeKeyAndOrderFront(nil)
      window.setContentSize(NSSize(width: 1060, height: 720))
      for appearance in [AppAppearance.light, .dark] {
        appearance.apply()
        let directory = URL(fileURLWithPath: "scratch/editor-ui-qa/roll-name-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { model.returnHome(); try? FileManager.default.removeItem(at: directory) }
        try TIFFCodec.write(url: directory.appendingPathComponent("frame.tiff"),
          width: 8, height: 6, profile: nil) { rows in
          Array(repeating: UInt16(32768), count: rows.count * 8 * 3)
        }
        model.open(directory)
        try await ready { window.attachedSheet != nil }
        guard let content = window.attachedSheet?.contentView else {
          throw PrintroomError.invalid("New roll naming sheet missing")
        }
        let views = descendants(content)
        guard views.compactMap({ ($0 as? NSTextField)?.stringValue }).contains("命名胶卷"),
          let field = views.compactMap({ $0 as? NSTextField }).first(where: { $0.isEditable }),
          let save = views.compactMap({ $0 as? NSButton }).first(where: { $0.title == "保存" }),
          let cancel = views.compactMap({ $0 as? NSButton }).first(where: { $0.title == "取消" }) else {
          throw PrintroomError.invalid("New roll naming controls missing")
        }
        content.layoutSubtreeIfNeeded()
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
          throw PrintroomError.invalid("Cannot capture naming sheet")
        }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to:
          URL(fileURLWithPath: "scratch/editor-ui-qa/roll-name-dialog-\(appearance.rawValue).png"))
        let screenCapture = Process()
        screenCapture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        screenCapture.arguments = ["-x", "-o", "-l", String(window.attachedSheet!.windowNumber),
          "scratch/editor-ui-qa/roll-name-dialog-\(appearance.rawValue)-screen.png"]
        try screenCapture.run()
        screenCapture.waitUntilExit()
        guard screenCapture.terminationStatus == 0 else {
          throw PrintroomError.invalid("Cannot capture composed naming sheet")
        }
        if appearance == .light {
          field.stringValue = "新卷命名 QA"
          save.performClick(nil)
        } else { cancel.performClick(nil) }
        try await ready { window.attachedSheet == nil && model.hasImage }
        let expectedName: String? = appearance == .light ? "新卷命名 QA" : nil
        guard try ProjectStore.open(folder: directory).name == expectedName,
          model.newRollNamingID == nil, model.project?.name == expectedName else {
          throw PrintroomError.invalid("New roll naming save/cancel did not persist correctly")
        }
        try await capture("roll-name-after-dialog-\(appearance.rawValue)")
        model.returnHome()
        model.open(directory)
        try await ready { model.hasImage && !model.isImporting }
        try await Task.sleep(for: .milliseconds(350))
        guard window.attachedSheet == nil, model.newRollNamingID == nil else {
          throw PrintroomError.invalid("Saved roll unexpectedly prompted for a name")
        }
        if appearance == .dark {
          model.openRollFolderInFinder()
          guard model.errorMessage == nil else {
            throw PrintroomError.invalid(model.errorMessage ?? "Finder could not open the roll folder")
          }
        }
      }
      try await capture("roll-name-home-dark")
      print("ROLL NAMING QA PASS: filmstrip at two widths/themes; automatic new-roll sheet; Save/Cancel; no prompt on reopen; Finder accepted roll folder")
      return
    }
    if CommandLine.arguments.contains("--themes") {
      NSApp.activate(ignoringOtherApps: true)
      window.makeKeyAndOrderFront(nil)
      for theme in [AppAppearance.light, .dark, .light] {
        theme.apply()
        try await capture("theme-\(theme.rawValue)-editor")
        model.saveFailure = true
        model.isExporting = true
        model.exportProgress = 0.42
        model.exportDetail = "2/4 · frame.tiff"
        try await capture("theme-\(theme.rawValue)-without-status-row")
        model.isExporting = false
        model.saveFailure = false
        model.timingMode = .rgb
        try await capture("theme-\(theme.rawValue)-rgb")
        model.timingMode = .simple
        model.beginCrop()
        try await capture("theme-\(theme.rawValue)-crop")
        model.project?.frames[0].cropNeedsReview = true
        try await capture("theme-\(theme.rawValue)-crop-review")
        model.project?.frames[0].cropNeedsReview = false
        model.cancelCrop()
        let savedProject = model.project
        model.project = nil
        model.previewImage = nil
        try await capture("theme-\(theme.rawValue)-home")
        model.project = savedProject
        model.previewImage = preview
      }
      print("THEME QA PASSED: live light/dark/light in the same window")
      if CommandLine.arguments.contains("--window-chrome") {
        guard window.toolbar != nil, window.titleVisibility == .hidden,
          window.styleMask.contains([.titled, .closable, .miniaturizable, .resizable]), window.isMovable,
          let close = window.standardWindowButton(.closeButton),
          let mini = window.standardWindowButton(.miniaturizeButton),
          let zoom = window.standardWindowButton(.zoomButton),
          !close.isHidden, !mini.isHidden, !zoom.isHidden else {
          throw PrintroomError.invalid("Native window chrome missing")
        }
        print("CHROME: native buttons present; title hidden; movable/resizable; toolbar style \(window.toolbarStyle.rawValue)")
        let original = window.frame
        window.setContentSize(NSSize(width: 1360, height: 900))
        try await capture("unified-large")
        window.setFrame(original, display: true)
        window.performMiniaturize(nil)
        try await Task.sleep(for: .milliseconds(900))
        guard window.isMiniaturized else { throw PrintroomError.invalid("Miniaturize failed") }
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(900))
        guard !window.isMiniaturized else { throw PrintroomError.invalid("Restore failed") }
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.toggleFullScreen(nil)
        try await Task.sleep(for: .seconds(3))
        guard window.styleMask.contains(.fullScreen) else { throw PrintroomError.invalid("Fullscreen entry failed") }
        try await capture("unified-fullscreen")
        // AppKit reparents fullscreen toolbar items into a separate titlebar window.
        // Inspect/capture that owned window as well; the main bitmap omits its controls.
        let itemWindows = window.toolbar?.items.compactMap { $0.view?.window } ?? []
        var captured = Set<Int>()
        for itemWindow in itemWindows where itemWindow !== window && captured.insert(itemWindow.windowNumber).inserted {
          print("FULLSCREEN TOOLBAR: visible=\(itemWindow.isVisible), frame=\(itemWindow.frame)")
          if let view = itemWindow.contentView?.superview,
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to:
              URL(fileURLWithPath: "scratch/editor-ui-qa/unified-fullscreen-toolbar.png"))
          }
        }
        window.toggleFullScreen(nil)
        try await Task.sleep(for: .seconds(3))
        guard !window.styleMask.contains(.fullScreen) else { throw PrintroomError.invalid("Fullscreen exit failed") }
        try await capture("unified-restored")
        print("WINDOW CHROME QA PASSED: resize, native minimize/restore, fullscreen/restore")
      }
      return
    }
    if CommandLine.arguments.contains("--loading") {
      model.project = nil
      let folder = URL(fileURLWithPath: "scratch/editor-ui-qa/loading-\(UUID())")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      defer { model.cancelImport(); try? FileManager.default.removeItem(at: folder) }
      for index in 0..<8 { try Data([1]).write(to: folder.appendingPathComponent("\(index).ARW")) }
      model.proxyLoader = { url in
        if url.lastPathComponent == "0.ARW" { return }
        while !Task.isCancelled { Thread.sleep(forTimeInterval: 0.01) }
        throw CancellationError()
      }
      model.open(folder)
      try await Task.sleep(for: .milliseconds(200))
      try await capture("0353-loading")
      model.cancelImport()
      model.proxyLoader = { _ in throw PrintroomError.invalid("代理读取失败，请重试") }
      model.open(folder)
      try await Task.sleep(for: .milliseconds(200))
      try await capture("0353-loading-failed")
      print("Loading page QA complete")
      return
    }
    if CommandLine.arguments.contains("--export-layout") {
      try await capture("0352-toolbar")
      for format in ExportFormat.allCases {
        var settings = ProjectExportSettings()
        settings.format = format
        let options = ExportOptionsView(settings: settings)
        let optionsWindow = NSWindow(contentRect: options.frame, styleMask: [.titled], backing: .buffered, defer: false)
        optionsWindow.appearance = NSAppearance(named: .aqua)
        options.wantsLayer = true
        options.layer?.backgroundColor = NSColor.white.cgColor
        optionsWindow.contentView = options
        optionsWindow.orderFront(nil)
        options.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        guard let bitmap = options.bitmapImageRepForCachingDisplay(in: options.bounds) else {
          throw PrintroomError.invalid("Export options bitmap unavailable")
        }
        options.cacheDisplay(in: options.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to:
          URL(fileURLWithPath: "scratch/editor-ui-qa/0352-export-\(format.rawValue).png"))
        optionsWindow.orderOut(nil)
      }
      model.project = nil
      try await capture("0352-home")
      return
    }
    if CommandLine.arguments.contains("--roll-timing") {
      try await capture("roll-timing-entry")
      let directory = URL(fileURLWithPath: "scratch/editor-ui-qa/roll-timing-\(UUID())", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let assets = model.assets!
      let url = directory.appendingPathComponent("sample.tif")
      try TIFFCodec.write(url: url, width: 16, height: 16, profile: assets.profile) {
        [UInt16](repeating: 32000, count: $0.count * 16 * 3)
      }
      var roll = try ProjectStore.open(folder: directory)
      roll.calibration = try Pipeline.calibrate(image: LinearImage(width: 16, height: 16,
        samples: [UInt16](repeating: 32000, count: 16 * 16 * 3)),
        rect: .init(x: 0, y: 0, width: 4, height: 4), matrix: .identity,
        sourceFrameID: roll.frames[0].id)
      model.project = roll; model.folder = directory
      model.rollTimingRunner = { p, _, _, autoExposure, progress in
        await progress("分析 1/1")
        try await Task.sleep(for: .seconds(2))
        return RollTimingResult(timing: .init(red: 30, green: 20, blue: 10), sources: [],
          masters: autoExposure ? Dictionary(uniqueKeysWithValues: p.frames.map { ($0.id, 100) }) : [:])
      }
      model.startRollTiming()
      func sheetCapture(_ name: String) async throws {
        try await Task.sleep(for: .milliseconds(500))
        guard window.attachedSheet != nil else {
          throw PrintroomError.invalid("Missing automatic timing sheet")
        }
        guard let content = window.attachedSheet?.contentView else {
          throw PrintroomError.invalid("Missing native alert content")
        }
        content.layoutSubtreeIfNeeded()
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
          throw PrintroomError.invalid("Cannot render timing sheet")
        }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
          throw PrintroomError.invalid("Cannot capture timing sheet")
        }
        try data.write(to: URL(fileURLWithPath: "scratch/editor-ui-qa/\(name).png"))
        print("Saved \(name)")
      }
      try await sheetCapture("roll-timing-progress")
      while model.isAnalyzingRollTiming { try await Task.sleep(for: .milliseconds(100)) }
      try await sheetCapture("roll-timing-result")
      model.cancelRollTiming()
      return
    }
    if CommandLine.arguments.contains("--scrollbars") {
      func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
      model.selectAll()
      for size in [NSSize(width: 1060, height: 720), NSSize(width: 1440, height: 900)] {
        window.setContentSize(size)
        try await capture("scrollbars-\(Int(size.width))")
        let scrolls = descendants(host).compactMap { $0 as? NSScrollView }
        guard let strip = scrolls.first(where: { $0.bounds.width > 800 && $0.bounds.height < 200 }),
          let inspector = scrolls.first(where: { $0.bounds.width < 400 && $0.bounds.height > 250 }),
          let document = strip.documentView else {
          throw PrintroomError.invalid("Missing editor scroll views")
        }
        for scroll in [strip, inspector] {
          guard scroll.scrollerStyle == .overlay, scroll.autohidesScrollers else {
            throw PrintroomError.invalid("Editor scrollbar does not auto-hide as overlay")
          }
        }
        guard document.bounds.height <= strip.contentView.bounds.height + 0.5 else {
          throw PrintroomError.invalid("Filmstrip content clipped: \(document.bounds), viewport \(strip.contentView.bounds)")
        }
        document.scroll(NSPoint(x: 500, y: 0))
        strip.reflectScrolledClipView(strip.contentView)
        guard strip.contentView.bounds.minX > 0 else {
          throw PrintroomError.invalid("Filmstrip cannot scroll horizontally")
        }
        if let panel = inspector.documentView {
          let end = max(0, panel.bounds.height - inspector.contentView.bounds.height)
          panel.scroll(NSPoint(x: 0, y: panel.isFlipped ? end : 0))
          inspector.reflectScrolledClipView(inspector.contentView)
        }
        try await Task.sleep(for: .seconds(2))
        try await capture("scrollbars-idle-\(Int(size.width))")
        print("PASS: \(host.bounds.size), overlay auto-hide; filmstrip content \(document.bounds.height) <= viewport \(strip.contentView.bounds.height); horizontal scrolling")
      }
      return
    }
    if CommandLine.arguments.contains("--histogram") {
      let portrait = try FrameOrientation.identity.applying(.rotateClockwise).transform(buffer)
      model.thumbnails[frames[1].id] = try DisplayImage.make(portrait, profile: nil, diagnostic: true)
      func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
      try await Task.sleep(for: .milliseconds(500))
      host.layoutSubtreeIfNeeded()
      guard let canvas = descendants(host).compactMap({ $0 as? CanvasView }).first,
        let panel = descendants(host).compactMap({ $0 as? HistogramPointerView }).first else {
        throw PrintroomError.invalid("Missing cursor surfaces")
      }
      let previousPointer = NSEvent.mouseLocation
      let screenHeight = NSScreen.screens[0].frame.maxY
      defer { CGWarpMouseCursorPosition(CGPoint(x: previousPointer.x, y: screenHeight - previousPointer.y)) }
      func move(_ view: NSView, _ point: CGPoint, expected: NSCursor) async throws {
        let location = view.convert(point, to: nil)
        let screen = window.convertPoint(toScreen: location)
        CGWarpMouseCursorPosition(CGPoint(x: screen.x, y: screenHeight - screen.y))
        let event = NSEvent.mouseEvent(with: .mouseMoved, location: location, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
          context: nil, eventNumber: 1, clickCount: 0, pressure: 0)!
        NSApp.postEvent(event, atStart: false)
        try await Task.sleep(for: .milliseconds(250))
        canvas.refreshCursor()
        guard NSCursor.current === expected else {
          let hit = host.hitTest(host.convert(location, from: nil))
          throw PrintroomError.invalid("Unexpected cursor at \(point), key=\(window.isKeyWindow), hit=\(String(describing: hit)), image=\(model.previewImage != nil)")
        }
      }
      let center = CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
      try await move(canvas, center, expected: .arrow)
      try await move(panel, CGPoint(x: panel.bounds.midX, y: panel.bounds.midY), expected: .arrow)
      try await move(panel, CGPoint(x: panel.bounds.maxX - 14, y: panel.bounds.maxY - 18), expected: .arrow)
      try await move(canvas, center, expected: .arrow)
      print("PASS: actual pointer enters chart/header as arrow and exits as arrow")
      let hoverFolder = URL(fileURLWithPath: "scratch/editor-ui-qa/hover-roll-\(UUID())", isDirectory: true)
      try FileManager.default.createDirectory(at: hoverFolder, withIntermediateDirectories: true)
      try TIFFCodec.write(url: hoverFolder.appendingPathComponent("hover.tiff"),
        width: 600, height: 400, profile: model.assets!.profile) { rows in
        var samples: [UInt16] = []
        for y in rows {
          for x in 0..<600 {
            samples.append(UInt16(8000 + x * 45))
            samples.append(UInt16(12000 + y * 70))
            samples.append(UInt16(22000 + x * 25))
          }
        }
        return samples
      }
      try ProjectStore.save(try ProjectStore.open(folder: hoverFolder), folder: hoverFolder, expectedModification: nil)
      model.open(hoverFolder)
      func settleHover() async throws {
        let limit = ContinuousClock.now.advanced(by: .seconds(15))
        while (model.isLoading || model.isRendering || model.histogram == nil), ContinuousClock.now < limit {
          try await Task.sleep(for: .milliseconds(30))
        }
        guard model.histogram != nil else { throw PrintroomError.invalid("Hover preview unavailable") }
      }
      try await settleHover()
      try await move(canvas, center, expected: .arrow)
      canvas.refreshHistogramProbe()
      guard model.histogramProbe != nil else { throw PrintroomError.invalid("Missing Final hover marker") }
      try await capture("27-histogram-hover-final")
      model.histogramStage = .d3
      try await settleHover()
      canvas.refreshHistogramProbe()
      guard model.histogramProbe != nil else { throw PrintroomError.invalid("Missing Density hover marker") }
      try await capture("28-histogram-hover-density")
      try await move(panel, CGPoint(x: panel.bounds.midX, y: panel.bounds.midY), expected: .arrow)
      guard model.histogramProbe == nil else { throw PrintroomError.invalid("Hover marker leaked into panel") }
      try await move(canvas, center, expected: .arrow)
      func panEvent(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
          context: nil, eventNumber: 2, clickCount: 1, pressure: 1)!
      }
      canvas.mouseDown(with: panEvent(.leftMouseDown, center))
      canvas.mouseDragged(with: panEvent(.leftMouseDragged, CGPoint(x: center.x + 20, y: center.y + 20)))
      guard canvas.isPanning, NSCursor.current === NSCursor.closedHand, model.histogramProbe == nil else {
        throw PrintroomError.invalid("Pan must show closed hand and hide markers")
      }
      canvas.mouseUp(with: panEvent(.leftMouseUp, center))
      guard NSCursor.current === NSCursor.arrow, model.histogramProbe != nil else {
        throw PrintroomError.invalid("Release must restore arrow and markers")
      }
      print("PASS: Final/Density hover markers, panel exclusion, closed hand during pan and arrow on release")
      // 90% dark background, 10% subject spread over midtones. In-memory only.
      var nightPixels = [SIMD4<Float>](repeating: SIMD4<Float>(0, 0, 0, 1), count: 90_000)
      for i in 0..<10_000 {
        let v = Float(70 + i % 100) / 256
        nightPixels.append(SIMD4<Float>(v, v + 0.03, v + 0.06, 1))
      }
      let night = PixelBuffer(width: 400, height: 250, pixels: nightPixels)
      model.histogram = try HistogramStatistics.compute(night, stage: .final)
      try await capture("23-histogram-night-rgb")
      model.histogramStage = .d3
      model.stage = .d3
      model.histogram = try HistogramStatistics.compute(night, stage: .d3)
      try await capture("24-histogram-night-density")
      histogramDefaults.set(false, forKey: "histogramExpanded")
      try await capture("25-histogram-collapsed")
      histogramDefaults.set(true, forKey: "histogramExpanded")
      model.histogramStage = .final
      model.histogram = try HistogramStatistics.compute(night, stage: .final)
      try await capture("26-histogram-expanded-final")
      print("HISTOGRAM UI QA PASSED: Final and Density RGB layout, collapse and expand")
      return
    }
    if CommandLine.arguments.contains("--timing") {
      func sliders(_ view: NSView) -> [NSSlider] {
        (view as? NSSlider).map { [$0] } ?? view.subviews.flatMap { sliders($0) }
      }
      let before = model.project!.frames
      model.timingMode = .simple
      try await capture("20-timing-simple")
      func matrixMenus(_ view: NSView) -> [NSPopUpButton] {
        (view as? NSPopUpButton).map { [$0] } ?? view.subviews.flatMap { matrixMenus($0) }
      }
      let menus = matrixMenus(host).filter {
        ["CMOS 矩阵", "密度矩阵"].contains($0.accessibilityLabel() ?? "")
      }
      guard menus.count == 2,
        abs(menus[0].frame.width - menus[1].frame.width) < 1,
        abs(menus[0].convert(menus[0].bounds, to: host).minX
          - menus[1].convert(menus[1].bounds, to: host).minX) < 1,
        menus.allSatisfy({ $0.numberOfItems > 0 && $0.indexOfSelectedItem >= 0 }) else {
        throw PrintroomError.invalid("Matrix menus must align with equal widths and valid selections")
      }
      print("MATRIX LAYOUT PASSED: equal widths \(menus[0].frame.width), aligned, valid selections")
      let simple = sliders(host)
      guard simple.count == 7,
        let contrast = simple.first(where: { $0.accessibilityLabel() == "Contrast Master" }) else {
        throw PrintroomError.invalid("Expected three simple and four contrast sliders")
      }
      let contrastFrame = contrast.convert(contrast.bounds, to: host)
      model.timingMode = .rgb
      try await capture("21-timing-rgb")
      let rgb = sliders(host)
      guard rgb.count == 8,
        let rgbContrast = rgb.first(where: { $0.accessibilityLabel() == "Contrast Master" }),
        abs(rgbContrast.convert(rgbContrast.bounds, to: host).minY - contrastFrame.minY) < 1,
        model.project!.frames == before else {
        throw PrintroomError.invalid("Mode changed layout or photo parameters")
      }
      print("TIMING QA PASSED: 7/8 sliders, fixed Contrast position, unchanged photo parameters")
      return
    }
    if CommandLine.arguments.contains("--appearance") {
      try await capture("10-gray-preview")
      for (stage, name) in [(PipelineStage.l2, "15-toolbar-linear"), (.d3, "16-toolbar-density"), (.final, "17-toolbar-output")] {
        model.stage = stage
        model.previewImage = preview
        model.histogram = try HistogramStatistics.compute(buffer, stage: stage)
        try await capture(name)
      }
      histogramDefaults.set(false, forKey: "histogramExpanded")
      try await capture("11-histogram-collapsed")
      histogramDefaults.set(true, forKey: "histogramExpanded")
      try await capture("12-histogram-expanded")
      model.project = nil
      model.previewImage = nil
      model.histogram = nil
      try await capture("09-empty-state")
      for index in 1...8 {
        history.record(folder: URL(fileURLWithPath: "/Volumes/底片档案/2026/上海街头 · Kodak 5219 第\(index)卷"), projectID: UUID())
      }
      try await capture("13-recent-rolls")
      history.remove(history.entries[2])
      try await capture("14-recent-removed")
      return
    }
    model.selectAll()
    try await capture("01-final-minimum-window")
    func scrollViews(_ view: NSView) -> [NSScrollView] {
      (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews($0) }
    }
    guard let inspector = scrollViews(host).first(where: { $0.bounds.width < 400 && $0.bounds.height > 250 }),
      let document = inspector.documentView else { throw PrintroomError.invalid("Missing inspector scroll view") }
    document.scroll(NSPoint(x: 0, y: document.isFlipped ? max(0, document.bounds.height - inspector.contentView.bounds.height) : 0))
    inspector.reflectScrolledClipView(inspector.contentView)
    try await capture("22-cineon-log-lut")
    model.beginSync()
    try await capture("06-sync-minimum-window")
    for popup in NSApp.windows where popup !== window && popup.isVisible {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
      process.arguments = ["-x", "-o", "-l", String(popup.windowNumber),
        "scratch/editor-ui-qa/07-sync-popover-\(popup.windowNumber).png"]
      try process.run()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else { throw PrintroomError.invalid("Popover screenshot failed") }
    }
    guard !model.hasSyncSelection else { throw PrintroomError.invalid("Sync defaults must be empty") }
    model.showSync = false
    model.beginCrop()
    model.previewImage = preview
    try await capture("08-crop-without-sync")
    model.cancelCrop()
    model.stage = .d3
    model.previewImage = preview
    model.histogram = try HistogramStatistics.compute(buffer, stage: .d3)
    model.toggleNeutralPicker()
    try await capture("02-density-neutral-minimum-window")
    model.saveFailure = true
    model.isExporting = true
    model.exportProgress = 0.42
    model.exportDetail = "正在导出 frame-2.tiff · 2 / 4"
    try await capture("03-export-save-without-status-row-minimum-window")
    model.isExporting = false
    model.saveFailure = false
    model.project = nil
    model.previewImage = nil
    model.histogram = nil
    try await capture("09-empty-state")
  }

  @MainActor static func keyboard() async throws {
    let session = CGSessionCopyCurrentDictionary() as? [String: Any]
    let frontmost = NSWorkspace.shared.frontmostApplication
    let locked = session?["CGSSessionScreenIsLocked"] as? Bool == true
    let atLogin = frontmost?.bundleIdentifier == "com.apple.loginwindow"
    print("SESSION: frontmost=\(frontmost?.localizedName ?? "nil") locked=\(locked) onConsole=\(String(describing: session?["kCGSessionOnConsoleKey"]))")
    guard !locked, !atLogin else {
      throw KeyboardBlocked(detail: "会话处于登录或锁屏界面；未尝试激活窗口、未发送键鼠事件。解锁后运行 scripts/editor-window-qa.sh --release --skip-build --keyboard。")
    }
    let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("scratch/editor-ui-qa")
    let folder = output.appendingPathComponent("keyboard-roll-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let model = EditorModel()
    guard let assets = model.assets else {
      throw PrintroomError.invalid(model.errorMessage ?? "QA assets unavailable")
    }
    for frame in 1...3 {
      try TIFFCodec.write(url: folder.appendingPathComponent("frame-\(frame).tiff"),
        width: 120, height: 80, profile: assets.profile) { rows in
          var samples: [UInt16] = []
          for y in rows {
            for x in 0..<120 {
              let base = UInt16(15_000 + x * 120 + y * 100 + frame * 300)
              samples += [base, base + 1_200, base + 2_000]
            }
          }
          return samples
        }
    }
    let window = NSWindow(contentRect: CGRect(x: 80, y: 70, width: 1060, height: 720),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = "Printroom · Keyboard QA"
    let host = NSHostingView(rootView: EditorView(model: model))
    window.contentView = host
    defer { model.stopTimingKey(); _ = model.flushSave(); window.orderOut(nil) }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    try await Task.sleep(for: .milliseconds(1500))
    guard NSApp.isActive, window.isKeyWindow, window.isVisible, window.windowNumber > 0 else {
      throw KeyboardBlocked(detail: "一次激活后 QA 窗口未获得焦点；active=\(NSApp.isActive), key=\(window.isKeyWindow), visible=\(window.isVisible), windowNumber=\(window.windowNumber), frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil")。未发送键鼠事件，不继续尝试激活。")
    }
    try ProjectStore.save(try ProjectStore.open(folder: folder), folder: folder, expectedModification: nil)
    model.open(folder)
    func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
      guard condition() else { throw PrintroomError.invalid(message) }
    }
    func ready() async throws {
      for _ in 0..<100 {
        if let error = model.errorMessage { throw PrintroomError.invalid(error) }
        if model.hasImage && !model.isRendering && model.histogram != nil {
          host.layoutSubtreeIfNeeded()
          try await Task.sleep(for: .milliseconds(200))
          return
        }
        try await Task.sleep(for: .milliseconds(50))
      }
      throw PrintroomError.invalid("Keyboard QA preview timed out")
    }
    func requireFocus() throws {
      guard NSApp.isActive, window.isKeyWindow, window.isVisible else {
        throw KeyboardBlocked(detail: "QA 过程中窗口失去焦点；立即停止发送事件，不重新激活。")
      }
    }
    func press(_ characters: String, code: UInt16,
               modifiers: NSEvent.ModifierFlags = [], repeatKey: Bool = false) async throws {
      try requireFocus()
      for type in [NSEvent.EventType.keyDown, .keyUp] {
        guard let event = NSEvent.keyEvent(with: type, location: .zero,
          modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: window.windowNumber, context: nil, characters: characters,
          charactersIgnoringModifiers: characters, isARepeat: repeatKey, keyCode: code)
        else { throw PrintroomError.invalid("QA key event creation failed") }
        try require(event.window === window, "QA key event did not resolve to its own window")
        NSApp.postEvent(event, atStart: false)
      }
      try await Task.sleep(for: .milliseconds(180))
    }
    func click(windowPoint: CGPoint) async throws {
      try requireFocus()
      for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        guard let event = NSEvent.mouseEvent(with: type, location: windowPoint,
          modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: window.windowNumber, context: nil, eventNumber: 1,
          clickCount: 1, pressure: 1)
        else { throw PrintroomError.invalid("QA mouse event creation failed") }
        NSApp.postEvent(event, atStart: false)
      }
      try await Task.sleep(for: .milliseconds(250))
    }
    func descendants(_ view: NSView) -> [NSView] {
      [view] + view.subviews.flatMap(descendants)
    }
    try await ready()
    // SwiftUI does not always materialize an accessibility tree until a client
    // requests it. Use the actual layout and verify each click's model effect.
    let filmstripPoint = CGPoint(x: 220, y: host.isFlipped ? host.bounds.height - 75 : 75)
    try await click(windowPoint: host.convert(filmstripPoint, to: nil))
    try require(model.activeFrame?.filename == "frame-2.tiff", "Filmstrip click did not change the active frame")
    try await ready()
    try require(!(window.firstResponder is NSTextView), "Filmstrip click left a text editor focused")
    try await press("w", code: 13)
    try require(model.adjustments.timing.master == 1, "W after Filmstrip click must set Timing Master to 1")
    print("PASS: Filmstrip click → W sets Timing Master +1 CV")
    try await press("´", code: 14, modifiers: [.option])
    try require(abs(model.adjustments.contrast.red - 1.01) < 0.00001,
      "Option-E must set Contrast R to 1.01")
    try require(model.adjustments.timing.red == 0, "Option-E must preserve Timing R")
    print("PASS: Option-E dead-key event sets Contrast R +0.01")
    try await press("´", code: 14, modifiers: [.option, .shift])
    try require(abs(model.adjustments.contrast.red - 1.02) < 0.00001,
      "Option-Shift-E must increment Contrast R by only 0.01")
    print("PASS: Option-Shift-E also increments only 0.01")
    try await ready()
    guard let masterSlider = descendants(host).compactMap({ $0 as? ChannelSlider })
      .first(where: { $0.toolTip == "Color Timing Master" }) else {
      throw PrintroomError.invalid("QA Color Timing Master native slider missing")
    }
    let masterFrame = masterSlider.convert(masterSlider.bounds, to: nil)
    // The value field sits 16 px from the inspector edge, with a 56 px width.
    try await click(windowPoint: CGPoint(x: host.bounds.width - 44, y: masterFrame.midY))
    guard let editor = window.firstResponder as? NSTextView else {
      throw PrintroomError.invalid("Clicking the numeric field did not focus a native text editor")
    }
    let beforeText = model.adjustments
    let beforeSelection = model.selection.selectedFrameIDs
    try await press("a", code: 0, modifiers: [.command])
    try require(model.selection.selectedFrameIDs == beforeSelection,
      "Command-A in the text field must preserve photo selection")
    try await press("w", code: 13)
    try require(model.adjustments == beforeText, "Typing W in the numeric field altered grading")
    try require(editor.string.lowercased().contains("w"), "Numeric field did not receive the typed W")
    try await press("i", code: 34)
    try require(!model.neutralPicking && editor.string.lowercased().contains("i"),
      "Typing I must reach the numeric field without enabling the eyedropper")
    try await press("a", code: 0, modifiers: [.command])
    try await press("1", code: 18)
    try await press("\t", code: 48)
    window.makeFirstResponder(nil)
    try require(model.adjustments == beforeText, "Leaving the numeric field changed the restored value")
    print("PASS: Numeric text field receives W, I and Command-A without tool, grading or photo selection changes")
    try await ready()
    // The 24×20 eyedropper is in the heading, 10 px above the 24 px timing row.
    try await click(windowPoint: CGPoint(x: host.bounds.width - 28, y: masterFrame.midY + 32))
    try require(model.neutralPicking, "Eyedropper button did not enter neutral picking")
    try await press("\u{1b}", code: 53)
    try require(!model.neutralPicking && !model.isNeutralSampling,
      "Escape did not cancel the eyedropper")
    print("PASS: Eyedropper button → Escape cancels picking")
    guard let canvas = descendants(host).compactMap({ $0 as? CanvasView }).first else {
      throw PrintroomError.invalid("QA preview canvas missing")
    }
    let previousPointer = NSEvent.mouseLocation
    let screenHeight = NSScreen.screens[0].frame.maxY
    defer {
      CGWarpMouseCursorPosition(CGPoint(x: previousPointer.x, y: screenHeight - previousPointer.y))
    }
    func movePointer(to point: CGPoint) async throws {
      try requireFocus()
      let screen = window.convertPoint(toScreen: point)
      try require(CGWarpMouseCursorPosition(CGPoint(x: screen.x, y: screenHeight - screen.y)) == .success,
        "QA could not position the cursor in its own window")
      guard let event = NSEvent.mouseEvent(with: .mouseMoved, location: point,
        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, eventNumber: 1,
        clickCount: 0, pressure: 0) else { throw PrintroomError.invalid("QA move event creation failed") }
      NSApp.postEvent(event, atStart: false)
      try await Task.sleep(for: .milliseconds(250))
    }
    let canvasCenter = canvas.convert(CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY), to: nil)
    try await movePointer(to: canvasCenter)
    try require(NSCursor.current === NSCursor.arrow, "Idle preview must show the arrow cursor")
    try await press("i", code: 34)
    try require(model.neutralPicking && NSCursor.current === CanvasView.neutralCursor,
      "I must enter the eyedropper and update a stationary pointer")
    try await press("i", code: 34, repeatKey: true)
    try require(model.neutralPicking, "Holding I must not repeatedly toggle the eyedropper")
    if let data = CanvasView.neutralCursor.image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: data), let png = bitmap.representation(using: .png, properties: [:]) {
      try png.write(to: output.appendingPathComponent("05-neutral-cursor.png"))
    }
    try await press("i", code: 34)
    try require(!model.neutralPicking && NSCursor.current === NSCursor.arrow,
      "I must cancel the eyedropper and restore the arrow cursor")
    try await press("i", code: 34)
    try await movePointer(to: CGPoint(x: host.bounds.width - 28, y: masterFrame.midY + 32))
    try require(NSCursor.current !== CanvasView.neutralCursor, "Eyedropper cursor leaked into the inspector")
    try await movePointer(to: canvasCenter)
    try require(NSCursor.current === CanvasView.neutralCursor, "Re-entering the canvas must restore the eyedropper")
    try await press("\u{1b}", code: 53)
    try require(NSCursor.current === NSCursor.arrow, "Escape must restore the stationary cursor")
    print("PASS: I toggles eyedropper; cursor updates without movement, restores on Escape and stays inside canvas")
    // Bring the synthetic patch into Final midtones so this tests a real fit.
    model.edit { $0.timing.master = 200 }
    try await ready()
    let beforeNeutralPick = model.adjustments
    try await press("i", code: 34)
    try await click(windowPoint: canvasCenter)
    try await ready()
    try require(!model.neutralPicking && !model.isNeutralSampling && NSCursor.current === NSCursor.arrow,
      "Completed neutral sampling must restore the arrow cursor without movement")
    try require(model.adjustments != beforeNeutralPick && model.adjustments.timing.master == 200,
      "Final neutral picking must fit RGB Timing and preserve Master")
    print("PASS: Final neutral picking fits RGB Timing, preserves Master and restores the stationary cursor")
    // Locate the Film Base button relative to the top of the actual canvas.
    let baseButton = CGPoint(x: host.bounds.width - 153,
      y: canvas.convert(CGPoint(x: 0, y: 0), to: nil).y - 20)
    try await click(windowPoint: baseButton)
    try require(model.sampling, "Film Base button did not enter selection")
    try await movePointer(to: canvasCenter)
    try require(NSCursor.current === NSCursor.crosshair, "Film Base selection must show the crosshair")
    try await press("i", code: 34)
    try require(model.sampling && !model.neutralPicking, "I must preserve Film Base mode exclusivity")
    try await click(windowPoint: baseButton)
    try require(!model.sampling && NSCursor.current === NSCursor.arrow,
      "Canceling Film Base selection must restore the stationary cursor")
    print("PASS: Film Base button shows crosshair; I respects exclusivity; cancel restores arrow")
    try require(model.project?.frames[0].adjustments == FrameAdjustments(),
      "Keyboard edits leaked into the previous frame")
    try require(model.errorMessage == nil, "Keyboard QA ended with an application error")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", "-o", "-l", String(window.windowNumber),
      output.appendingPathComponent("04-keyboard-regression.png").path]
    try process.run()
    process.waitUntilExit()
    try require(process.terminationStatus == 0, "Keyboard QA screenshot failed")
    print("EDITOR KEYBOARD QA PASSED: real EditorView, active own window, queued AppKit key/mouse events; fixture=\(folder.path)")
  }
}
