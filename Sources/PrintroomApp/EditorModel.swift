import AppKit
import CryptoKit
import ImageIO
import PrintroomCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class EditorModel: ObservableObject {
  @Published var project: RollProject?
  @Published var folder: URL?
  @Published var selection = SelectionState()
  @Published var snapshot: ParameterSnapshot?
  @Published var previewImage: CGImage?
  @Published var thumbnails: [UUID: CGImage] = [:]
  @Published var stage: PipelineStage = .final { didSet { render() } }
  @Published var sampling = false
  @Published var status = "打开一张 TIFF，开始整卷调色"
  @Published var errorMessage: String?
  @Published var isLoading = false
  @Published var isRendering = false
  @Published var isExporting = false
  @Published var exportProgress = 0.0
  @Published var dirty = false
  @Published var saveFailure = false
  @Published var sourceWidth = 0
  @Published var sourceHeight = 0
  @Published var embeddedProfile = ""
  @Published var baseStatistics = ""
  @Published var sampleReadout = "点击预览查看原始像素与当前阶段数值"
  @Published var undoRevision = 0
  let undoManager = UndoManager()
  let imageService = ImageService()
  private let thumbnailService = ImageService()
  var assets: AppAssets?
  private var previewInput: PixelBuffer?
  private var loadTask: Task<Void, Never>?
  private var renderTask: Task<Void, Never>?
  private var thumbnailTask: Task<Void, Never>?
  private var exportTask: Task<Void, Never>?
  private var saveTask: Task<Void, Never>?
  private var loadRevision = 0
  private var renderRevision = 0
  private var expectedModification: Date?
  private var gestureBefore: RollProject?
  private var thumbnailInputs: [UUID: PixelBuffer] = [:]
  private var thumbnailGeneration = UUID()
  var activeFrame: FrameRecord? { project?.frames.first { $0.id == selection.activeFrameID } }
  var adjustments: FrameAdjustments { activeFrame?.adjustments ?? .init() }
  var canApply: Bool { snapshot != nil && !selection.selectedFrameIDs.isEmpty && !isExporting }
  var canUndo: Bool { undoManager.canUndo }
  var canRedo: Bool { undoManager.canRedo }
  var hasImage: Bool { previewImage != nil && activeFrame != nil }
  var matrix: PrintDensityMatrix { project?.calibration.matrix ?? .identity }

  init() {
    undoManager.groupsByEvent = false
    do { assets = try AppAssets() } catch { errorMessage = error.localizedDescription }
  }
  func openPanel() {
    guard !isExporting else { return }
    let panel = NSOpenPanel()
    panel.title = "打开一张 TIFF 或整卷文件夹"
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.tiff]
    if panel.runModal() == .OK, let url = panel.url { open(url) }
  }
  func open(_ url: URL, discardUnsaved: Bool = false) {
    guard !isExporting else {
      errorMessage = "请先完成或取消当前导出"
      return
    }
    guard discardUnsaved || flushSave() else { return }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
      errorMessage = "文件不存在：\(url.lastPathComponent)"
      return
    }
    let targetFolder = isDirectory.boolValue ? url : url.deletingLastPathComponent()
    let preferred = isDirectory.boolValue ? nil : url
    do {
      let roll = try ProjectStore.open(folder: targetFolder, preferredFile: preferred)
      if folder != targetFolder { snapshot = nil }
      thumbnails = [:]
      thumbnailInputs = [:]
      baseStatistics = ""
      loadTask?.cancel()
      renderTask?.cancel()
      thumbnailTask?.cancel()
      saveTask?.cancel()
      folder = targetFolder
      project = roll
      expectedModification = roll.loadedModificationDate
      saveFailure = false
      selection = SelectionState()
      let available = roll.frames.filter { !$0.isMissing }
      let chosen =
        available.first { $0.filename == preferred?.lastPathComponent } ?? available.first {
          $0.id == roll.lastActiveFrameID
        } ?? available.first
      if let chosen {
        selection.click(chosen.id, ordered: available.map(\.id), command: false, shift: false)
      }
      undoManager.removeAllActions()
      undoRevision += 1
      dirty = true
      sampling = false
      status = "\(targetFolder.lastPathComponent) · \(available.count) 张照片"
      _ = flushSave()
      loadActive()
      refreshThumbnails()
    } catch { errorMessage = error.localizedDescription }
  }
  func select(_ id: UUID, command: Bool = false, shift: Bool = false) {
    guard let project, !isExporting else { return }
    let old = selection.activeFrameID
    selection.click(
      id, ordered: project.frames.filter { !$0.isMissing }.map(\.id), command: command, shift: shift
    )
    if old != selection.activeFrameID { loadActive() }
    self.project?.lastActiveFrameID = selection.activeFrameID
    dirty = true
    scheduleSave()
  }
  func selectAll() {
    guard let project else { return }
    let before = selection.activeFrameID
    selection.selectAll(project.frames.filter { !$0.isMissing }.map(\.id))
    if before != selection.activeFrameID { loadActive() }
  }
  func loadActive() {
    loadTask?.cancel()
    renderTask?.cancel()
    loadRevision += 1
    renderRevision += 1
    let revision = loadRevision
    previewImage = nil
    previewInput = nil
    sourceWidth = 0
    sourceHeight = 0
    sampleReadout = "点击预览查看像素读数"
    guard let frame = activeFrame, let folder else {
      isLoading = false
      isRendering = false
      return
    }
    isLoading = true
    let url = folder.appendingPathComponent(frame.filename)
    loadTask = Task {
      do {
        let result = try await imageService.preview(url)
        guard !Task.isCancelled, revision == loadRevision else { return }
        previewInput = result.0
        sourceWidth = result.1
        sourceHeight = result.2
        embeddedProfile = result.3
        isLoading = false
        render()
      } catch {
        if !Task.isCancelled && revision == loadRevision {
          isLoading = false
          errorMessage = error.localizedDescription
        }
      }
    }
  }
  func render() {
    renderTask?.cancel()
    renderRevision += 1
    guard let input = previewInput, let project, let frame = activeFrame, let assets else { return }
    let revision = renderRevision
    let selectedStage = stage
    let calibration = project.calibration
    let adjustments = frame.adjustments
    isRendering = true
    renderTask = Task {
      do {
        let output = try await Task.detached(priority: .userInitiated) {
          try assets.gpu.render(
            input, calibration: calibration, adjustments: adjustments, lut: assets.lut,
            stage: selectedStage)
        }.value
        guard !Task.isCancelled, revision == renderRevision else { return }
        previewImage = try DisplayImage.make(
          output, profile: assets.profile, diagnostic: selectedStage != .final)
        isRendering = false
      } catch {
        if !Task.isCancelled && revision == renderRevision {
          isRendering = false
          errorMessage = error.localizedDescription
        }
      }
    }
  }
  func beginAdjustment() { if gestureBefore == nil { gestureBefore = project } }
  func endAdjustment() {
    if let old = gestureBefore, let current = project, old.frames != current.frames {
      registerUndo(old: old, name: "调整参数")
    }
    gestureBefore = nil
    scheduleSave(immediate: true)
    refreshThumbnails()
  }
  func edit(_ mutate: (inout FrameAdjustments) -> Void) {
    guard var next = project,
      let index = next.frames.firstIndex(where: { $0.id == selection.activeFrameID }), !isExporting
    else { return }
    let old = next
    mutate(&next.frames[index].adjustments)
    do { try Pipeline.validate(next.frames[index].adjustments) } catch {
      errorMessage = error.localizedDescription
      return
    }
    guard next.frames[index].adjustments != old.frames[index].adjustments else { return }
    if gestureBefore == nil { registerUndo(old: old, name: "调整参数") }
    project = next
    dirty = true
    render()
    scheduleSave()
    if gestureBefore == nil { refreshThumbnails() }
  }
  private func registerUndo(old: RollProject, name: String) {
    let grouping = !undoManager.isUndoing && !undoManager.isRedoing
    if grouping { undoManager.beginUndoGrouping() }
    undoManager.registerUndo(withTarget: self) { target in target.restore(old, name: name) }
    undoManager.setActionName(name)
    if grouping { undoManager.endUndoGrouping() }
    undoRevision += 1
  }
  private func restore(_ value: RollProject, name: String) {
    guard let old = project else { return }
    registerUndo(old: old, name: name)
    project = value
    dirty = true
    render()
    refreshThumbnails()
    scheduleSave(immediate: true)
    undoRevision += 1
  }
  func undo() {
    undoManager.undo()
    undoRevision += 1
    status = "已撤销调色操作"
  }
  func redo() {
    undoManager.redo()
    undoRevision += 1
    status = "已重做调色操作"
  }
  func resetAdjustments() { edit { $0 = .init() } }
  func copyParameters() {
    guard let activeFrame else { return }
    snapshot = ParameterSnapshot(frame: activeFrame)
    status = "已复制：\(activeFrame.filename)"
  }
  func applyParameters() {
    guard let snapshot, let project, !selection.selectedFrameIDs.isEmpty, let folder else { return }
    do {
      let targets = selection.selectedFrameIDs
      for frame in project.frames where targets.contains(frame.id) {
        guard
          FileManager.default.fileExists(atPath: folder.appendingPathComponent(frame.filename).path)
        else { throw PrintroomError.invalid("目标文件已丢失：\(frame.filename)") }
      }
      let next = try snapshot.applying(to: project, targets: targets)
      guard next.frames != project.frames else {
        status = "所选照片参数已相同"
        return
      }
      registerUndo(old: project, name: "应用到 \(targets.count) 张")
      self.project = next
      dirty = true
      render()
      refreshThumbnails()
      scheduleSave(immediate: true)
      status = "已应用到 \(targets.count) 张"
    } catch { errorMessage = error.localizedDescription }
  }
  func setMatrix(_ matrix: PrintDensityMatrix) {
    guard var next = project, let old = project, next.calibration.matrix != matrix else { return }
    do {
      next.calibration = try Pipeline.recalibrate(next.calibration, matrix: matrix)
      registerUndo(old: old, name: "切换密度矩阵")
      project = next
      dirty = true
      render()
      refreshThumbnails()
      scheduleSave(immediate: true)
    } catch { errorMessage = error.localizedDescription }
  }
  func sampleBase(_ rect: PixelRect) {
    guard let folder, let frame = activeFrame, let project else { return }
    let id = frame.id
    let matrix = project.calibration.matrix
    let rollID = project.id
    sampling = false
    status = "正在采样原始像素…"
    Task {
      do {
        let result = try await imageService.sample(
          folder.appendingPathComponent(frame.filename), rect: rect, matrix: matrix, frameID: id)
        guard var next = self.project, next.id == rollID else { return }
        // If the matrix changed during sampling, use the current choice.
        next.calibration = try Pipeline.recalibrate(result.0, matrix: next.calibration.matrix)
        next.calibrationNeedsReview = false
        baseStatistics = String(
          format: "%d 像素 · 零值 %.2f%% · 饱和 %.2f%%", result.1.pixelCount, result.1.zeroFraction * 100,
          result.1.saturatedFraction * 100)
        if let old = self.project { registerUndo(old: old, name: "片基校准") }
        self.project = next
        dirty = true
        status = "整卷片基已校准至 95 CV"
        render()
        refreshThumbnails()
        scheduleSave(immediate: true)
      } catch {
        errorMessage = error.localizedDescription
        status = "片基采样未完成"
      }
    }
  }
  func readPixel(x: Int, y: Int) {
    guard let folder, let frame = activeFrame, let project, let assets else { return }
    let selectedStage = stage
    Task {
      do {
        let p = try await imageService.pixel(
          folder.appendingPathComponent(frame.filename), x: x, y: y)
        let v = try Pipeline.process(
          p, calibration: project.calibration, adjustments: frame.adjustments, lut: assets.lut,
          stage: selectedStage)
        guard activeFrame?.id == frame.id, stage == selectedStage else { return }
        let values = String(format: "R %.5f  G %.5f  B %.5f", v.x, v.y, v.z)
        sampleReadout = "(\(x), \(y)) · \(selectedStage.label)  \(values)"
        if [.d0, .d1, .d2, .d3].contains(selectedStage) {
          sampleReadout += String(
            format: " · CV %.2f / %.2f / %.2f", v.x * 1024, v.y * 1024, v.z * 1024)
        }
      } catch { errorMessage = error.localizedDescription }
    }
  }
  func scheduleSave(immediate: Bool = false) {
    saveTask?.cancel()
    if immediate {
      _ = flushSave()
      return
    }
    saveTask = Task {
      try? await Task.sleep(for: .milliseconds(300))
      if !Task.isCancelled { _ = flushSave() }
    }
  }
  @discardableResult func flushSave() -> Bool {
    saveTask?.cancel()
    guard dirty, let folder, let project else { return true }
    do {
      expectedModification = try ProjectStore.save(
        project, folder: folder, expectedModification: expectedModification)
      dirty = false
      saveFailure = false
      return true
    } catch {
      saveFailure = true
      errorMessage = "调色仍保留在内存，保存失败：\(error.localizedDescription)"
      return false
    }
  }
  func reloadDiscardingUnsaved() {
    guard let folder else { return }
    errorMessage = nil
    open(folder, discardUnsaved: true)
  }
  func backupPanel() {
    guard let project else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = "\(folder?.lastPathComponent ?? "Roll")-Printroom-settings.json"
    panel.title = "另存调色设置副本"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      guard
        url.standardizedFileURL.resolvingSymlinksInPath()
          != folder?.appendingPathComponent(ProjectStore.filename).standardizedFileURL
          .resolvingSymlinksInPath()
      else { throw PrintroomError.invalid("请为设置副本选择不同文件名，不能绕过冲突检查覆盖当前项目") }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(project).write(to: url, options: .atomic)
      status = "设置副本已保存：\(url.lastPathComponent)"
      errorMessage = nil
    } catch { errorMessage = error.localizedDescription }
  }
  func restoreBackupPanel() {
    guard folder != nil else { return }
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.title = "恢复本卷调色设置副本"
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do { try restoreBackup(data: Data(contentsOf: url)) } catch {
      errorMessage = error.localizedDescription
    }
  }
  func restoreBackup(data: Data) throws {
    guard let folder, let previous = project else { throw PrintroomError.invalid("请先打开对应胶卷") }
    let backup = try ProjectStore.decodeSnapshot(data)
    var next = try ProjectStore.open(folder: folder, preferredFile: nil)
    guard next.id == backup.id else { throw PrintroomError.invalid("设置副本属于另一卷底片") }
    for i in next.frames.indices {
      if let source = backup.frames.first(where: { $0.id == next.frames[i].id }) {
        next.frames[i].adjustments = source.adjustments
      }
    }
    next.calibration = backup.calibration
    if let source = backup.frames.first(where: { $0.id == backup.calibration.sourceFrameID }),
      let current = next.frames.first(where: { $0.id == source.id })
    {
      next.calibrationNeedsReview =
        current.isMissing || source.sourceSize != current.sourceSize
        || source.sourceModified != current.sourceModified
    }
    let saved = try ProjectStore.save(
      next, folder: folder, expectedModification: next.loadedModificationDate)
    registerUndo(old: previous, name: "恢复设置副本")
    project = next
    expectedModification = saved
    dirty = false
    saveFailure = false
    errorMessage = nil
    render()
    refreshThumbnails()
    status = "已恢复本卷设置副本"
  }
  func exportPanel() {
    guard let frame = activeFrame, let folder, let project, let assets, !isExporting else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.tiff]
    panel.nameFieldStringValue =
      URL(fileURLWithPath: frame.filename).deletingPathExtension().lastPathComponent
      + "_Printroom.tiff"
    panel.directoryURL = folder.appendingPathComponent("Printroom Exports", isDirectory: true)
    panel.title = "导出当前照片 · 16-bit TIFF · P3 D65 Gamma 2.6"
    guard panel.runModal() == .OK, let requested = panel.url else { return }
    let source = folder.appendingPathComponent(frame.filename)
    guard
      source.resolvingSymlinksInPath().standardizedFileURL
        != requested.resolvingSymlinksInPath().standardizedFileURL
    else {
      errorMessage = "不能覆盖原始 TIFF"
      return
    }
    var destination = requested
    var suffix = 1
    while FileManager.default.fileExists(atPath: destination.path) {
      destination = requested.deletingLastPathComponent().appendingPathComponent(
        requested.deletingPathExtension().lastPathComponent + "_\(suffix).tiff")
      suffix += 1
    }
    do {
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    } catch {
      errorMessage = error.localizedDescription
      return
    }
    isExporting = true
    exportProgress = 0
    status = "正在导出 \(frame.filename)…"
    let finalURL = destination
    exportTask = Task {
      do {
        try await imageService.export(
          source: source, destination: finalURL, calibration: project.calibration,
          adjustments: frame.adjustments, assets: assets
        ) { value in Task { @MainActor [weak self] in self?.exportProgress = value } }
        status = "已导出：\(finalURL.lastPathComponent)（16-bit，已嵌入 ICC）"
      } catch is CancellationError { status = "导出已取消" } catch {
        errorMessage = error.localizedDescription
        status = "导出未完成"
      }
      isExporting = false
    }
  }
  func cancelExport() { exportTask?.cancel() }
  private func refreshThumbnails() {
    thumbnailTask?.cancel()
    thumbnailGeneration = UUID()
    guard let project, let folder, let assets else { return }
    let generation = thumbnailGeneration
    let frames = project.frames.filter { !$0.isMissing }
    let cache = folder.appendingPathComponent(".printroom-cache", isDirectory: true)
    thumbnailTask = Task {
      for frame in frames {
        guard !Task.isCancelled, generation == thumbnailGeneration else { return }
        do {
          let encoder = JSONEncoder()
          encoder.outputFormatting = .sortedKeys
          let keyData = try encoder.encode(
            ThumbnailKey(
              filename: frame.filename, modified: frame.sourceModified, size: frame.sourceSize,
              calibration: project.calibration, adjustments: frame.adjustments,
              algorithm: algorithmVersion, icc: ProjectAssetIdentity.expectedICCSHA256,
              lut: ProjectAssetIdentity.expectedLUTSHA256, dimension: 240))
          let key = SHA256.hash(data: keyData).map { String(format: "%02x", $0) }.joined()
          let file = cache.appendingPathComponent(key + ".png")
          if let source = CGImageSourceCreateWithURL(file as CFURL, nil),
            let cg = CGImageSourceCreateImageAtIndex(source, 0, nil)
          {
            thumbnails[frame.id] = cg
            continue
          }
          let input: PixelBuffer
          if let cached = thumbnailInputs[frame.id] {
            input = cached
          } else {
            let raw = try await thumbnailService.load(folder.appendingPathComponent(frame.filename))
            input = raw.preview(maxDimension: 240)
            await thumbnailService.clear()
            guard !Task.isCancelled, generation == thumbnailGeneration else { return }
            thumbnailInputs[frame.id] = input
          }
          let output = try await Task.detached(priority: .utility) {
            try assets.gpu.render(
              input, calibration: project.calibration, adjustments: frame.adjustments,
              lut: assets.lut)
          }.value
          guard !Task.isCancelled, generation == thumbnailGeneration else { return }
          let cg = try DisplayImage.make(output, profile: assets.profile)
          thumbnails[frame.id] = cg
          // Cache is expendable; failures do not prevent editing or project save.
          try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
          if let dest = CGImageDestinationCreateWithURL(
            file as CFURL, UTType.png.identifier as CFString, 1, nil)
          {
            CGImageDestinationAddImage(dest, cg, nil)
            _ = CGImageDestinationFinalize(dest)
          }
        } catch { if !Task.isCancelled { status = "缩略图不可用：\(frame.filename)" } }
      }
    }
  }
  private struct ThumbnailKey: Codable {
    let filename: String
    let modified: Double
    let size: Int64
    let calibration: FilmCalibration
    let adjustments: FrameAdjustments
    let algorithm: String
    let icc: String
    let lut: String
    let dimension: Int
  }
  func handleTimingKey(_ key: String) {
    guard activeFrame != nil else { return }
    edit { a in
      switch key.lowercased() {
      case "q": a.timing.red = max(-256, a.timing.red - 1)
      case "e": a.timing.red = min(256, a.timing.red + 1)
      case "a": a.timing.green = max(-256, a.timing.green - 1)
      case "d": a.timing.green = min(256, a.timing.green + 1)
      case "z": a.timing.blue = max(-256, a.timing.blue - 1)
      case "c": a.timing.blue = min(256, a.timing.blue + 1)
      case "w", "s": a.timing.master = min(256, a.timing.master + 1)
      default: break
      }
    }
  }
}
