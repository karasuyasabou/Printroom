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
  @Published var histogram: HistogramStatistics?
  @Published var histogramChannel = -1
  @Published var isHistogramUpdating = false
  @Published var detailImage: CGImage?
  @Published var detailRect: PixelRect?
  @Published var isDetailLoading = false
  @Published var nativeZoomToken = 0
  @Published var thumbnails: [UUID: CGImage] = [:]
  @Published var stage: PipelineStage = .final { didSet { render() } }
  @Published var sampling = false {
    didSet {
      guard sampling != oldValue else { return }
      let changesGeometry = activeFrame?.crop != nil || isCropping
      if sampling { isCropping = false; cropDraft = nil }
      guard changesGeometry else { return }
      previewImage = nil
      cropViewportToken += 1
      render()
    }
  }
  @Published private(set) var isCropping = false
  @Published var cropDraft: FrameCrop?
  @Published var cropViewportToken = 0
  @Published var status = "打开一张 TIFF，开始整卷调色"
  @Published var errorMessage: String?
  @Published var isLoading = false
  @Published var isRendering = false
  @Published var isExporting = false
  @Published var exportProgress = 0.0
  @Published var exportDetail = ""
  @Published var exportSummary: ExportSummary?
  @Published var showExportSummary = false
  private let exportEngine = ExportEngine()
  private var exportGeneration = UUID()
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
  private let previewRenderer = PreviewRenderService()
  private let detailRenderer = PreviewRenderService()
  private let thumbnailRenderer = PreviewRenderService()
  private let thumbnailService = ImageService()
  var assets: AppAssets?
  private var previewInput: PixelBuffer?
  private var previewInputIdentity = UUID()
  private struct PreviewContext: Equatable {
    let source: UUID
    let frameID: UUID
    let calibration: FilmCalibration
    let stage: PipelineStage
    let orientation: FrameOrientation
    let crop: FrameCrop?
    let sourceWidth: Int
    let sourceHeight: Int
  }
  private struct PreviewRequest {
    let input: PixelBuffer
    let assets: AppAssets
    let context: PreviewContext
    let adjustments: FrameAdjustments
    let revision: Int
  }
  private var previewContext: PreviewContext?
  private var pendingPreview: PreviewRequest?
  private var renderGeneration = UUID()
  private var pendingThumbnailIDs: Set<UUID> = []
  private var sampleTask: Task<Void, Never>?
  private var sampleRevision = 0
  private var pixelTask: Task<Void, Never>?
  private var pixelRevision = 0
  private var loadTask: Task<Void, Never>?
  private var histogramTask: Task<Void, Never>?
  private var detailTask: Task<Void, Never>?
  private var detailRevision = 0
  private var requestedDetailRect: PixelRect?
  private var renderTask: Task<Void, Never>?
  private var thumbnailTask: Task<Void, Never>?
  private var exportTask: Task<Void, Never>?
  private var saveTask: Task<Void, Never>?
  private var loadRevision = 0
  private var renderRevision = 0
  private var expectedModification: Date?
  private var gestureBefore: RollProject?
  private var thumbnailGeneration = UUID()
  var activeFrame: FrameRecord? { project?.frames.first { $0.id == selection.activeFrameID } }
  var adjustments: FrameAdjustments { activeFrame?.adjustments ?? .init() }
  var canApply: Bool { snapshot != nil && !selection.selectedFrameIDs.isEmpty }
  var canUndo: Bool { undoManager.canUndo }
  var canRedo: Bool { undoManager.canRedo }
  var hasImage: Bool { previewImage != nil && activeFrame != nil }
  var orientation: FrameOrientation { activeFrame?.orientation ?? .identity }
  var displayedCrop: FrameCrop? { isCropping || sampling ? nil : activeFrame?.crop }
  var displayGeometry: CropGeometry? {
    try? CropGeometry(crop: displayedCrop, sourceWidth: sourceWidth,
      sourceHeight: sourceHeight, orientation: orientation)
  }
  var displayWidth: Int { displayGeometry?.outputWidth ?? 0 }
  var displayHeight: Int { displayGeometry?.outputHeight ?? 0 }
  var cropDraftGeometry: CropGeometry? {
    guard isCropping else { return nil }
    return try? CropGeometry(crop: cropDraft, sourceWidth: sourceWidth,
      sourceHeight: sourceHeight, orientation: orientation)
  }
  /// Only controls and pointer gestures use the direction-adjusted copy. The
  /// actual draft, project value and batch snapshot stay in original coordinates.
  var displayedCropDraft: FrameCrop? { cropDraftGeometry?.displayCrop }
  var canSyncCrop: Bool { activeFrame != nil && selection.selectedFrameIDs.count > 1 }
  var exportSettings: ProjectExportSettings { project?.exportSettings ?? .init() }
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
    stopTimingKey()
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
      pendingThumbnailIDs = []
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
    stopTimingKey()
    guard let project else { return }
    let old = selection.activeFrameID
    selection.click(
      id, ordered: project.frames.filter { !$0.isMissing }.map(\.id), command: command, shift: shift
    )
    if old != selection.activeFrameID { loadActive() }
    self.project?.lastActiveFrameID = selection.activeFrameID
    dirty = true
    scheduleSave()
  }
  func selectAdjacentFrame(_ delta: Int) {
    let frames = project?.frames.filter { !$0.isMissing } ?? []
    guard !frames.isEmpty else { return }
    guard let index = frames.firstIndex(where: { $0.id == selection.activeFrameID }) else {
      select(frames[0].id)
      return
    }
    let next = index + delta
    guard frames.indices.contains(next), next != index else { return }
    select(frames[next].id)
  }
  func selectAll() {
    stopTimingKey()
    guard let project else { return }
    let before = selection.activeFrameID
    selection.selectAll(project.frames.filter { !$0.isMissing }.map(\.id))
    if before != selection.activeFrameID { loadActive() }
  }
  func loadActive() {
    isCropping = false
    cropDraft = nil
    sampling = false
    cancelSampling()
    pixelTask?.cancel()
    pixelRevision += 1
    isRendering = false
    embeddedProfile = ""
    loadTask?.cancel()
    cancelPreviewWorker()
    previewContext = nil
    loadRevision += 1
    renderRevision += 1
    let revision = loadRevision
    histogramTask?.cancel()
    histogram = nil
    isHistogramUpdating = false
    invalidateDetail()
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
        previewInputIdentity = UUID()
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
  private func cancelPreviewWorker() {
    renderTask?.cancel()
    renderTask = nil
    pendingPreview = nil
    renderGeneration = UUID()
  }
  func render() {
    histogramTask?.cancel()
    histogram = nil
    isHistogramUpdating = false
    invalidateDetail()
    renderRevision += 1
    guard let input = previewInput, let project, let frame = activeFrame, let assets else { return }
    let context = PreviewContext(source: previewInputIdentity, frameID: frame.id,
      calibration: project.calibration, stage: stage, orientation: frame.orientation,
      crop: displayedCrop, sourceWidth: sourceWidth, sourceHeight: sourceHeight)
    // Geometry/source/stage changes invalidate in-flight work. Ordinary edits keep
    // the current job alive and replace the single pending snapshot instead.
    if context != previewContext {
      cancelPreviewWorker()
      previewContext = context
    }
    pendingPreview = PreviewRequest(input: input, assets: assets, context: context,
      adjustments: frame.adjustments, revision: renderRevision)
    isRendering = true
    guard renderTask == nil else { return }
    let generation = renderGeneration
    renderTask = Task {
      while !Task.isCancelled, generation == renderGeneration, let request = pendingPreview {
        pendingPreview = nil
        do {
          let result = try await previewRenderer.render(request.input,
            calibration: request.context.calibration, adjustments: request.adjustments,
            assets: request.assets, stage: request.context.stage,
            orientation: request.context.orientation, inputIdentity: request.context.source,
            crop: request.context.crop, sourceWidth: request.context.sourceWidth,
            sourceHeight: request.context.sourceHeight)
          guard !Task.isCancelled, generation == renderGeneration,
            previewContext == request.context, activeFrame?.id == request.context.frameID else { return }
          // One serial worker publishes snapshots in increasing order, including
          // while input continues faster than rendering. The next job reads only
          // the latest pending edit; an older result cannot overwrite a newer one.
          previewImage = result.image
          if request.revision == renderRevision {
            isRendering = false
            if !isCropping {
              updateHistogram(result.pixels, stage: request.context.stage,
                revision: request.revision, frameID: request.context.frameID)
            }
          }
        } catch {
          guard !Task.isCancelled, generation == renderGeneration else { return }
          if request.revision == renderRevision {
            isRendering = false
            errorMessage = error.localizedDescription
          }
        }
      }
      if generation == renderGeneration { renderTask = nil }
    }
  }
  private func updateHistogram(_ buffer: PixelBuffer, stage: PipelineStage, revision: Int, frameID: UUID) {
    isHistogramUpdating = true
    histogramTask = Task {
      do {
        // Statistics follow settled edits; high-rate interaction does not scan
        // every intermediate 1600px image. Cancellation also covers this delay.
        try await Task.sleep(for: .milliseconds(120))
        let worker = Task.detached(priority: .utility) {
          try HistogramStatistics.compute(buffer, stage: stage, isPreview: true, cancelled: { Task.isCancelled })
        }
        let result = try await withTaskCancellationHandler {
          try await worker.value
        } onCancel: { worker.cancel() }
        guard !Task.isCancelled, revision == renderRevision, activeFrame?.id == frameID else { return }
        histogram = result
        isHistogramUpdating = false
      } catch {
        if !Task.isCancelled && revision == renderRevision { isHistogramUpdating = false }
      }
    }
  }
  func changeOrientation(_ operation: OrientationOperation) {
    guard !isCropping else { return }
    guard var next = project, let index = next.frames.firstIndex(where: { $0.id == selection.activeFrameID }) else { return }
    let old = next
    next.frames[index].orientation = next.frames[index].orientation.applying(operation)
    do {
      if next.frames[index].crop?.geometryVersion == 1 {
        next.frames[index].crop = try next.frames[index].crop?.sourceCoordinates(
          sourceWidth: sourceWidth, sourceHeight: sourceHeight,
          orientation: old.frames[index].orientation)
      }
    } catch { errorMessage = error.localizedDescription; return }
    guard next.frames != old.frames else { return }
    registerUndo(old: old, name: "调整方向")
    cancelSampling()
    previewImage = nil
    project = next
    dirty = true
    render()
    refreshThumbnails(affectedIDs: [next.frames[index].id])
    scheduleSave(immediate: true)
  }
  func beginCrop() {
    guard !isCropping, activeFrame != nil, sourceWidth > 0, sourceHeight > 0 else { return }
    stopTimingKey()
    cancelSampling()
    sampling = false
    let initial = activeFrame?.crop ?? FrameCrop(portrait: sourceHeight > sourceWidth)
    do {
      cropDraft = try initial.sourceCoordinates(sourceWidth: sourceWidth,
        sourceHeight: sourceHeight, orientation: orientation)
      isCropping = true
      previewImage = nil
      cropViewportToken += 1
      render()
    } catch { errorMessage = error.localizedDescription }
  }
  func updateCropDraft(_ value: FrameCrop) {
    guard isCropping else { return }
    do {
      cropDraft = try value.sourceCoordinates(sourceWidth: sourceWidth,
        sourceHeight: sourceHeight, orientation: orientation)
    } catch { errorMessage = error.localizedDescription }
  }
  func updateDisplayedCropDraft(_ value: FrameCrop) {
    updateCropDraft(value)
  }
  func resetCropDraft() {
    guard isCropping else { return }
    cropDraft = nil
  }
  func cancelCrop() {
    guard isCropping else { return }
    isCropping = false
    cropDraft = nil
    previewImage = nil
    cropViewportToken += 1
    render()
  }
  func commitCrop(syncSelection: Bool = false) {
    guard isCropping, let id = activeFrame?.id else { return }
    let targets = syncSelection ? selection.selectedFrameIDs : [id]
    applyCrop(cropDraft, targets: targets)
  }
  func syncCurrentCropToSelection() {
    guard canSyncCrop, let frame = activeFrame else { return }
    if isCropping { commitCrop(syncSelection: true) }
    else { applyCrop(frame.crop, targets: selection.selectedFrameIDs) }
  }
  private func applyCrop(_ crop: FrameCrop?, targets: Set<UUID>) {
    guard let old = project, let folder, !targets.isEmpty else { return }
    do {
      let sourceCrop = try crop?.sourceCoordinates(sourceWidth: sourceWidth,
        sourceHeight: sourceHeight, orientation: orientation)
      guard targets.isSubset(of: Set(old.frames.filter { !$0.isMissing }.map(\.id))) else {
        throw PrintroomError.invalid("裁剪同步包含不可用照片")
      }
      var next = old
      // Validate and fit every captured target before changing any frame. The
      // saved normalized crop is a value snapshot, independent of later edits.
      for index in next.frames.indices where targets.contains(next.frames[index].id) {
        let frame = next.frames[index]
        let metadata = try TIFFCodec.metadata(url: folder.appendingPathComponent(frame.filename))
        next.frames[index].crop = try sourceCrop?.constrained(sourceWidth: metadata.width,
          sourceHeight: metadata.height)
      }
      let changed = next.frames != old.frames
      if changed {
        registerUndo(old: old, name: targets.count > 1 ? "同步裁剪到 \(targets.count) 张" : "裁剪照片")
        project = next
        dirty = true
      }
      isCropping = false
      cropDraft = nil
      previewImage = nil
      cropViewportToken += 1
      render()
      if changed {
        refreshThumbnails(affectedIDs: targets)
        scheduleSave(immediate: true)
      }
      status = changed ? "已应用裁剪到 \(targets.count) 张" : "所选照片裁剪已相同"
    } catch { errorMessage = error.localizedDescription }
  }
  func inspectNativeResolution() { if !isCropping { nativeZoomToken += 1 } }
  func invalidateDetail() {
    detailTask?.cancel()
    detailRevision += 1
    requestedDetailRect = nil
    detailImage = nil
    detailRect = nil
    isDetailLoading = false
  }
  func requestDetail(_ rect: PixelRect?) {
    guard let rect else {
      if requestedDetailRect != nil { invalidateDetail() }
      return
    }
    guard rect != requestedDetailRect, !isRendering, !isLoading, !isCropping,
      let frame = activeFrame, let project, let folder, let assets,
      rect.width > 0, rect.height > 0 else { return }
    detailTask?.cancel()
    detailRevision += 1
    let revision = detailRevision
    let renderID = renderRevision
    requestedDetailRect = rect
    detailImage = nil
    detailRect = nil
    isDetailLoading = true
    let width = sourceWidth, height = sourceHeight, stage = stage, crop = displayedCrop
    detailTask = Task {
      do {
        try await Task.sleep(for: .milliseconds(80))
        let geometry = try CropGeometry(crop: crop, sourceWidth: width,
          sourceHeight: height, orientation: frame.orientation)
        let input = try await imageService.transformedRegion(
          folder.appendingPathComponent(frame.filename), geometry: geometry, rect: rect)
        try Task.checkCancellation()
        let result = try await detailRenderer.render(input, calibration: project.calibration,
          adjustments: frame.adjustments, assets: assets, stage: stage)
        guard !Task.isCancelled, revision == detailRevision, renderID == renderRevision, activeFrame?.id == frame.id else { return }
        detailImage = result.image
        detailRect = rect
        isDetailLoading = false
      } catch {
        if !Task.isCancelled && revision == detailRevision {
          isDetailLoading = false
          status = "原始像素区域读取失败：\(error.localizedDescription)"
        }
      }
    }
  }
  func sampleDisplayedBase(_ rect: PixelRect) {
    do { sampleBase(try orientation.inverseRect(rect, sourceWidth: sourceWidth, sourceHeight: sourceHeight)) }
    catch { errorMessage = error.localizedDescription }
  }
  func readDisplayedPixel(x: Int, y: Int) {
    guard let geometry = displayGeometry else { return }
    let point = geometry.sourcePoint(outputX: Double(x) + 0.5, outputY: Double(y) + 0.5)
    readPixel(x: max(0, min(sourceWidth - 1, Int(floor(point.x)))),
      y: max(0, min(sourceHeight - 1, Int(floor(point.y)))))
  }
  func beginAdjustment() { if gestureBefore == nil { gestureBefore = project } }
  func endAdjustment() {
    if let old = gestureBefore, let current = project, old.frames != current.frames {
      registerUndo(old: old, name: "调整参数")
      refreshThumbnails(changedFrom: old, to: current)
    }
    gestureBefore = nil
    scheduleSave(immediate: true)
  }
  func edit(_ mutate: (inout FrameAdjustments) -> Void) {
    guard var next = project,
      let index = next.frames.firstIndex(where: { $0.id == selection.activeFrameID })
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
    if gestureBefore == nil { refreshThumbnails(affectedIDs: [next.frames[index].id]) }
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
    cancelSampling()
    sampling = false
    isCropping = false
    cropDraft = nil
    let oldFrame = old.frames.first(where: { $0.id == selection.activeFrameID })
    let newFrame = value.frames.first(where: { $0.id == selection.activeFrameID })
    if oldFrame?.orientation != newFrame?.orientation || oldFrame?.crop != newFrame?.crop {
      previewImage = nil
      cropViewportToken += 1
    }
    project = value
    let available = value.frames.filter { !$0.isMissing }.map(\.id)
    if let id = selection.activeFrameID, !available.contains(id) {
      selection = SelectionState()
      if let first = available.first { selection.click(first, ordered: available) }
    }
    selection.selectedFrameIDs.formIntersection(Set(available))
    self.project?.lastActiveFrameID = selection.activeFrameID
    dirty = true
    if old.frames.map({ $0.filename }) != value.frames.map({ $0.filename }) { loadActive() }
    else { render() }
    refreshThumbnails(changedFrom: old, to: value)
    scheduleSave(immediate: true)
    undoRevision += 1
  }
  func undo() {
    stopTimingKey()
    if isCropping { cancelCrop(); return }
    undoManager.undo()
    undoRevision += 1
    status = "已撤销操作"
  }
  func redo() {
    stopTimingKey()
    if isCropping { cancelCrop(); return }
    undoManager.redo()
    undoRevision += 1
    status = "已重做操作"
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
      refreshThumbnails(affectedIDs: targets)
      scheduleSave(immediate: true)
      status = "已应用到 \(targets.count) 张"
    } catch { errorMessage = error.localizedDescription }
  }
  func setMatrix(_ matrix: PrintDensityMatrix) {
    guard var next = project, let old = project, next.calibration.matrix != matrix else { return }
    do {
      cancelSampling()
      next.calibration = try Pipeline.recalibrate(next.calibration, matrix: matrix)
      registerUndo(old: old, name: "切换密度矩阵")
      project = next
      dirty = true
      render()
      refreshThumbnails()
      scheduleSave(immediate: true)
    } catch { errorMessage = error.localizedDescription }
  }
  private func cancelSampling() {
    sampleTask?.cancel()
    sampleRevision += 1
  }
  func sampleBase(_ rect: PixelRect) {
    guard let folder, let frame = activeFrame, let project else { return }
    cancelSampling()
    let revision = sampleRevision
    let id = frame.id
    let matrix = project.calibration.matrix
    let rollID = project.id
    sampling = false
    status = "正在采样原始像素…"
    sampleTask = Task {
      do {
        let result = try await imageService.sample(
          folder.appendingPathComponent(frame.filename), rect: rect, matrix: matrix, frameID: id)
        guard !Task.isCancelled, revision == sampleRevision, var next = self.project, next.id == rollID else { return }
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
        if !Task.isCancelled && revision == sampleRevision {
          errorMessage = error.localizedDescription
          status = "片基采样未完成"
        }
      }
    }
  }
  func readPixel(x: Int, y: Int) {
    guard let folder, let frame = activeFrame, let project, let assets else { return }
    pixelTask?.cancel()
    pixelRevision += 1
    let pixelID = pixelRevision
    let selectedStage = stage
    let revision = renderRevision
    pixelTask = Task {
      do {
        let p = try await imageService.pixel(
          folder.appendingPathComponent(frame.filename), x: x, y: y)
        let v = try Pipeline.process(
          p, calibration: project.calibration, adjustments: frame.adjustments, lut: assets.lut,
          stage: selectedStage)
        guard !Task.isCancelled, pixelID == pixelRevision, activeFrame?.id == frame.id, stage == selectedStage, revision == renderRevision else { return }
        let values = String(format: "R %.5f  G %.5f  B %.5f", v.x, v.y, v.z)
        sampleReadout = "(\(x), \(y)) · 原片 · \(selectedStage.label)  \(values)"
        if [.d0, .d1, .d2, .d3].contains(selectedStage) {
          sampleReadout += String(
            format: " · CV %.2f / %.2f / %.2f", v.x * 1024, v.y * 1024, v.z * 1024)
        }
      } catch {
        if !Task.isCancelled, pixelID == pixelRevision, activeFrame?.id == frame.id,
          stage == selectedStage, revision == renderRevision { errorMessage = error.localizedDescription }
      }
    }
  }
  func scheduleSave(immediate: Bool = false) {
    saveTask?.cancel()
    if immediate {
      _ = flushSave()
      return
    }
    saveTask = Task {
      try? await Task.sleep(for: .seconds(2))
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
        next.frames[i].orientation = source.orientation
        next.frames[i].crop = source.crop
        if let crop = source.crop, crop.geometryVersion == 1, !next.frames[i].isMissing,
          let metadata = try? TIFFCodec.metadata(
            url: folder.appendingPathComponent(next.frames[i].filename))
        {
          next.frames[i].crop = try crop.sourceCoordinates(sourceWidth: metadata.width,
            sourceHeight: metadata.height, orientation: source.orientation)
        }
      }
    }
    next.exportSettings = backup.exportSettings
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
    cancelSampling()
    isCropping = false
    cropDraft = nil
    sampling = false
    previewImage = nil
    cropViewportToken += 1
    registerUndo(old: previous, name: "恢复设置副本")
    project = next
    expectedModification = saved
    dirty = false
    saveFailure = false
    errorMessage = nil
    render()
    refreshThumbnails(changedFrom: previous, to: next)
    status = "已恢复本卷设置副本"
  }
  func exportPanel() {
    guard let project, let frame = activeFrame, let folder, !isExporting, !isCropping else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.tiff]
    panel.nameFieldStringValue = URL(fileURLWithPath: frame.filename).deletingPathExtension().lastPathComponent + "_Printroom.tiff"
    panel.directoryURL = folder.appendingPathComponent("Printroom Exports", isDirectory: true)
    panel.title = "导出当前照片"
    panel.prompt = "导出"
    let options = ExportOptionsView(settings: project.exportSettings)
    options.attach(to: panel)
    guard panel.runModal() == .OK, let destination = panel.url,
      self.project?.id == project.id, !isExporting else { return }
    setExportSettings(options.settings)
    startExport(targetIDs: [frame.id], directory: destination.deletingLastPathComponent(), explicitDestination: destination)
  }
  func batchExportPanel(allFrames: Bool) {
    guard let project, !isExporting, !isCropping else { return }
    let targets = allFrames ? Set(project.frames.map(\.id)) : selection.selectedFrameIDs
    guard !targets.isEmpty else { return }
    let panel = NSOpenPanel()
    panel.title = "导出\(allFrames ? "整卷" : "选中照片") · \(targets.count) 张 · 选择输出文件夹"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = folder?.appendingPathComponent("Printroom Exports", isDirectory: true)
    panel.prompt = "导出"
    let options = ExportOptionsView(settings: project.exportSettings)
    options.attach(to: panel)
    guard panel.runModal() == .OK, let directory = panel.url,
      self.project?.id == project.id, !isExporting else { return }
    setExportSettings(options.settings)
    startExport(targetIDs: targets, directory: directory)
  }
  func startExport(targetIDs: Set<UUID>, directory: URL, explicitDestination: URL? = nil) {
    guard let project, let assets, !isExporting else { return }
    do {
      // Captures targets, source identities, calibration, frame edits, orientation, and output settings now.
      let request = try ExportRequest(project: project, targetIDs: targetIDs,
        destinationDirectory: directory, explicitDestination: explicitDestination)
      exportGeneration = UUID()
      let generation = exportGeneration
      isExporting = true
      exportProgress = 0
      exportDetail = "准备导出 \(targetIDs.count) 张"
      exportSummary = nil
      showExportSummary = false
      status = "导出已开始；可以继续调色与切图"
      exportTask = Task {
        do {
          let summary = try await exportEngine.run(request, lut: assets.lut, p3Profile: assets.profile) { progress in
            Task { @MainActor [weak self] in
              guard let self, self.exportGeneration == generation, self.isExporting else { return }
              self.exportProgress = progress.fraction
              self.exportDetail = "\(progress.processedCount)/\(progress.totalCount) · \(progress.currentName ?? "")"
            }
          }
          exportSummary = summary
          status = "\(summary.wasCancelled ? "导出已取消" : "导出完成") · 成功 \(summary.completedCount) · 失败 \(summary.failedCount)"
          showExportSummary = true
        } catch {
          errorMessage = error.localizedDescription
          status = "导出未完成"
        }
        isExporting = false
      }
    } catch { errorMessage = error.localizedDescription }
  }
  func cancelExport() { exportTask?.cancel(); exportDetail = "正在取消；保留已完成文件…" }
  func clearThumbnailCache() {
    guard let folder else { return }
    thumbnailTask?.cancel()
    thumbnailGeneration = UUID()
    thumbnails = [:]
    let cache = DiskThumbnailCache(directory: folder.appendingPathComponent(".printroom-cache"))
    Task {
      do {
        await thumbnailService.clear()
        let result = try await cache.clear()
        status = "已清理 \(result.removedFiles) 个缩略图缓存；重新生成当前卷"
        refreshThumbnails()
      } catch { errorMessage = error.localizedDescription }
    }
  }
  private func refreshThumbnails(changedFrom old: RollProject, to next: RollProject) {
    guard old.calibration == next.calibration else { refreshThumbnails(); return }
    let previous = Dictionary(uniqueKeysWithValues: old.frames.map { ($0.id, $0) })
    refreshThumbnails(affectedIDs: Set(next.frames.filter { previous[$0.id] != $0 }.map(\.id)))
  }
  private func refreshThumbnails(affectedIDs: Set<UUID>? = nil) {
    guard let project, let folder, let assets else { return }
    let available = Set(project.frames.filter { !$0.isMissing }.map(\.id))
    pendingThumbnailIDs.formUnion(affectedIDs ?? available)
    pendingThumbnailIDs.formIntersection(available)
    if thumbnails.keys.contains(where: { !available.contains($0) }) {
      thumbnails = thumbnails.filter { available.contains($0.key) }
    }
    thumbnailTask?.cancel()
    thumbnailGeneration = UUID()
    guard !pendingThumbnailIDs.isEmpty else { return }
    let generation = thumbnailGeneration
    let frames = project.frames.filter { pendingThumbnailIDs.contains($0.id) }
      .sorted { $0.id == selection.activeFrameID && $1.id != selection.activeFrameID }
    let cache = DiskThumbnailCache(directory: folder.appendingPathComponent(".printroom-cache", isDirectory: true))
    thumbnailTask = Task {
      if affectedIDs == nil { _ = try? await cache.maintain() }
      for frame in frames {
        guard !Task.isCancelled, generation == thumbnailGeneration else { return }
        do {
          let sourceURL = folder.appendingPathComponent(frame.filename)
          let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
          let encoder = JSONEncoder()
          encoder.outputFormatting = .sortedKeys
          let keyData = try encoder.encode(
            ThumbnailKey(
              filename: frame.filename,
              modified: (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
              size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
              inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
              calibration: project.calibration, adjustments: frame.adjustments,
              orientation: frame.orientation,
              crop: frame.crop,
              algorithm: algorithmVersion, icc: ProjectAssetIdentity.expectedICCSHA256,
              lut: ProjectAssetIdentity.expectedLUTSHA256, dimension: 240,
              presentationVersion: DisplayImage.presentationVersion))
          let key = SHA256.hash(data: keyData).map { String(format: "%02x", $0) }.joined()
          if let cg = try? await cache.image(for: key) {
            guard !Task.isCancelled, generation == thumbnailGeneration else { return }
            thumbnails[frame.id] = cg
            pendingThumbnailIDs.remove(frame.id)
            continue
          }
          let source = try await thumbnailService.thumbnailSource(sourceURL)
          let output = try await thumbnailRenderer.render(source.0,
            calibration: project.calibration, adjustments: frame.adjustments,
            assets: assets, orientation: frame.orientation, crop: frame.crop,
            sourceWidth: source.1, sourceHeight: source.2)
          guard !Task.isCancelled, generation == thumbnailGeneration else { return }
          thumbnails[frame.id] = output.image
          // Expendable disk cache failures never prevent editing or project save.
          try? await cache.store(output.image, for: key)
          guard !Task.isCancelled, generation == thumbnailGeneration else { return }
          pendingThumbnailIDs.remove(frame.id)
        } catch {
          if !Task.isCancelled && generation == thumbnailGeneration { status = "缩略图不可用：\(frame.filename)" }
        }
      }
    }
  }
  func relocatePanel(_ frameID: UUID) {
    guard let frame = project?.frames.first(where: { $0.id == frameID }), frame.isMissing else { return }
    let panel = NSOpenPanel()
    panel.title = "重新定位 \(frame.filename) · 选择本卷中的 TIFF"
    panel.allowedContentTypes = [.tiff]
    panel.directoryURL = folder
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    relocate(frameID, to: url)
  }
  func relocate(_ frameID: UUID, to url: URL) {
    guard let project, let folder else { return }
    do {
      let next = try ProjectStore.relocate(project, frameID: frameID, to: url, folder: folder)
      registerUndo(old: project, name: "重新定位照片")
      self.project = next
      dirty = true
      // Reconcile selection by stable ID after merging a newly discovered placeholder.
      selection = SelectionState()
      selection.click(frameID, ordered: next.frames.filter { !$0.isMissing }.map(\.id))
      self.project?.lastActiveFrameID = frameID
      loadActive()
      refreshThumbnails()
      scheduleSave(immediate: true)
      status = "已重新定位；保留照片 ID、调色与方向"
    } catch { errorMessage = error.localizedDescription }
  }
  func setOutputProfile(_ profile: OutputColorProfile) {
    var settings = exportSettings
    settings.profile = profile
    setExportSettings(settings)
  }
  func setOutputCompression(_ compression: TIFFCompression) {
    var settings = exportSettings
    settings.compression = compression
    setExportSettings(settings)
  }
  func setExportSettings(_ settings: ProjectExportSettings) {
    guard project != nil, exportSettings != settings else { return }
    project?.exportSettings = settings
    dirty = true
    scheduleSave(immediate: true)
  }
  private struct ThumbnailKey: Codable {
    let filename: String
    let modified: Double
    let size: Int64
    let inode: UInt64
    let calibration: FilmCalibration
    let adjustments: FrameAdjustments
    let orientation: FrameOrientation
    let crop: FrameCrop?
    let algorithm: String
    let icc: String
    let lut: String
    let dimension: Int
    let presentationVersion: String
  }
  private var timingTask: Task<Void, Never>?
  private var heldTimingKey: String?

  func stopTimingKey(_ key: String? = nil) {
    guard let held = heldTimingKey, key == nil || key?.lowercased() == held else { return }
    timingTask?.cancel()
    timingTask = nil
    heldTimingKey = nil
    endAdjustment()
  }

  func startTimingKey(_ key: String, shift: Bool, isRepeat: Bool,
                      canContinue: @escaping @MainActor () -> Bool) {
    let key = key.lowercased()
    guard !isRepeat, key.count == 1, "qeadzcws".contains(key), activeFrame != nil else { return }
    stopTimingKey()
    beginAdjustment()
    heldTimingKey = key
    handleTimingKey(key, step: shift ? 10 : 1)
    let frameID = selection.activeFrameID
    let clock = ContinuousClock()
    let start = clock.now
    timingTask = Task { [weak self] in
      // Accumulate integer CV at 20 Hz while leaving time for preview rendering.
      do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
      var applied = 0
      while !Task.isCancelled {
        guard let self else { return }
        guard self.selection.activeFrameID == frameID, canContinue(),
          self.errorMessage == nil, !self.showExportSummary else {
          self.stopTimingKey()
          return
        }
        let elapsed = start.duration(to: clock.now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        let total = Self.heldTimingCV(elapsed: seconds)
        if total > applied {
          self.handleTimingKey(key, step: total - applied)
          applied = total
        }
        do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
      }
    }
  }

  static func heldTimingCV(elapsed: Double) -> Int {
    Int((max(0, elapsed - 0.4) * 50 + 1e-9).rounded(.down))
  }

  func handleTimingKey(_ key: String, step: Int = 1) {
    guard activeFrame != nil else { return }
    let step = max(0, min(TimingParameters.range.count - 1, step))
    edit { a in
      switch key.lowercased() {
      case "q": a.timing.red = max(TimingParameters.range.lowerBound, a.timing.red - step)
      case "e": a.timing.red = min(TimingParameters.range.upperBound, a.timing.red + step)
      case "a": a.timing.green = max(TimingParameters.range.lowerBound, a.timing.green - step)
      case "d": a.timing.green = min(TimingParameters.range.upperBound, a.timing.green + step)
      case "z": a.timing.blue = max(TimingParameters.range.lowerBound, a.timing.blue - step)
      case "c": a.timing.blue = min(TimingParameters.range.upperBound, a.timing.blue + step)
      case "w": a.timing.master = min(TimingParameters.range.upperBound, a.timing.master + step)
      case "s": a.timing.master = max(TimingParameters.range.lowerBound, a.timing.master - step)
      default: break
      }
    }
  }
}
