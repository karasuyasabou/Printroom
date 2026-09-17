import AppKit
import CryptoKit
import ImageIO
import PrintroomCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class EditorModel: ObservableObject {
  private let timingDefaults: UserDefaults
  @Published var timingMode: TimingMode {
    didSet {
      guard timingMode != oldValue else { return }
      stopTimingKey()
      timingDefaults.set(timingMode.rawValue, forKey: TimingMode.preferenceKey)
    }
  }
  @Published var matrixLibrary: [MatrixLibraryEntry] = []
  @Published var matrixLibraryError: String?
  @Published var matrixManager: MatrixKind?
  @Published var showMatrixMenu = false
  let matrixStore: MatrixLibraryStore
  @Published var project: RollProject?
  @Published var folder: URL?
  @Published var selection = SelectionState()
  @Published var snapshot: ParameterSnapshot?
  @Published var previewImage: CGImage? {
    didSet { if previewImage == nil { cropPreviewTransition = nil } }
  }
  // Retain the geometry belonging to the visible image until its replacement arrives.
  // This is display-only state, never a crop or sampling source.
  struct CropPreviewTransition {
    let size: CGSize
    let isCropping: Bool
    let geometry: CropGeometry?
    let detailImage: CGImage?
    let detailRect: PixelRect?
  }
  private(set) var cropPreviewTransition: CropPreviewTransition?
  private func retainCropPreview() {
    guard cropPreviewTransition == nil, previewImage != nil, previewInput != nil else { return }
    cropPreviewTransition = CropPreviewTransition(
      size: CGSize(width: displayWidth, height: displayHeight), isCropping: isCropping,
      geometry: cropDraftGeometry, detailImage: detailImage, detailRect: detailRect)
  }
  @Published private(set) var isPreviewPlaceholder = false
  @Published var histogram: HistogramStatistics?
  @Published var histogramStage: PipelineStage = .final {
    didSet {
      guard histogramStage != oldValue else { return }
      render()
    }
  }
  var isHistogramUpdating: Bool { isRendering && !isCropping }
  @Published var detailImage: CGImage?
  @Published var detailRect: PixelRect?
  @Published var isDetailLoading = false
  @Published var nativeZoomToken = 0
  @Published var thumbnails: [UUID: CGImage] = [:]
  @Published var stage: PipelineStage = .final {
    didSet {
      guard stage != oldValue else { return }
      previewImage = nil
      isPreviewPlaceholder = false
      render()
      showCachedPreview()
    }
  }
  @Published var sampling = false {
    didSet {
      guard sampling != oldValue else { return }
      if sampling { cancelNeutralPicker() }
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
  @Published private(set) var isAutoCropping = false
  @Published private(set) var autoCropProgressText = ""
  @Published private(set) var autoCropCompletedRun = 0
  @Published var reviewOnlyPendingCrops = false
  @Published private var cropReviewSession = false
  private var autoCropTask: Task<Void, Never>?
  private var autoCropGeneration = UUID()
  typealias AutoCropRunner = @Sendable ([AutoCropInput], Set<UUID>, @escaping @Sendable (String) async -> Void) async throws -> [AutoCropOutput]
  var autoCropRunner: AutoCropRunner = { inputs, targets, progress in
    try await AutoCropService.run(inputs: inputs, targets: targets, progress: progress)
  }
  var pendingAutoCropFrameIDs: Set<UUID> {
    Set(project?.frames.filter { !$0.isMissing && $0.cropNeedsReview }.map(\.id) ?? [])
  }
  var cropReviewAvailable: Bool { cropReviewSession || !pendingAutoCropFrameIDs.isEmpty }
  var canStartAutoCrop: Bool {
    project != nil && !isAutoCropping && !isCropping && !isLoading && !isExporting
      && project?.frames.contains(where: { !$0.isMissing }) == true
  }
  @Published var status = "打开 TIFF 或 ARW，开始整卷调色"
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
  @Published private(set) var neutralPicking = false
  @Published private(set) var isNeutralSampling = false
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
    let histogramStage: PipelineStage
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
  private var neutralTask: Task<Void, Never>?
  private var neutralRevision = 0
  typealias NeutralSolver = @Sendable (
    PixelBuffer, FilmCalibration, FrameAdjustments, CubeLUT, Data
  ) throws -> FrameAdjustments
  private let neutralSolver: NeutralSolver
  private var previewSourceStamp: PreviewSourceStamp?
  private var presentationCache = PreviewPresentationCache()
  private var thumbnailPresentationKeys: [UUID: PreviewPresentationKey] = [:]
  private var loadTask: Task<Void, Never>?
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
  var hasImage: Bool { previewImage != nil && activeFrame != nil && !isPreviewPlaceholder && !isLoading && cropPreviewTransition == nil }
  var canPickNeutral: Bool { hasImage && !isCropping && !sampling && !isNeutralSampling && !isRendering }
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

  let recentRolls: RecentRolls?

  init(recentRolls: RecentRolls? = nil, timingDefaults: UserDefaults = .standard, matrixStore: MatrixLibraryStore = .init(), neutralSolver: @escaping NeutralSolver = { samples, calibration, adjustments, lut, profile in
    try NeutralTiming.solve(samples, calibration: calibration, adjustments: adjustments,
      lut: lut, p3Profile: profile)
  }) {
    self.timingDefaults = timingDefaults
    self.timingMode = TimingMode(rawValue: timingDefaults.string(forKey: TimingMode.preferenceKey) ?? "") ?? .simple
    self.recentRolls = recentRolls
    self.matrixStore = matrixStore
    self.neutralSolver = neutralSolver
    do { matrixLibrary = try matrixStore.load() }
    catch { matrixLibraryError = error.localizedDescription }
    undoManager.groupsByEvent = false
    do { assets = try AppAssets() } catch { errorMessage = error.localizedDescription }
  }
  func openPanel() {
    guard !isExporting else { return }
    let panel = NSOpenPanel()
    panel.title = "打开 TIFF、ARW 或整卷文件夹"
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.tiff, UTType(filenameExtension: "arw") ?? .rawImage]
    if panel.runModal() == .OK, let url = panel.url { open(url) }
  }
  func openRecent(_ entry: RecentRoll) {
    guard !isExporting else { return }
    var directory: ObjCBool = false
    if FileManager.default.fileExists(atPath: entry.path, isDirectory: &directory), directory.boolValue {
      open(entry.url)
      return
    }
    let panel = NSOpenPanel()
    panel.title = "重新定位胶卷：\(entry.url.lastPathComponent)"
    panel.message = "原位置不可用，请连接硬盘后重试，或选择这卷的新位置。"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let roll = try ProjectStore.open(folder: url)
      guard roll.id == entry.projectID else {
        errorMessage = "所选文件夹不是这卷胶卷。请选取包含原胶卷设置的文件夹，或使用打开按钮打开其他胶卷。"
        return
      }
      open(url, replacingRecent: entry.path)
    } catch { errorMessage = error.localizedDescription }
  }
  func open(_ url: URL, discardUnsaved: Bool = false, replacingRecent: String? = nil) {
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
    cancelAutoCrop()
    resetAutoCropReview()
    cancelGeometryPreparation()
    let targetFolder = isDirectory.boolValue ? url : url.deletingLastPathComponent()
    let preferred = isDirectory.boolValue ? nil : url
    do {
      var roll = try ProjectStore.open(folder: targetFolder, preferredFile: preferred)
      if let source = roll.frames.first(where: { $0.id == roll.calibration.sourceFrameID }),
        let previous = source.rawProcessing,
        previous != (try? SourceImageIO.processingIdentity(url: targetFolder.appendingPathComponent(source.filename))) {
        roll.calibrationNeedsReview = true
      }
      if folder != targetFolder { snapshot = nil }
      thumbnails = [:]
      thumbnailPresentationKeys = [:]
      presentationCache.clear()
      pendingThumbnailIDs = []
      baseStatistics = ""
      loadTask?.cancel()
      renderTask?.cancel()
      thumbnailTask?.cancel()
      saveTask?.cancel()
      folder = targetFolder
      project = roll
      recentRolls?.record(folder: targetFolder, projectID: roll.id, replacing: replacingRecent)
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
  func returnHome() {
    guard project != nil, !isExporting else { return }
    stopTimingKey()
    endAdjustment()
    guard saveCropBeforeSwitching(), flushSave() else { return }
    cancelAutoCrop()
    resetAutoCropReview()
    project = nil
    folder = nil
    selection = SelectionState()
    snapshot = nil
    loadActive()
    thumbnailTask?.cancel()
    thumbnailGeneration = UUID()
    pendingThumbnailIDs = []
    thumbnails = [:]
    thumbnailPresentationKeys = [:]
    presentationCache.clear()
    preparedGeometryMetadata = [:]
    expectedModification = nil
    gestureBefore = nil
    baseStatistics = ""
    showSync = false
    matrixManager = nil
    showMatrixMenu = false
    showExportSummary = false
    exportSummary = nil
    undoManager.removeAllActions()
    undoRevision += 1
    errorMessage = nil
    status = "打开 TIFF 或 ARW，开始整卷调色"
  }

  func select(_ id: UUID, command: Bool = false, shift: Bool = false) {
    stopTimingKey()
    guard let project else { return }
    let old = selection.activeFrameID
    var nextSelection = selection
    nextSelection.click(
      id, ordered: project.frames.filter { !$0.isMissing }.map(\.id), command: command, shift: shift
    )
    if old != nextSelection.activeFrameID, !saveCropBeforeSwitching() { return }
    selection = nextSelection
    if old != selection.activeFrameID { loadActive(preservingCropMode: isCropping) }
    self.project?.lastActiveFrameID = selection.activeFrameID
    dirty = true
    scheduleSave()
  }
  private func saveCropBeforeSwitching(confirm: Bool = false) -> Bool {
    // A loading frame has no editable draft; nil must not clear its saved crop.
    guard isCropping, !isLoading, sourceWidth > 0, sourceHeight > 0,
      var next = project,
      let index = next.frames.firstIndex(where: { $0.id == selection.activeFrameID })
    else { return true }
    do {
      next.frames[index].crop = try cropDraft?.sourceCoordinates(sourceWidth: sourceWidth,
        sourceHeight: sourceHeight, orientation: orientation)
        .constrained(sourceWidth: sourceWidth, sourceHeight: sourceHeight)
      guard let old = project else { return true }
      if confirm || next.frames[index].crop != old.frames[index].crop {
        next.frames[index].cropOrigin = .manual
        next.frames[index].cropNeedsReview = false
      }
      guard next.frames != old.frames else { return true }
      registerUndo(old: old, name: "裁剪照片")
      project = next
      dirty = true
      refreshThumbnails(affectedIDs: [next.frames[index].id])
      scheduleSave(immediate: true)
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }
  func selectAdjacentFrame(_ delta: Int) {
    let frames = project?.frames.filter { !$0.isMissing && (!isCropping || !reviewOnlyPendingCrops || $0.cropNeedsReview) } ?? []
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
  private var rawPreparationTask: Task<Void, Never>?
  private func prepareRAWProxies() {
    rawPreparationTask?.cancel()
    guard let project, let folder else { return }
    let active = selection.activeFrameID
    let urls = project.frames.filter { !$0.isMissing && SourceImageIO.isRAW(folder.appendingPathComponent($0.filename)) }
      .sorted { $0.id == active && $1.id != active }
      .map { folder.appendingPathComponent($0.filename) }
    guard !urls.isEmpty else { return }
    rawPreparationTask = Task { await RAWPrewarmer.prepare(urls) }
  }
  func loadActive(preservingCropMode: Bool = false) {
    rawPreparationTask?.cancel()
    cancelGeometryPreparation()
    isCropping = preservingCropMode
    cropDraft = nil
    sampling = false
    cancelSampling()
    cancelNeutralPicker()
    isRendering = false
    embeddedProfile = ""
    loadTask?.cancel()
    cancelPreviewWorker()
    previewContext = nil
    loadRevision += 1
    renderRevision += 1
    let revision = loadRevision
    histogram = nil
    invalidateDetail()
    previewImage = nil
    isPreviewPlaceholder = false
    previewSourceStamp = nil
    previewInput = nil
    sourceWidth = 0
    sourceHeight = 0
    guard let frame = activeFrame, let folder else {
      isLoading = false
      isRendering = false
      return
    }
    isLoading = true
    let url = folder.appendingPathComponent(frame.filename)
    if SourceImageIO.isRAW(url) { status = "正在准备 RAW 预览：\(frame.filename)" }
    previewSourceStamp = try? PreviewSourceStamp(url: url)
    showCachedPreview()
    loadTask = Task {
      do {
        let result = try await imageService.preview(url)
        guard !Task.isCancelled, revision == loadRevision else { return }
        let stamp = try PreviewSourceStamp(url: url)
        guard stamp == previewSourceStamp else {
          throw PrintroomError.invalid("读取期间源图像已改变，请重新打开照片")
        }
        previewInput = result.0
        previewInputIdentity = UUID()
        sourceWidth = result.1
        sourceHeight = result.2
        embeddedProfile = result.3
        if isCropping {
          let initial = frame.crop ?? FrameCrop(aspect: .free, freeRatio: Double(sourceWidth) / Double(sourceHeight))
          cropDraft = try initial.sourceCoordinates(sourceWidth: sourceWidth,
            sourceHeight: sourceHeight, orientation: frame.orientation)
          cropViewportToken += 1
        }
        if SourceImageIO.isRAW(url), let index = project?.frames.firstIndex(where: { $0.id == frame.id }) {
          let identity = try SourceImageIO.processingIdentity(url: url)
          if let previous = project?.frames[index].rawProcessing, previous != identity,
            project?.calibration.sourceFrameID == frame.id { project?.calibrationNeedsReview = true }
          project?.frames[index].rawProcessing = identity
          dirty = true
          scheduleSave()
          status = "RAW 预览已就绪：\(frame.filename)"
        }
        isLoading = false
        render()
      } catch {
        if !Task.isCancelled && revision == loadRevision {
          isLoading = false
          previewImage = nil
          isPreviewPlaceholder = false
          errorMessage = error.localizedDescription
        }
      }
    }
    prepareRAWProxies()
  }
  private func cancelPreviewWorker() {
    renderTask?.cancel()
    renderTask = nil
    pendingPreview = nil
    renderGeneration = UUID()
  }
  private func presentationKey(stage: PipelineStage? = nil) -> PreviewPresentationKey? {
    guard let source = previewSourceStamp, let frame = activeFrame, let project else { return nil }
    return PreviewPresentationKey(source: source, frameID: frame.id,
      calibration: project.calibration, adjustments: frame.adjustments,
      orientation: frame.orientation, crop: displayedCrop, stage: stage ?? self.stage)
  }
  private func showCachedPreview() {
    guard isLoading || isRendering, previewImage == nil || isPreviewPlaceholder,
      let key = presentationKey() else { return }
    if let entry = presentationCache.image(for: key) {
      sourceWidth = entry.sourceWidth
      sourceHeight = entry.sourceHeight
      previewImage = entry.image
      isPreviewPlaceholder = true
    } else if stage == .final, thumbnailPresentationKeys[key.frameID] == key,
      let image = thumbnails[key.frameID] {
      previewImage = image
      isPreviewPlaceholder = true
    }
  }
  private func publishThumbnail(_ image: CGImage, key: PreviewPresentationKey) {
    guard (try? PreviewSourceStamp(url: key.source.url)) == key.source else { return }
    thumbnails[key.frameID] = image
    thumbnailPresentationKeys[key.frameID] = key
    if activeFrame?.id == key.frameID { showCachedPreview() }
  }
  func render() {
    cancelNeutralPicker()
    if histogram?.stage != histogramStage { histogram = nil }
    invalidateDetail()
    renderRevision += 1
    guard let input = previewInput, let project, let frame = activeFrame, let assets else { return }
    let context = PreviewContext(source: previewInputIdentity, frameID: frame.id,
      calibration: project.calibration, stage: stage, histogramStage: histogramStage, orientation: frame.orientation,
      crop: displayedCrop, sourceWidth: sourceWidth, sourceHeight: sourceHeight)
    // Geometry/source/stage changes invalidate in-flight work. Ordinary edits keep
    // the current job alive and replace the single pending snapshot instead.
    if context != previewContext {
      histogram = nil
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
            sourceHeight: request.context.sourceHeight, includeHistogram: !isCropping,
            histogramStage: request.context.histogramStage)
          guard !Task.isCancelled, generation == renderGeneration,
            previewContext == request.context, activeFrame?.id == request.context.frameID else { return }
          // One serial worker publishes snapshots in increasing order, including
          // while input continues faster than rendering. The next job reads only
          // the latest pending edit; an older result cannot overwrite a newer one.
          // Publish one matched snapshot in a single main-actor turn, without suspension.
          cropPreviewTransition = nil
          histogram = result.histogram
          previewImage = result.image
          isPreviewPlaceholder = false
          if let source = previewSourceStamp {
            let key = PreviewPresentationKey(source: source, frameID: request.context.frameID,
              calibration: request.context.calibration, adjustments: request.adjustments,
              orientation: request.context.orientation, crop: request.context.crop,
              stage: request.context.stage)
            presentationCache.store(.init(key: key, image: result.image,
              sourceWidth: request.context.sourceWidth, sourceHeight: request.context.sourceHeight))
          }
          if request.revision == renderRevision {
            isRendering = false
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
  var canChangeSelectedOrientations: Bool {
    project != nil && !selection.selectedFrameIDs.isEmpty && !isCropping && !isLoading
  }

  func changeSelectedOrientations(_ operation: OrientationOperation) {
    guard canChangeSelectedOrientations, let old = project, let folder else { return }
    stopTimingKey()
    let targets = selection.selectedFrameIDs
    let legacyURLs = old.frames.filter { targets.contains($0.id) && $0.crop?.geometryVersion == 1 }
      .map { folder.appendingPathComponent($0.filename) }
    if prepareGeometryIfNeeded(legacyURLs, then: { self.changeSelectedOrientations(operation) }) { return }
    do {
      guard targets.isSubset(of: Set(old.frames.filter { !$0.isMissing }.map(\.id))) else {
        throw PrintroomError.invalid("所选底片包含不可用照片")
      }
      var next = old
      for index in next.frames.indices where targets.contains(next.frames[index].id) {
        let frame = next.frames[index]
        let url = folder.appendingPathComponent(frame.filename)
        guard FileManager.default.fileExists(atPath: url.path) else {
          throw PrintroomError.invalid("目标文件已丢失：\(frame.filename)")
        }
        if frame.crop?.geometryVersion == 1 {
          let metadata = try geometryMetadata(url)
          next.frames[index].crop = try frame.crop?.sourceCoordinates(
            sourceWidth: metadata.width, sourceHeight: metadata.height, orientation: frame.orientation)
        }
        next.frames[index].orientation = frame.orientation.applying(operation)
      }
      guard next.frames != old.frames else { return }
      registerUndo(old: old, name: "调整\(targets.count)张底片方向")
      cancelSampling()
      previewImage = nil
      project = next
      dirty = true
      render()
      refreshThumbnails(affectedIDs: targets)
      scheduleSave(immediate: true)
    } catch { errorMessage = error.localizedDescription }
  }

  private func resetAutoCropReview() {
    reviewOnlyPendingCrops = false
    cropReviewSession = false
  }
  func cancelAutoCrop() {
    autoCropTask?.cancel()
    autoCropTask = nil
    autoCropGeneration = UUID()
    isAutoCropping = false
    autoCropProgressText = ""
  }
  func autoCropTargetCount(preserveExisting: Bool) -> Int {
    project?.frames.filter {
      !$0.isMissing && (!preserveExisting || ($0.crop == nil && $0.cropOrigin == nil))
    }.count ?? 0
  }
  func startAutoCrop(preserveExisting: Bool = true, inwardPercent: Double = 0) {
    guard canStartAutoCrop, let old = project, let folder else { return }
    guard inwardPercent.isFinite, (0...5).contains(inwardPercent) else {
      errorMessage = "向内裁切百分比必须在 0% 到 5% 之间。"
      return
    }
    stopTimingKey()
    endAdjustment()
    let frames = old.frames.filter { !$0.isMissing }
    let targets = Set(frames.filter {
      !preserveExisting || ($0.crop == nil && $0.cropOrigin == nil)
    }.map(\.id))
    guard !targets.isEmpty else {
      autoCropCompletedRun += 1
      return
    }
    let inputs = frames.map { AutoCropInput(id: $0.id, url: folder.appendingPathComponent($0.filename)) }
    let generation = UUID()
    autoCropGeneration = generation
    isAutoCropping = true
    autoCropProgressText = "准备自动裁切…"
    let runner = autoCropRunner
    autoCropTask = Task {
      do {
        let results = try await runner(inputs, targets) { [weak model = self] text in
          await model?.updateAutoCropProgress(text, generation: generation)
        }
        guard !Task.isCancelled, autoCropGeneration == generation,
          var next = project, next.id == old.id, self.folder == folder else { return }
        guard Set(results.map(\.id)) == targets, results.count == targets.count else {
          throw PrintroomError.invalid("自动裁切未得到完整结果，原裁剪已保留。")
        }
        // Do not overwrite crop edits made while analysis was running. Unrelated
        // timing, orientation and calibration edits are retained from current state.
        for result in results {
          guard let before = old.frames.first(where: { $0.id == result.id }),
            let index = next.frames.firstIndex(where: { $0.id == result.id }),
            next.frames[index].filename == before.filename,
            next.frames[index].crop == before.crop,
            next.frames[index].cropOrigin == before.cropOrigin,
            next.frames[index].cropNeedsReview == before.cropNeedsReview,
            !next.frames[index].isMissing,
            try AutoCropSourceStamp(result.source.url) == result.source else {
            throw PrintroomError.invalid("照片或裁剪已改变，请重新运行自动裁切。")
          }
          var crop = result.crop
          crop.width *= 1 - inwardPercent * 0.02
          try crop.validate()
          next.frames[index].crop = crop
          next.frames[index].cropOrigin = .automatic
          next.frames[index].cropNeedsReview = result.needsReview
        }
        guard let current = project else { return }
        if current.frames != next.frames {
          registerUndo(old: current, name: "自动裁切 \(results.count) 张")
          retainCropPreview()
          project = next
          dirty = true
          cropViewportToken += 1
          render()
          refreshThumbnails(affectedIDs: targets)
          scheduleSave(immediate: true)
        }
        isAutoCropping = false
        autoCropProgressText = ""
        autoCropTask = nil
        autoCropCompletedRun += 1
      } catch {
        guard !Task.isCancelled, autoCropGeneration == generation else { return }
        isAutoCropping = false
        autoCropProgressText = ""
        autoCropTask = nil
        if !(error is CancellationError) { errorMessage = error.localizedDescription }
      }
    }
  }
  private func updateAutoCropProgress(_ text: String, generation: UUID) {
    guard autoCropGeneration == generation else { return }
    autoCropProgressText = text
  }
  func reviewAutoCrops() {
    guard !isAutoCropping, let frames = project?.frames.filter({ !$0.isMissing }), !frames.isEmpty else { return }
    let target = frames.first(where: { $0.cropNeedsReview })
      ?? frames.first(where: { $0.cropOrigin == .automatic }) ?? frames.first!
    guard saveCropBeforeSwitching() else { return }
    cropReviewSession = true
    reviewOnlyPendingCrops = !pendingAutoCropFrameIDs.isEmpty
    // Loading in crop mode creates the correct draft for this frame and keeps the
    // review controls usable when the currently displayed frame is still loading.
    selection.click(target.id, ordered: frames.map(\.id))
    project?.lastActiveFrameID = target.id
    dirty = true
    scheduleSave()
    loadActive(preservingCropMode: true)
  }
  func confirmCropAndAdvance() {
    guard isCropping, !isLoading, let id = selection.activeFrameID,
      let frames = project?.frames.filter({ !$0.isMissing }),
      let index = frames.firstIndex(where: { $0.id == id }),
      saveCropBeforeSwitching(confirm: true) else { return }
    let remaining = project?.frames.filter { !$0.isMissing && (!reviewOnlyPendingCrops || $0.cropNeedsReview) } ?? []
    let after = Set(frames.dropFirst(index + 1).map(\.id))
    if let next = remaining.first(where: { after.contains($0.id) }) {
      select(next.id)
    } else if reviewOnlyPendingCrops, let next = remaining.first {
      select(next.id)
    } else {
      reviewOnlyPendingCrops = false
      commitCrop()
      cropReviewSession = false
    }
  }

  func beginCrop() {
    guard !isAutoCropping, !isCropping, !isLoading, !isPreviewPlaceholder, activeFrame != nil,
      sourceWidth > 0, sourceHeight > 0 else { return }
    stopTimingKey()
    cancelSampling()
    sampling = false
    let initial = activeFrame?.crop ?? FrameCrop(aspect: .free, freeRatio: Double(sourceWidth) / Double(sourceHeight))
    do {
      let draft = try initial.sourceCoordinates(sourceWidth: sourceWidth,
        sourceHeight: sourceHeight, orientation: orientation)
      retainCropPreview()
      cropDraft = draft
      isCropping = true
      cropViewportToken += 1
      render()
    } catch { errorMessage = error.localizedDescription }
  }
  func updateCropDraft(_ value: FrameCrop) {
    guard isCropping, !isLoading, sourceWidth > 0, sourceHeight > 0 else { return }
    do {
      cropDraft = try value.sourceCoordinates(sourceWidth: sourceWidth,
        sourceHeight: sourceHeight, orientation: orientation)
    } catch { errorMessage = error.localizedDescription }
  }
  func updateDisplayedCropDraft(_ value: FrameCrop) {
    updateCropDraft(value)
  }
  func nudgeCropDraft(horizontal: Double = 0, vertical: Double = 0) {
    guard isCropping, let displayed = displayedCropDraft else { return }
    var next = displayed
    next.centerX += horizontal
    next.centerY += vertical
    updateDisplayedCropDraft(next)
  }
  func nudgeCropAngle(_ delta: Double) {
    guard isCropping, delta.isFinite else { return }
    var draft = displayedCropDraft
      ?? FrameCrop(aspect: .free, geometryVersion: 1, freeRatio: Double(displayWidth) / Double(max(1, displayHeight)))
    draft.angleDegrees = (min(10, max(-10, draft.angleDegrees + delta)) * 100).rounded() / 100
    updateDisplayedCropDraft(draft)
  }
  func resetCropDraft() {
    guard isCropping else { return }
    cropDraft = nil
  }
  func cancelCrop() {
    guard isCropping else { return }
    retainCropPreview()
    isCropping = false
    cropDraft = nil
    cropViewportToken += 1
    render()
  }
  func commitCrop(syncSelection: Bool = false) {
    guard isCropping, !isLoading, sourceWidth > 0, sourceHeight > 0, let id = activeFrame?.id else { return }
    let targets = syncSelection ? selection.selectedFrameIDs : [id]
    applyCrop(cropDraft, targets: targets)
  }
  func syncCurrentCropToSelection() {
    guard canSyncCrop, let frame = activeFrame else { return }
    if isCropping { commitCrop(syncSelection: true) }
    else { applyCrop(frame.crop, targets: selection.selectedFrameIDs) }
  }
  // Prepared dimensions live only for the synchronous commit following this background job.
  var rawGeometryMetadataLoader: @Sendable (URL) throws -> TIFFMetadata = {
    try SourceImageIO.metadata(url: $0)
  }
  private var preparedGeometryMetadata: [URL: TIFFMetadata] = [:]
  @Published private(set) var isPreparingGeometry = false
  private var geometryPreparationTask: Task<Void, Never>?
  private var geometryPreparationToken = UUID()
  private func cancelGeometryPreparation() {
    geometryPreparationToken = UUID()
    geometryPreparationTask?.cancel()
    geometryPreparationTask = nil
    isPreparingGeometry = false
  }
  private func geometryProjectSnapshot(_ value: RollProject) -> Data? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try? encoder.encode(value)
  }
  private func geometrySourceRevisions(_ urls: [URL]) -> [URL: String] {
    Dictionary(uniqueKeysWithValues: Set(urls).map { url in
      let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
      let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
      let inode = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
      let date = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
      return (url, "\(size):\(inode):\(date)")
    })
  }
  private func geometryMetadata(_ url: URL) throws -> TIFFMetadata {
    if let value = preparedGeometryMetadata[url] { return value }
    guard !SourceImageIO.isRAW(url) else { throw PrintroomError.invalid("RAW 尺寸尚未准备") }
    return try TIFFCodec.metadata(url: url)
  }
  @discardableResult
  private func prepareGeometryIfNeeded(_ urls: [URL], then commit: @escaping @MainActor () -> Void) -> Bool {
    let rawURLs = Array(Set(urls.filter { SourceImageIO.isRAW($0) && preparedGeometryMetadata[$0] == nil }))
    guard !rawURLs.isEmpty, let previous = project else { return false }
    let encoded = geometryProjectSnapshot(previous)
    let revisions = geometrySourceRevisions(urls)
    let capturedFolder = folder, active = selection.activeFrameID, selected = selection.selectedFrameIDs
    let draft = cropDraft, cropping = isCropping, timing = syncTiming, contrast = syncContrast, lut = syncLUT, crop = syncCrop
    cancelGeometryPreparation()
    let token = UUID()
    geometryPreparationToken = token
    isPreparingGeometry = true
    status = "正在准备 RAW 原始尺寸…"
    let loader = rawGeometryMetadataLoader
    geometryPreparationTask = Task {
      defer {
        if geometryPreparationToken == token {
          isPreparingGeometry = false
          geometryPreparationTask = nil
        }
      }
      do {
        let worker = Task.detached(priority: .userInitiated) {
          var result: [URL: TIFFMetadata] = [:]
          for url in rawURLs {
            try Task.checkCancellation()
            result[url] = try loader(url)
            try Task.checkCancellation()
          }
          return result
        }
        let metadata = try await withTaskCancellationHandler {
          try await worker.value
        } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        guard geometryPreparationToken == token, folder == capturedFolder,
          project.flatMap({ geometryProjectSnapshot($0) }) == encoded,
          selection.activeFrameID == active, selection.selectedFrameIDs == selected,
          cropDraft == draft, isCropping == cropping, syncTiming == timing, syncContrast == contrast, syncLUT == lut, syncCrop == crop,
          geometrySourceRevisions(urls) == revisions
        else { return }
        preparedGeometryMetadata = metadata
        defer { preparedGeometryMetadata.removeAll() }
        commit()
      } catch {
        guard !Task.isCancelled, geometryPreparationToken == token, folder == capturedFolder else { return }
        errorMessage = error.localizedDescription
      }
    }
    return true
  }
  private func applyCrop(_ crop: FrameCrop?, targets: Set<UUID>) {
    guard let old = project, let folder, !targets.isEmpty else { return }
    let urls = old.frames.filter { targets.contains($0.id) }.map { folder.appendingPathComponent($0.filename) }
    if prepareGeometryIfNeeded(urls, then: { self.applyCrop(crop, targets: targets) }) { return }
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
        let metadata = try geometryMetadata(folder.appendingPathComponent(frame.filename))
        next.frames[index].crop = try sourceCrop?.constrained(sourceWidth: metadata.width,
          sourceHeight: metadata.height)
        next.frames[index].cropOrigin = .manual
        next.frames[index].cropNeedsReview = false
      }
      let changed = next.frames != old.frames
      retainCropPreview()
      if changed {
        registerUndo(old: old, name: targets.count > 1 ? "同步裁剪到 \(targets.count) 张" : "裁剪照片")
        project = next
        dirty = true
      }
      isCropping = false
      cropDraft = nil
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
          errorMessage = status
        }
      }
    }
  }
  func sampleDisplayedBase(_ rect: PixelRect) {
    do { sampleBase(try orientation.inverseRect(rect, sourceWidth: sourceWidth, sourceHeight: sourceHeight)) }
    catch { errorMessage = error.localizedDescription }
  }
  func toggleNeutralPicker() {
    if neutralPicking || isNeutralSampling { cancelNeutralPicker(); return }
    guard canPickNeutral else { return }
    stopTimingKey()
    neutralPicking = true
  }
  func cancelNeutralPicker() {
    neutralTask?.cancel()
    neutralTask = nil
    neutralRevision += 1
    neutralPicking = false
    isNeutralSampling = false
  }
  func pickNeutralDisplayed(x: Int, y: Int) {
    guard neutralPicking, canPickNeutral, let geometry = displayGeometry,
      let frame = activeFrame, let project, let folder, let assets,
      x >= 0, y >= 0, x < geometry.outputWidth, y < geometry.outputHeight else { return }
    let point = geometry.sourcePoint(outputX: Double(x) + 0.5, outputY: Double(y) + 0.5)
    let sx = max(0, min(sourceWidth - 1, Int(floor(point.x))))
    let sy = max(0, min(sourceHeight - 1, Int(floor(point.y))))
    // An 11×11 source-pixel neighbourhood, trimmed at the source edges.
    let left = max(0, sx - 5), top = max(0, sy - 5)
    let rect = PixelRect(x: left, y: top, width: min(sourceWidth, sx + 6) - left,
      height: min(sourceHeight, sy + 6) - top)
    neutralPicking = false
    isNeutralSampling = true
    let token = neutralRevision, revision = renderRevision, loadID = loadRevision
    let stamp = previewSourceStamp
    let width = sourceWidth, height = sourceHeight, expectedStage = stage
    let url = folder.appendingPathComponent(frame.filename)
    let solve = neutralSolver
    func contextIsCurrent() -> Bool {
      token == neutralRevision && revision == renderRevision && loadID == loadRevision
        && self.folder == folder && activeFrame == frame && self.project?.id == project.id
        && self.project?.calibration == project.calibration
        && sourceWidth == width && sourceHeight == height && stage == expectedStage
        && !sampling && !isCropping && previewSourceStamp == stamp
        && self.assets?.profile == assets.profile && self.assets?.lut.size == assets.lut.size
        && self.assets?.lut.values == assets.lut.values
    }
    neutralTask = Task {
      defer {
        if token == neutralRevision { isNeutralSampling = false; neutralTask = nil }
      }
      do {
        try Task.checkCancellation()
        guard contextIsCurrent() else { return }
        guard try PreviewSourceStamp(url: url) == stamp else {
          throw PrintroomError.invalid("源图像已改变，请重新打开照片后取样")
        }
        let samples = try await imageService.region(url, rect: rect)
        try Task.checkCancellation()
        guard try PreviewSourceStamp(url: url) == stamp else {
          throw PrintroomError.invalid("取样期间源图像已改变，请重新打开照片")
        }
        guard contextIsCurrent() else { return }
        let worker = Task.detached(priority: .userInitiated) {
          try Task.checkCancellation()
          return try solve(samples, project.calibration, frame.adjustments, assets.lut(for: frame.adjustments.cineonLogLUT), assets.profile)
        }
        let result = try await withTaskCancellationHandler {
          try await worker.value
        } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        guard contextIsCurrent() else { return }
        guard try PreviewSourceStamp(url: url) == stamp else {
          throw PrintroomError.invalid("标定期间源图像已改变，请重新打开照片")
        }
        // edit() is the same atomic frame transaction used by manual controls.
        edit(actionName: "标定 Final 中性点") { $0 = result }
      } catch {
        if !Task.isCancelled, contextIsCurrent() { errorMessage = error.localizedDescription }
      }
    }
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
  func edit(actionName: String = "调整参数", _ mutate: (inout FrameAdjustments) -> Void) {
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
    if gestureBefore == nil { registerUndo(old: old, name: actionName) }
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
    cancelAutoCrop()
    resetAutoCropReview()
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
  @Published var showSync = false
  @Published var syncTiming = false
  @Published var syncContrast = false
  @Published var syncLUT = false
  var hasSyncSelection: Bool { syncTiming || syncContrast || syncLUT || syncCrop }
  @Published var syncCrop = false
  var syncTargetIDs: Set<UUID> {
    selection.selectedFrameIDs.subtracting(selection.activeFrameID.map { [$0] } ?? [])
  }
  var canSync: Bool { activeFrame != nil && !syncTargetIDs.isEmpty && !isCropping && !isLoading }
  func beginSync() {
    guard canSync else { return }
    stopTimingKey()
    syncTiming = false
    syncContrast = false
    syncLUT = false
    syncCrop = false
    showSync = true
  }
  @discardableResult
  func syncCurrentSettings() -> Bool {
    guard canSync, hasSyncSelection, let source = activeFrame,
      let old = project, let folder else { return false }
    let targets = syncTargetIDs
    let urls = old.frames.filter { targets.contains($0.id) || $0.id == source.id }
      .map { folder.appendingPathComponent($0.filename) }
    if syncCrop, prepareGeometryIfNeeded(urls, then: { _ = self.syncCurrentSettings() }) { return false }
    do {
      guard targets.isSubset(of: Set(old.frames.filter { !$0.isMissing }.map(\.id))),
        !source.isMissing else { throw PrintroomError.invalid("同步包含不可用照片") }
      var crop: FrameCrop?
      if syncCrop, let savedCrop = source.crop {
        let metadata = try geometryMetadata(folder.appendingPathComponent(source.filename))
        crop = try savedCrop.sourceCoordinates(sourceWidth: metadata.width,
          sourceHeight: metadata.height, orientation: source.orientation)
      }
      if syncTiming || syncContrast || syncLUT {
        _ = try ParameterSnapshot(frame: source).applying(to: old, targets: targets)
      }
      var next = old
      for index in next.frames.indices where targets.contains(next.frames[index].id) {
        let url = folder.appendingPathComponent(next.frames[index].filename)
        guard FileManager.default.fileExists(atPath: url.path) else {
          throw PrintroomError.invalid("目标文件已丢失：\(url.lastPathComponent)")
        }
        if syncTiming { next.frames[index].adjustments.timing = source.adjustments.timing }
        if syncContrast { next.frames[index].adjustments.contrast = source.adjustments.contrast }
        if syncLUT { next.frames[index].adjustments.cineonLogLUT = source.adjustments.cineonLogLUT }
        if syncCrop {
          let metadata = try geometryMetadata(url)
          next.frames[index].crop = try crop?.constrained(sourceWidth: metadata.width,
            sourceHeight: metadata.height)
          next.frames[index].cropOrigin = .manual
          next.frames[index].cropNeedsReview = false
        }
      }
      guard next.frames != old.frames else {
        status = "所选照片的同步内容已相同"
        showSync = false
        return true
      }
      registerUndo(old: old, name: "同步到其余 \(targets.count) 张")
      project = next
      dirty = true
      refreshThumbnails(affectedIDs: targets)
      scheduleSave(immediate: true)
      status = "已同步到其余 \(targets.count) 张"
      showSync = false
      return true
    } catch {
      errorMessage = error.localizedDescription
      showSync = false
      return false
    }
  }
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
  var cmosMatrix: MatrixPreset { project?.calibration.cmosMatrix ?? .identity }
  func matrixOptions(_ kind: MatrixKind) -> [MatrixPreset] {
    var result = kind.builtIns + matrixLibrary.filter { $0.kind == kind }.map(\.preset)
    let selected = kind == .cmos ? cmosMatrix : matrix
    if !result.contains(selected) { result.append(selected) }
    return result
  }
  func isMatrixSnapshot(_ value: MatrixPreset, kind: MatrixKind) -> Bool {
    !value.isBuiltIn && !matrixLibrary.contains { $0.kind == kind && $0.preset == value }
  }
  func reloadMatrixLibrary() {
    do { matrixLibrary = try matrixStore.load(); matrixLibraryError = nil }
    catch { matrixLibraryError = error.localizedDescription }
  }
  func saveMatrix(_ preset: MatrixPreset, kind: MatrixKind, apply: Bool) throws {
    guard matrixLibraryError == nil, !preset.isBuiltIn else {
      throw PrintroomError.invalid("内置矩阵不可编辑；矩阵库读取失败时请先重新载入。")
    }
    if let previous = matrixLibrary.first(where: { $0.preset.id == preset.id }), previous.kind != kind {
      throw PrintroomError.invalid("不能改变矩阵的类型。")
    }
    var next = matrixLibrary.filter { $0.preset.id != preset.id }
    next.append(MatrixLibraryEntry(kind: kind, preset: preset))
    try matrixStore.save(next, replacing: matrixLibrary)
    matrixLibrary = next
    if apply { setMatrixPreset(preset, kind: kind) }
  }
  func deleteMatrix(_ preset: MatrixPreset) throws {
    guard matrixLibraryError == nil, !preset.isBuiltIn else {
      throw PrintroomError.invalid("内置矩阵不可删除；矩阵库读取失败时请先重新载入。")
    }
    let next = matrixLibrary.filter { $0.preset.id != preset.id }
    try matrixStore.save(next, replacing: matrixLibrary)
    matrixLibrary = next
    // The current roll, other rolls and undo snapshots retain their coefficients.
  }
  func setMatrix(_ matrix: PrintDensityMatrix) { setMatrixPreset(matrix, kind: .density) }
  func setMatrixPreset(_ preset: MatrixPreset, kind: MatrixKind) {
    guard let current = project, !preset.isBuiltIn || kind.builtIns.contains(preset) else { return }
    var target = pendingMatrixCalibration ?? current.calibration
    if kind == .cmos {
      guard target.cmosMatrix != preset else { return }
      target.cmosMatrix = preset
    } else {
      guard target.matrix != preset else { return }
      target.matrix = preset
    }
    stopTimingKey()
    cancelSampling()
    guard target != current.calibration else { return }
    do {
      guard target.isCalibrated else {
        commitMatrixCalibration(target, name: "切换\(kind.label)")
        return
      }
      let sourceURL = try calibrationSource(current)
      // Older projects can retain a base sampled under a different CMOS matrix.
      // Re-read that selection as well before promising alignment under the current one.
      if target.cmosMatrix == target.sampledCMOSMatrix {
        target = try Pipeline.recalibrate(target, matrix: target.matrix)
        commitMatrixCalibration(target, name: "切换\(kind.label)并对齐片基")
        return
      }
      guard let rect = target.selection, let sourceID = target.sourceFrameID else {
        throw PrintroomError.invalid("片基采样记录不完整，请重新框选片基。")
      }
      let requested = target
      let revision = sampleRevision
      pendingMatrixCalibration = requested
      status = "正在按新矩阵重新对齐片基…"
      sampleTask = Task {
        do {
          let result = try await imageService.sample(sourceURL, rect: rect,
            matrix: requested.matrix, frameID: sourceID, cmosMatrix: requested.cmosMatrix)
          guard !Task.isCancelled, revision == sampleRevision,
            let latest = self.project, latest.id == current.id,
            latest.calibration == current.calibration else { return }
          _ = try calibrationSource(latest)
          guard result.0.sourceWidth == requested.sourceWidth,
            result.0.sourceHeight == requested.sourceHeight else {
            throw PrintroomError.invalid("片基原图尺寸已改变，请重新框选片基。")
          }
          pendingMatrixCalibration = nil
          commitMatrixCalibration(result.0, name: "切换矩阵并对齐片基")
        } catch {
          guard !Task.isCancelled, revision == sampleRevision else { return }
          pendingMatrixCalibration = nil
          errorMessage = error.localizedDescription
          status = "重新对齐失败，已保留原矩阵和片基校准"
        }
      }
    } catch {
      errorMessage = error.localizedDescription
      status = "重新对齐失败，已保留原矩阵和片基校准"
    }
  }

  private func calibrationSource(_ roll: RollProject) throws -> URL {
    guard let folder, !roll.calibrationNeedsReview,
      let source = roll.frames.first(where: { $0.id == roll.calibration.sourceFrameID }),
      !source.isMissing else {
      throw PrintroomError.invalid("片基原图缺失或已改变，请恢复原图并重新框选片基。")
    }
    let url = folder.appendingPathComponent(source.filename)
    let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    guard Int64(values.fileSize ?? -1) == source.sourceSize,
      values.contentModificationDate?.timeIntervalSince1970 == source.sourceModified else {
      throw PrintroomError.invalid("片基原图已改变，请重新框选片基。")
    }
    if let previous = source.rawProcessing,
      previous != (try SourceImageIO.processingIdentity(url: url)) {
      throw PrintroomError.invalid("片基 RAW 处理方式已改变，请重新框选片基。")
    }
    return url
  }

  private func commitMatrixCalibration(_ calibration: FilmCalibration, name: String) {
    guard let old = project, var next = project, old.calibration != calibration else { return }
    next.calibration = calibration
    registerUndo(old: old, name: name)
    project = next
    dirty = true
    status = calibration.isCalibrated ? "整卷片基已重新对齐至 95 CV" : "已切换矩阵"
    render()
    refreshThumbnails()
    scheduleSave(immediate: true)
  }
  private var pendingMatrixCalibration: FilmCalibration?

  private func cancelSampling() {
    pendingMatrixCalibration = nil
    cancelNeutralPicker()
    sampleTask?.cancel()
    sampleRevision += 1
  }
  func sampleBase(_ rect: PixelRect) {
    guard let folder, let frame = activeFrame, let project else { return }
    cancelSampling()
    let revision = sampleRevision
    let id = frame.id
    let matrix = project.calibration.matrix
    let cmos = project.calibration.cmosMatrix
    let rollID = project.id
    sampling = false
    status = "正在采样原始像素…"
    sampleTask = Task {
      do {
        let result = try await imageService.sample(
          folder.appendingPathComponent(frame.filename), rect: rect, matrix: matrix, frameID: id, cmosMatrix: cmos)
        guard !Task.isCancelled, revision == sampleRevision, var next = self.project, next.id == rollID else { return }
        guard next.calibration.matrix == matrix, next.calibration.cmosMatrix == cmos else { return }
        next.calibration = result.0
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
    let urls = backup.frames.filter { $0.crop?.geometryVersion == 1 }
      .map { folder.appendingPathComponent($0.filename) }
      .filter { FileManager.default.fileExists(atPath: $0.path) }
    if prepareGeometryIfNeeded(urls, then: {
      do { try self.restoreBackup(data: data) } catch { self.errorMessage = error.localizedDescription }
    }) { return }
    var next = try ProjectStore.open(folder: folder, preferredFile: nil)
    guard next.id == backup.id else { throw PrintroomError.invalid("设置副本属于另一卷底片") }
    for i in next.frames.indices {
      if let source = backup.frames.first(where: { $0.id == next.frames[i].id }) {
        next.frames[i].adjustments = source.adjustments
        next.frames[i].orientation = source.orientation
        next.frames[i].crop = source.crop
        if let crop = source.crop, crop.geometryVersion == 1, !next.frames[i].isMissing,
          let metadata = try? geometryMetadata(folder.appendingPathComponent(next.frames[i].filename))
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
        || source.rawProcessing != current.rawProcessing
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
    showExportPanel(project: project, targets: [frame.id], title: "导出当前照片", folder: folder)
  }
  func batchExportPanel(allFrames: Bool) {
    guard let project, !isExporting, !isCropping else { return }
    let targets = allFrames ? Set(project.frames.map(\.id)) : selection.selectedFrameIDs
    guard !targets.isEmpty else { return }
    showExportPanel(project: project, targets: targets,
      title: "导出\(allFrames ? "整卷" : "选中照片") · \(targets.count) 张", folder: folder)
  }
  private func showExportPanel(project: RollProject, targets: Set<UUID>, title: String, folder: URL?) {
    let panel = NSOpenPanel()
    panel.title = title + " · 选择输出文件夹"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = folder?.appendingPathComponent("Printroom Exports", isDirectory: true)
    panel.prompt = "导出"
    let options = ExportOptionsView(settings: project.exportSettings,
      filenamePrefix: folder?.lastPathComponent ?? "Printroom")
    options.attach(to: panel)
    guard panel.runModal() == .OK, let directory = panel.url,
      self.project?.id == project.id, !isExporting else { return }
    setExportSettings(options.settings)
    startExport(targetIDs: targets, directory: directory, filenamePrefix: options.filenamePrefix)
  }
  func startExport(targetIDs: Set<UUID>, directory: URL, explicitDestination: URL? = nil, filenamePrefix: String? = nil) {
    guard let project, let assets, !isExporting else { return }
    do {
      // Captures targets, source identities, calibration, frame edits, orientation, and output settings now.
      let request = try ExportRequest(project: project, targetIDs: targetIDs,
        destinationDirectory: directory, explicitDestination: explicitDestination, filenamePrefix: filenamePrefix)
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
          let summary = try await exportEngine.run(request, lut: assets.lut, p3Profile: assets.profile, fujifilmLUT: assets.fujifilmLUT) { progress in
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
  func clearRAWCache() {
    guard !isExporting else { return }
    rawPreparationTask?.cancel()
    status = "正在清理 RAW 中间文件…"
    Task {
      do {
        try await Task.detached(priority: .utility) { try RAWSourceService.shared.clearCache() }.value
        status = "RAW 中间文件已清理；再次需要时自动重建"
      } catch { errorMessage = error.localizedDescription }
    }
  }
  func clearThumbnailCache() {
    guard let folder, let project else { return }
    thumbnailTask?.cancel()
    thumbnailGeneration = UUID()
    thumbnails = [:]
    thumbnailPresentationKeys = [:]
    presentationCache.clear()
    let cache = DiskThumbnailCache.forRoll(folder: folder, projectID: project.id)
    Task {
      do {
        await thumbnailService.clear()
        try? await cache.migrateLegacy(from: folder)
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
      thumbnailPresentationKeys = thumbnailPresentationKeys.filter { available.contains($0.key) }
    }
    thumbnailTask?.cancel()
    thumbnailGeneration = UUID()
    let generation = thumbnailGeneration
    let frames = project.frames.filter { pendingThumbnailIDs.contains($0.id) }
      .sorted { $0.id == selection.activeFrameID && $1.id != selection.activeFrameID }
    let cache = DiskThumbnailCache.forRoll(folder: folder, projectID: project.id)
    thumbnailTask = Task {
      if affectedIDs == nil {
        try? await cache.migrateLegacy(from: folder)
        _ = try? await cache.maintain()
      }
      for frame in frames {
        guard !Task.isCancelled, generation == thumbnailGeneration else { return }
        do {
          let sourceURL = folder.appendingPathComponent(frame.filename)
          let stamp = try PreviewSourceStamp(url: sourceURL)
          let presentationKey = PreviewPresentationKey(source: stamp, frameID: frame.id,
            calibration: project.calibration, adjustments: frame.adjustments,
            orientation: frame.orientation, crop: frame.crop, stage: .final)
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
              lut: frame.adjustments.cineonLogLUT.sha256, dimension: 240,
              presentationVersion: DisplayImage.presentationVersion,
              rawProcessing: stamp.rawProcessing))
          let key = SHA256.hash(data: keyData).map { String(format: "%02x", $0) }.joined()
          if let cg = try? await cache.image(for: key) {
            guard !Task.isCancelled, generation == thumbnailGeneration else { return }
            publishThumbnail(cg, key: presentationKey)
            pendingThumbnailIDs.remove(frame.id)
            continue
          }
          let source = try await thumbnailService.thumbnailSource(sourceURL)
          let output = try await thumbnailRenderer.render(source.0,
            calibration: project.calibration, adjustments: frame.adjustments,
            assets: assets, orientation: frame.orientation, crop: frame.crop,
            sourceWidth: source.1, sourceHeight: source.2)
          guard !Task.isCancelled, generation == thumbnailGeneration else { return }
          publishThumbnail(output.image, key: presentationKey)
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
    panel.title = "重新定位 \(frame.filename) · 选择本卷中的 TIFF 或 ARW"
    panel.allowedContentTypes = [.tiff, UTType(filenameExtension: "arw") ?? .rawImage]
    panel.directoryURL = folder
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    relocate(frameID, to: url)
  }
  func relocate(_ frameID: UUID, to url: URL) {
    guard let previous = project, let capturedFolder = folder else { return }
    cancelGeometryPreparation()
    if SourceImageIO.isRAW(url) {
      let encoded = geometryProjectSnapshot(previous)
      let token = UUID()
      geometryPreparationToken = token
      isPreparingGeometry = true
      status = "正在验证 Adobe RAW 重新定位目标…"
      geometryPreparationTask = Task {
        defer {
          if geometryPreparationToken == token {
            isPreparingGeometry = false
            geometryPreparationTask = nil
          }
        }
        do {
          let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let next = try ProjectStore.relocate(previous, frameID: frameID, to: url, folder: capturedFolder)
            try Task.checkCancellation()
            return next
          }
          let next = try await withTaskCancellationHandler {
            try await worker.value
          } onCancel: { worker.cancel() }
          try Task.checkCancellation()
          guard geometryPreparationToken == token, folder == capturedFolder,
            project.flatMap({ geometryProjectSnapshot($0) }) == encoded else { return }
          finishRelocation(previous: previous, next: next, frameID: frameID)
        } catch {
          guard !Task.isCancelled, geometryPreparationToken == token, folder == capturedFolder else { return }
          errorMessage = error.localizedDescription
        }
      }
    } else {
      do {
        let next = try ProjectStore.relocate(previous, frameID: frameID, to: url, folder: capturedFolder)
        finishRelocation(previous: previous, next: next, frameID: frameID)
      } catch { errorMessage = error.localizedDescription }
    }
  }
  private func finishRelocation(previous: RollProject, next: RollProject, frameID: UUID) {
    registerUndo(old: previous, name: "重新定位照片")
    project = next
    dirty = true
    selection = SelectionState()
    selection.click(frameID, ordered: next.frames.filter { !$0.isMissing }.map(\.id))
    project?.lastActiveFrameID = frameID
    loadActive()
    refreshThumbnails()
    scheduleSave(immediate: true)
    status = "已重新定位；保留照片 ID、调色与方向"
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
    let rawProcessing: RAWProcessingIdentity?
  }
  let adjustmentKeyboard = AdjustmentKeyboard()
}
