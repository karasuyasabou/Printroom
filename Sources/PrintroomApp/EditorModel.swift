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
  @Published private(set) var newRollNamingID: UUID?
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
  }
  private(set) var cropPreviewTransition: CropPreviewTransition?
  private func retainCropPreview() {
    guard cropPreviewTransition == nil, previewImage != nil else { return }
    cropPreviewTransition = CropPreviewTransition(
      size: CGSize(width: displayWidth, height: displayHeight), isCropping: isCropping,
      geometry: cropDraftGeometry)
  }
  @Published private(set) var isPreviewPlaceholder = false
  @Published var histogram: HistogramStatistics? {
    didSet {
      if histogram == nil { histogramProbeSnapshot = nil; clearHistogramProbe() }
    }
  }
  @Published private(set) var histogramProbe: SIMD3<Float>?
  private var histogramProbeSnapshot: PreviewRequest?
  private var histogramProbePoint: CGPoint?

  func clearHistogramProbe() {
    histogramProbePoint = nil
    if histogramProbe != nil { histogramProbe = nil }
  }

  func probeHistogram(displayX: Int, displayY: Int) {
    guard !isCropping, !sampling, !isPreviewPlaceholder, cropPreviewTransition == nil,
      previewImage != nil, histogram != nil, let request = histogramProbeSnapshot,
      request.context == previewContext, request.context.frameID == activeFrame?.id,
      let geometry = displayGeometry,
      displayX >= 0, displayY >= 0,
      displayX < geometry.outputWidth, displayY < geometry.outputHeight else {
      clearHistogramProbe(); return
    }
    let point = geometry.sourcePoint(outputX: Double(displayX) + 0.5, outputY: Double(displayY) + 0.5)
    let x = max(0, min(request.context.sourceWidth - 1, Int(floor(point.x))))
    let y = max(0, min(request.context.sourceHeight - 1, Int(floor(point.y))))
    let sourcePoint = CGPoint(x: x, y: y)
    guard histogramProbePoint != sourcePoint else { return }
    histogramProbePoint = sourcePoint
    let samples = ImageService.neutralSample(request.input,
      sourceWidth: request.context.sourceWidth, sourceHeight: request.context.sourceHeight,
      sourceX: x, sourceY: y)
    let value = try? HistogramProbe.median(samples, calibration: request.context.calibration,
      adjustments: request.adjustments,
      lut: request.assets.lut(for: request.adjustments.cineonLogLUT), stage: request.context.histogramStage)
    if value != histogramProbe { histogramProbe = value }
  }
  @Published var histogramStage: PipelineStage = .final {
    didSet {
      guard histogramStage != oldValue else { return }
      render()
    }
  }
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
      schedulePreviewWarmup()
      if sampling { cancelNeutralPicker() }
      let changesGeometry = activeFrame?.crop != nil || isCropping
      if sampling { isCropping = false; cropDraft = nil }
      guard changesGeometry else { return }
      previewImage = nil
      cropViewportToken += 1
      render()
    }
  }
  @Published var cropPreviewEnabled = true {
    willSet { if newValue != cropPreviewEnabled { retainCropPreview() } }
    didSet {
      guard cropPreviewEnabled != oldValue else { return }
      cropViewportToken += 1
      render(preservingHistogram: true)
    }
  }
  @Published private(set) var isCropping = false { didSet { schedulePreviewWarmup() } }
  @Published var cropRatioLocked = true
  @Published var cropDraft: FrameCrop?
  @Published var cropViewportToken = 0
  @Published var showMissingFilmBaseDialog = false
  @Published private(set) var showRollTimingDialog = false
  @Published private(set) var isAnalyzingRollTiming = false { didSet { schedulePreviewWarmup() } }
  @Published private(set) var rollTimingProgress = ""
  @Published private(set) var rollTimingError: String?
  private var rollTimingTask: Task<Void, Never>?
  private var rollTimingGeneration = UUID()
  private var rollTimingSnapshot: RollProject?
  private var rollTimingResult: RollTimingResult?
  private var rollTimingAutoExposure = false
  typealias RollTimingRunner = @Sendable (RollProject, URL, AppAssets, Bool, @escaping @Sendable (String) async -> Void) async throws -> RollTimingResult
  var rollTimingRunner: RollTimingRunner = { project, folder, assets, autoExposure, progress in
    try await RollTimingService.run(project: project, folder: folder, assets: assets, autoExposure: autoExposure, progress: progress)
  }
  var hasFilmBase: Bool { project?.calibration.isCalibrated == true }
  var canAdjustColors: Bool { hasFilmBase && activeFrame != nil }
  var canOpenRollTiming: Bool {
    guard let p = project else { return false }
    return p.frames.contains { !$0.isMissing }
      && !isCropping && !isLoading && !isAutoCropping && !isExporting
      && !showRollTimingDialog && !showMissingFilmBaseDialog
      && !isNeutralSampling && !sampling && pendingMatrixCalibration == nil
  }
  var canStartRollTiming: Bool {
    guard let p = project else { return false }
    return canOpenRollTiming && p.calibration.isCalibrated
      && p.calibration.cmosMatrix == p.calibration.sampledCMOSMatrix
      && p.calibration.matrix == p.calibration.sampledDensityMatrix
  }
  func beginFilmBaseSelection() {
    showMissingFilmBaseDialog = false
    guard hasImage, !isCropping else { return }
    stopTimingKey()
    endAdjustment()
    sampling = true
  }
  func cancelRollTiming() {
    rollTimingTask?.cancel(); rollTimingTask = nil
    rollTimingGeneration = UUID()
    showMissingFilmBaseDialog = false
    showRollTimingDialog = false; isAnalyzingRollTiming = false
    rollTimingSnapshot = nil; rollTimingResult = nil; rollTimingError = nil
  }
  func startRollTiming(autoExposure: Bool = false) {
    guard canStartRollTiming, let folder, let assets else { return }
    stopTimingKey(); endAdjustment()
    guard let old = project else { return }
    cancelSampling()
    neutralPicking = false
    rollTimingAutoExposure = autoExposure
    rollTimingSnapshot = old; rollTimingResult = nil; rollTimingError = nil
    let generation = UUID()
    rollTimingGeneration = generation
    showRollTimingDialog = true; isAnalyzingRollTiming = true
    rollTimingProgress = "正在分析…"
    let runner = rollTimingRunner
    rollTimingTask = Task {
      do {
        let result = try await runner(old, folder, assets, autoExposure) { [weak model = self] text in
          await model?.updateRollTimingProgress(text, generation: generation)
        }
        guard !Task.isCancelled, rollTimingGeneration == generation else { return }
        rollTimingResult = result
      } catch {
        guard !Task.isCancelled, rollTimingGeneration == generation else { return }
        rollTimingError = error.localizedDescription
      }
      isAnalyzingRollTiming = false; rollTimingTask = nil
    }
  }
  private func updateRollTimingProgress(_ text: String, generation: UUID) {
    if rollTimingGeneration == generation { rollTimingProgress = text }
  }
  func applyRollTiming(preserveEdited: Bool) {
    guard !isAnalyzingRollTiming, let result = rollTimingResult,
      let old = rollTimingSnapshot, let current = project,
      let lut = old.frames.first?.adjustments.cineonLogLUT else { return }
    do {
      guard current.id == old.id, current.calibration == old.calibration,
        current.frames == old.frames else {
        throw PrintroomError.invalid("照片或参数已改变，请重新分析。")
      }
      for stamp in result.sources where try SourceStamp(url: stamp.url) != stamp {
        throw PrintroomError.invalid("源照片已改变，请重新分析。")
      }
      var next = current
      var targets = Set<UUID>()
      for index in next.frames.indices where !next.frames[index].isMissing {
        let a = next.frames[index].adjustments
        if preserveEdited && (a.timing != TimingParameters() || a.contrast != ContrastParameters()) { continue }
        next.frames[index].adjustments.cineonLogLUT = lut
        var timing = result.timing
        if rollTimingAutoExposure {
          guard let master = result.masters[next.frames[index].id], (0...512).contains(master) else {
            throw PrintroomError.invalid("自动曝光结果不完整，请重新分析。")
          }
          timing.master = master
        }
        next.frames[index].adjustments.timing = timing
        next.frames[index].adjustments.contrast = ContrastParameters()
        targets.insert(next.frames[index].id)
      }
      if next.frames != current.frames {
        registerUndo(old: current, name: "整卷自动调色")
        project = next; dirty = true
        render(); refreshThumbnails(affectedIDs: targets); scheduleSave(immediate: true)
      }
      cancelRollTiming()
    } catch { rollTimingError = error.localizedDescription; rollTimingResult = nil }
  }
  @Published private(set) var isAutoCropping = false { didSet { schedulePreviewWarmup() } }
  @Published private(set) var autoCropProgressText = ""
  @Published private(set) var autoCropCompletedRun = 0
  @Published var reviewOnlyPendingCrops = false
  @Published private var cropReviewSession = false
  private var autoCropTask: Task<Void, Never>?
  private var autoCropGeneration = UUID()
  typealias AutoCropRunner = @Sendable ([AutoCropInput], Set<UUID>, Double, @escaping @Sendable (String) async -> Void) async throws -> [AutoCropOutput]
  var autoCropRunner: AutoCropRunner = { inputs, targets, ratio, progress in
    try await AutoCropService.run(inputs: inputs, targets: targets, aspectRatio: ratio, progress: progress)
  }
  var pendingAutoCropFrameIDs: Set<UUID> {
    Set(project?.frames.filter { !$0.isMissing && $0.cropNeedsReview }.map(\.id) ?? [])
  }
  var cropReviewAvailable: Bool { cropReviewSession || !pendingAutoCropFrameIDs.isEmpty }
  var canStartAutoCrop: Bool {
    project != nil && !isAutoCropping && !isCropping && !isLoading && !isExporting
      && project?.frames.contains(where: { !$0.isMissing }) == true
  }
  @Published var errorMessage: String?
  @Published var isLoading = false { didSet { schedulePreviewWarmup() } }
  @Published var isRendering = false { didSet { schedulePreviewWarmup() } }
  @Published var isExporting = false { didSet { schedulePreviewWarmup() } }
  @Published var exportProgress = 0.0
  @Published var exportDetail = ""
  @Published var exportSummary: ExportSummary?
  @Published var showExportDialog = false
  private var exportDialog: ExportDialogController?
  private let exportEngine = ExportEngine()
  private var exportGeneration = UUID()
  @Published var dirty = false
  @Published var saveFailure = false
  @Published var sourceWidth = 0
  @Published var sourceHeight = 0
  @Published private(set) var neutralPicking = false { didSet { schedulePreviewWarmup() } }
  @Published private(set) var isNeutralSampling = false { didSet { schedulePreviewWarmup() } }
  @Published var undoRevision = 0
  let undoManager = UndoManager()
  let imageService = ImageService()
  private let previewRenderer = PreviewRenderService()
  private let thumbnailRenderer = PreviewRenderService()
  private let thumbnailService = ImageService(cacheLimitBytes: 16 * 1024 * 1024, cacheLimitEntries: 12)
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
    let histogramCrop: FrameCrop?
    let sprocketWhitening: SprocketWhiteningSettings
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
  private var previewSourceStamp: SourceStamp?
  private var presentationCache = PreviewPresentationCache()
  private let previewWarmupEnabled: Bool
  private var previewWarmupTask: Task<Void, Never>?
  private var previewWarmupGeneration = UUID()
  private var loadTask: Task<Void, Never>?
  private var renderTask: Task<Void, Never>?
  private var thumbnailTask: Task<Void, Never>?
  private var exportTask: Task<Void, Never>?
  private let persistence = ProjectPersistence()
  private var loadRevision = 0
  private var renderRevision = 0
  private var gestureBefore: RollProject?
  private var thumbnailGeneration = UUID()
  var activeFrame: FrameRecord? { project?.frames.first { $0.id == selection.activeFrameID } }
  var adjustments: FrameAdjustments { activeFrame?.adjustments ?? .init() }
  var canApply: Bool { hasFilmBase && snapshot != nil && !selection.selectedFrameIDs.isEmpty }
  var canUndo: Bool { undoManager.canUndo }
  var canRedo: Bool { undoManager.canRedo }
  var hasImage: Bool { previewImage != nil && activeFrame != nil && !isPreviewPlaceholder && !isLoading && cropPreviewTransition == nil }
  var canEditCrop: Bool { isCropping && !isLoading && !isPreviewPlaceholder && sourceWidth > 0 && sourceHeight > 0 }
  var canPickNeutral: Bool { hasFilmBase && hasImage && !isCropping && !sampling && !isNeutralSampling && !isRendering }
  var orientation: FrameOrientation { activeFrame?.orientation ?? .identity }
  var displayedCrop: FrameCrop? { isCropping || sampling || !cropPreviewEnabled ? nil : activeFrame?.crop }
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
  var exportSettings: ProjectExportSettings { project?.exportSettings ?? .init() }
  var matrix: PrintDensityMatrix { project?.calibration.matrix ?? .identity }

  let recentRolls: RecentRolls?

  init(recentRolls: RecentRolls? = nil, timingDefaults: UserDefaults = .standard, matrixStore: MatrixLibraryStore = .init(), previewWarmupEnabled: Bool = true, neutralSolver: @escaping NeutralSolver = { samples, calibration, adjustments, lut, profile in
    try NeutralTiming.solve(samples, calibration: calibration, adjustments: adjustments,
      lut: lut, p3Profile: profile)
  }) {
    self.timingDefaults = timingDefaults
    self.timingMode = TimingMode(rawValue: timingDefaults.string(forKey: TimingMode.preferenceKey) ?? "") ?? .simple
    self.recentRolls = recentRolls
    self.matrixStore = matrixStore
    self.neutralSolver = neutralSolver
    self.previewWarmupEnabled = previewWarmupEnabled
    do { matrixLibrary = try matrixStore.load() }
    catch { matrixLibraryError = error.localizedDescription }
    undoManager.groupsByEvent = false
    do { assets = try AppAssets() } catch { errorMessage = error.localizedDescription }
  }
  func openPanel() {
    guard !isExporting else { return }
    let panel = NSOpenPanel()
    panel.title = "打开底片文件夹"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
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
    guard discardUnsaved || (saveCropBeforeSwitching() && flushSave()) else { return }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
      errorMessage = "文件不存在：\(url.lastPathComponent)"
      return
    }
    cancelRollTiming()
    cancelAutoCrop()
    resetAutoCropReview()
    cancelGeometryPreparation()
    let targetFolder = isDirectory.boolValue ? url : url.deletingLastPathComponent()
    let preferred = isDirectory.boolValue ? nil : url
    do {
      let roll = try ProjectStore.open(folder: targetFolder, preferredFile: preferred)
      beginImport(roll, folder: targetFolder, preferred: preferred, replacingRecent: replacingRecent)
    } catch { errorMessage = error.localizedDescription }
  }
  private func activateRoll(_ roll: RollProject, folder targetFolder: URL,
    preferred: URL?, replacingRecent: String?) {
    if folder != targetFolder { snapshot = nil }
    thumbnails = [:]
    presentationCache.clear()
    pendingThumbnailIDs = []
    loadTask?.cancel()
    renderTask?.cancel()
    thumbnailTask?.cancel()
    persistence.cancel()
    folder = targetFolder
    project = roll
    recentRolls?.record(folder: targetFolder, projectID: roll.id, replacing: replacingRecent, name: roll.name)
    persistence.expectedModification = roll.loadedModificationDate
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
    _ = flushSave()
    loadActive()
    refreshThumbnails()
    if roll.loadedModificationDate == nil { newRollNamingID = roll.id }
  }
  func returnHome() {
    if isImporting { cancelImport(); return }
    guard project != nil, !isExporting else { return }
    stopTimingKey()
    endAdjustment()
    guard saveCropBeforeSwitching(), flushSave() else { return }
    resetEditor()
  }
  private func resetEditor() {
    cancelPreviewWarmup()
    cancelRollTiming()
    cancelAutoCrop()
    resetAutoCropReview()
    project = nil
    folder = nil
    newRollNamingID = nil
    selection = SelectionState()
    snapshot = nil
    loadActive()
    thumbnailTask?.cancel()
    thumbnailGeneration = UUID()
    pendingThumbnailIDs = []
    thumbnails = [:]
    presentationCache.clear()
    preparedGeometryMetadata = [:]
    persistence.expectedModification = nil
    gestureBefore = nil
    showSync = false
    matrixManager = nil
    showMatrixMenu = false
    exportDialog?.dismiss()
    showExportDialog = false
    exportSummary = nil
    undoManager.removeAllActions()
    undoRevision += 1
    errorMessage = nil
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
    if old != nextSelection.activeFrameID { retainCropPreview() }
    selection = nextSelection
    if old != selection.activeFrameID {
      loadActive(preservingCropMode: isCropping, preservingSamplingMode: sampling)
    }
    self.project?.lastActiveFrameID = selection.activeFrameID
    dirty = true
    scheduleSave()
  }
  private func saveCropBeforeSwitching(confirm: Bool = false) -> Bool {
    // A loading frame has no editable draft; nil must not clear its saved crop.
    guard canEditCrop,
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
    var nextSelection = selection
    nextSelection.selectAll(project.frames.filter { !$0.isMissing }.map(\.id))
    if before != nextSelection.activeFrameID { retainCropPreview() }
    selection = nextSelection
    if before != selection.activeFrameID { loadActive() }
  }
  private var proxyPreparationTask: Task<Void, Never>?
  private var importGeneration = UUID()
  private var importURL: URL?
  private var importReplacingRecent: String?
  @Published private(set) var isImporting = false { didSet { schedulePreviewWarmup() } }
  @Published private(set) var importCompleted = 0
  @Published private(set) var importTotal = 0
  @Published private(set) var importFailure: String?
  var proxyLoader: @Sendable (URL) throws -> Void = { _ = try SourceImageIO.metadata(url: $0) }

  func cancelImport() {
    importGeneration = UUID()
    proxyPreparationTask?.cancel()
    proxyPreparationTask = nil
    isImporting = false
    importFailure = nil
    importURL = nil
  }
  func retryImport() {
    guard let importURL else { return }
    open(importURL, replacingRecent: importReplacingRecent)
  }
  private func beginImport(_ roll: RollProject, folder targetFolder: URL,
    preferred: URL?, replacingRecent: String?) {
    // Keep the project unpublished: all editor/menu commands remain unavailable.
    resetEditor()
    cancelImport()
    let urls = roll.frames.filter { !$0.isMissing }
      .map { targetFolder.appendingPathComponent($0.filename) }
    guard !urls.isEmpty else {
      activateRoll(roll, folder: targetFolder, preferred: preferred, replacingRecent: replacingRecent)
      return
    }
    isImporting = true
    importCompleted = 0
    importTotal = urls.count
    importURL = preferred ?? targetFolder
    importReplacingRecent = replacingRecent
    let generation = importGeneration
    let loader = proxyLoader
    proxyPreparationTask = Task {
      let failures = await SourcePrewarmer.prepare(urls, progress: { [weak self] completed in
        await self?.updateImportProgress(completed, generation: generation)
      }, load: loader)
      guard !Task.isCancelled, generation == importGeneration else { return }
      proxyPreparationTask = nil
      guard failures.isEmpty else {
        importFailure = failures.map { "\($0.url.lastPathComponent)：\($0.message)" }.joined(separator: "\n")
        return
      }
      isImporting = false
      importURL = nil
      activateRoll(roll, folder: targetFolder, preferred: preferred, replacingRecent: replacingRecent)
    }
  }
  private func updateImportProgress(_ completed: Int, generation: UUID) {
    guard generation == importGeneration, isImporting else { return }
    importCompleted = completed
  }
  func loadActive(preservingCropMode: Bool = false, preservingSamplingMode: Bool = false) {
    guard !isImporting else { return }
    cancelPreviewWarmup()
    retainCropPreview()
    cancelGeometryPreparation()
    isCropping = preservingCropMode
    cropDraft = nil
    sampling = preservingSamplingMode
    cancelSampling()
    cancelNeutralPicker()
    isRendering = false
    loadTask?.cancel()
    cancelPreviewWorker()
    previewContext = nil
    loadRevision += 1
    renderRevision += 1
    let revision = loadRevision
    histogramProbeSnapshot = nil
    clearHistogramProbe()
    isPreviewPlaceholder = previewImage != nil
    previewSourceStamp = nil
    previewInput = nil
    sourceWidth = 0
    sourceHeight = 0
    guard let frame = activeFrame, let folder else {
      histogram = nil
      previewImage = nil
      isPreviewPlaceholder = false
      isLoading = false
      isRendering = false
      return
    }
    isLoading = true
    let url = folder.appendingPathComponent(frame.filename)
    previewSourceStamp = try? SourceStamp(url: url)
    showCachedPreview()
    loadTask = Task {
      do {
        let result = try await imageService.preview(url)
        guard !Task.isCancelled, revision == loadRevision else { return }
        let stamp = try SourceStamp(url: url)
        guard stamp == previewSourceStamp else {
          throw PrintroomError.invalid("读取期间源图像已改变，请重新打开照片")
        }
        previewInput = result.0
        previewInputIdentity = UUID()
        sourceWidth = result.1
        sourceHeight = result.2
        if isCropping && cropDraft == nil {
          cropRatioLocked = true
          let initial = frame.crop ?? FrameCrop(aspect: .free, freeRatio: Double(sourceWidth) / Double(sourceHeight))
          cropDraft = try initial.sourceCoordinates(sourceWidth: sourceWidth,
            sourceHeight: sourceHeight, orientation: frame.orientation)
          cropViewportToken += 1
        }
        if SourceImageIO.isRAW(url), let index = project?.frames.firstIndex(where: { $0.id == frame.id }) {
          let identity = try SourceImageIO.processingIdentity(url: url)
          project?.frames[index].rawProcessing = identity
          dirty = true
          scheduleSave()
        }
        isLoading = false
        render()
      } catch {
        if !Task.isCancelled && revision == loadRevision {
          isLoading = false
          histogram = nil
          previewImage = nil
          isPreviewPlaceholder = false
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
  private func presentationKey(stage: PipelineStage? = nil) -> PreviewPresentationKey? {
    guard let source = previewSourceStamp, let frame = activeFrame, let project else { return nil }
    return PreviewPresentationKey(source: source, frameID: frame.id,
      calibration: project.calibration, adjustments: frame.adjustments,
      orientation: frame.orientation, crop: displayedCrop, stage: stage ?? self.stage,
      sprocketWhitening: effectiveSprocketWhitening, protectedCrop: sampling ? nil : frame.crop)
  }
  private var canWarmPreviews: Bool {
    previewWarmupEnabled && project != nil && folder != nil && hasImage && assets != nil
      && !isImporting && !isLoading && !isRendering && !isExporting && !isCropping
      && !sampling && !neutralPicking && !isNeutralSampling && !isAutoCropping
      && !isAnalyzingRollTiming && !isPreparingGeometry && pendingMatrixCalibration == nil
      && gestureBefore == nil && thumbnailTask == nil
  }
  private func cancelPreviewWarmup() {
    previewWarmupTask?.cancel()
    previewWarmupTask = nil
    previewWarmupGeneration = UUID()
  }
  private func schedulePreviewWarmup() {
    cancelPreviewWarmup()
    guard canWarmPreviews else { return }
    let generation = previewWarmupGeneration
    previewWarmupTask = Task(priority: .utility) { [weak self] in
      do { try await Task.sleep(for: .seconds(1)) } catch { return }
      guard let self, !Task.isCancelled, generation == self.previewWarmupGeneration else { return }
      await self.warmPreviewCache(generation: generation)
      if generation == self.previewWarmupGeneration { self.previewWarmupTask = nil }
    }
  }
  private func warmPreviewCache(generation: UUID) async {
    guard canWarmPreviews, let roll = project, let folder, let assets else { return }
    let frames = roll.frames.filter { !$0.isMissing }
    let activeIndex = frames.firstIndex { $0.id == selection.activeFrameID } ?? 0
    // At most forty nearby frames; one utility request at a time, with a pause between frames.
    let candidates = frames.enumerated().sorted {
      let lhs = abs($0.offset - activeIndex), rhs = abs($1.offset - activeIndex)
      return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
    }.prefix(presentationCache.countLimit).map(\.element)
    let renderer = PreviewRenderService()
    let savedStage = stage, savedHistogramStage = histogramStage, savedCropPreview = cropPreviewEnabled
    for frame in candidates {
      guard !Task.isCancelled, generation == previewWarmupGeneration, canWarmPreviews else { return }
      do {
        let url = folder.appendingPathComponent(frame.filename)
        let source = try SourceStamp(url: url)
        let crop = savedCropPreview ? frame.crop : nil
        let key = PreviewPresentationKey(source: source, frameID: frame.id,
          calibration: roll.calibration, adjustments: frame.adjustments,
          orientation: frame.orientation, crop: crop, stage: savedStage,
          sprocketWhitening: roll.calibration.isCalibrated ? roll.sprocketWhitening : .init(),
          protectedCrop: frame.crop)
        // Fill the shared input cache even when the rendered display is already cached.
        let input = try await imageService.preview(url)
        guard !Task.isCancelled, generation == previewWarmupGeneration, canWarmPreviews else { return }
        if !presentationCache.contains(key, histogramStage: roll.calibration.isCalibrated ? savedHistogramStage : nil) {
          let result = try await renderer.render(input.0, calibration: roll.calibration,
            adjustments: frame.adjustments, assets: assets, stage: savedStage,
            original: !roll.calibration.isCalibrated, orientation: frame.orientation,
            inputIdentity: UUID(), crop: crop, sourceWidth: input.1, sourceHeight: input.2,
            includeHistogram: true, histogramStage: savedHistogramStage, histogramCrop: frame.crop,
            sprocketWhitening: key.sprocketWhitening, protectedCrop: frame.crop)
          guard !Task.isCancelled, generation == previewWarmupGeneration, canWarmPreviews,
            self.folder == folder, project?.id == roll.id, project?.calibration == roll.calibration,
            project?.sprocketWhitening == roll.sprocketWhitening,
            project?.frames.first(where: { $0.id == frame.id }) == frame,
            stage == savedStage, histogramStage == savedHistogramStage,
            cropPreviewEnabled == savedCropPreview, try SourceStamp(url: url) == source else { return }
          // Keep the visible frame most recently used while background work fills free slots.
          if let activeKey = presentationKey() { _ = presentationCache.image(for: activeKey) }
          presentationCache.store(.init(key: key, image: result.image, sourceWidth: input.1,
            sourceHeight: input.2, histogram: result.histogram))
        }
        try await Task.sleep(for: .milliseconds(120))
      } catch is CancellationError { return }
      catch {
        // Disposable preloading must not change selection, edits or show foreground errors.
        continue
      }
    }
  }
  private func showCachedPreview() {
    guard isLoading || isRendering, previewImage == nil || isPreviewPlaceholder,
      let key = presentationKey() else { return }
    if let entry = presentationCache.image(for: key) {
      sourceWidth = entry.sourceWidth
      sourceHeight = entry.sourceHeight
      if isCropping {
        cropRatioLocked = true
        let initial = activeFrame?.crop ?? FrameCrop(aspect: .free,
          freeRatio: Double(sourceWidth) / Double(sourceHeight))
        cropDraft = try? initial.sourceCoordinates(sourceWidth: sourceWidth,
          sourceHeight: sourceHeight, orientation: orientation)
      }
      cropPreviewTransition = nil
      histogram = !isCropping && entry.histogram?.stage == histogramStage ? entry.histogram : nil
      histogramProbeSnapshot = nil
      clearHistogramProbe()
      previewImage = entry.image
      isPreviewPlaceholder = true
    }
  }
  private func publishThumbnail(_ image: CGImage, key: PreviewPresentationKey) {
    guard (try? SourceStamp(url: key.source.url)) == key.source else { return }
    thumbnails[key.frameID] = image
  }
  func render(preservingHistogram: Bool = false) {
    cancelPreviewWarmup()
    cancelNeutralPicker()
    if histogram?.stage != histogramStage { histogram = nil }
    renderRevision += 1
    guard let input = previewInput, let project, let frame = activeFrame, let assets else { return }
    let context = PreviewContext(source: previewInputIdentity, frameID: frame.id,
      calibration: project.calibration, stage: stage, histogramStage: histogramStage, orientation: frame.orientation,
      crop: displayedCrop, histogramCrop: sampling ? nil : frame.crop,
      sprocketWhitening: effectiveSprocketWhitening,
      sourceWidth: sourceWidth, sourceHeight: sourceHeight)
    // Geometry/source/stage changes invalidate in-flight work. Ordinary edits keep
    // the current job alive and replace the single pending snapshot instead.
    if context != previewContext {
      if !preservingHistogram && !isPreviewPlaceholder && cropPreviewTransition == nil { histogram = nil }
      clearHistogramProbe()
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
            original: !request.context.calibration.isCalibrated,
            orientation: request.context.orientation, inputIdentity: request.context.source,
            crop: request.context.crop, sourceWidth: request.context.sourceWidth,
            sourceHeight: request.context.sourceHeight, includeHistogram: !isCropping,
            histogramStage: request.context.histogramStage, histogramCrop: request.context.histogramCrop,
            sprocketWhitening: request.context.sprocketWhitening, protectedCrop: request.context.histogramCrop)
          guard !Task.isCancelled, generation == renderGeneration,
            previewContext == request.context, activeFrame?.id == request.context.frameID else { return }
          // One serial worker publishes snapshots in increasing order, including
          // while input continues faster than rendering. The next job reads only
          // the latest pending edit; an older result cannot overwrite a newer one.
          // Publish one matched snapshot in a single main-actor turn, without suspension.
          cropPreviewTransition = nil
          histogram = result.histogram
          histogramProbeSnapshot = result.histogram == nil ? nil : request
          clearHistogramProbe()
          previewImage = result.image
          isPreviewPlaceholder = false
          if let source = previewSourceStamp {
            let key = PreviewPresentationKey(source: source, frameID: request.context.frameID,
              calibration: request.context.calibration, adjustments: request.adjustments,
              orientation: request.context.orientation, crop: request.context.crop,
              stage: request.context.stage, sprocketWhitening: request.context.sprocketWhitening,
              protectedCrop: request.context.histogramCrop)
            presentationCache.store(.init(key: key, image: result.image,
              sourceWidth: request.context.sourceWidth, sourceHeight: request.context.sourceHeight,
              histogram: result.histogram))
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
  func startAutoCrop(preserveExisting: Bool = true, inwardPercent: Double = 0, aspectRatio: Double = 1.5) {
    guard canStartAutoCrop, let old = project, let folder else { return }
    guard inwardPercent.isFinite, (0...5).contains(inwardPercent) else {
      errorMessage = "向内裁剪百分比必须在 0% 到 5% 之间。"
      return
    }
    if !aspectRatio.isFinite || !(0.1...10).contains(aspectRatio) {
      errorMessage = "画幅比例必须在 1:10 到 10:1 之间。"
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
    autoCropProgressText = "准备自动裁剪…"
    let runner = autoCropRunner
    autoCropTask = Task {
      do {
        let results = try await runner(inputs, targets, aspectRatio) { [weak model = self] text in
          await model?.updateAutoCropProgress(text, generation: generation)
        }
        guard !Task.isCancelled, autoCropGeneration == generation,
          var next = project, next.id == old.id, self.folder == folder else { return }
        guard Set(results.map(\.id)) == targets, results.count == targets.count else {
          throw PrintroomError.invalid("自动裁剪未得到完整结果，原裁剪已保留。")
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
            try SourceStamp(url: result.source.url) == result.source else {
            throw PrintroomError.invalid("照片或裁剪已改变，请重新运行自动裁剪。")
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
          registerUndo(old: current, name: "自动裁剪 \(results.count) 张")
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
    retainCropPreview()
    selection.click(target.id, ordered: frames.map(\.id))
    project?.lastActiveFrameID = target.id
    dirty = true
    scheduleSave()
    loadActive(preservingCropMode: true)
  }
  func performCropPrimaryAction() {
    if cropReviewAvailable && !pendingAutoCropFrameIDs.isEmpty {
      confirmCropAndAdvance()
    } else {
      commitCrop()
    }
  }

  func confirmCropAndAdvance() {
    guard canEditCrop, let id = selection.activeFrameID,
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
      cropRatioLocked = true
      isCropping = true
      cropViewportToken += 1
      render()
    } catch { errorMessage = error.localizedDescription }
  }
  func updateCropDraft(_ value: FrameCrop) {
    guard canEditCrop else { return }
    do {
      cropDraft = try value.sourceCoordinates(sourceWidth: sourceWidth,
        sourceHeight: sourceHeight, orientation: orientation)
    } catch { errorMessage = error.localizedDescription }
  }
  func updateDisplayedCropDraft(_ value: FrameCrop) {
    updateCropDraft(value)
  }
  var currentDisplayedCrop: FrameCrop {
    displayedCropDraft ?? FrameCrop(aspect: .free, geometryVersion: 1,
      freeRatio: Double(max(1, displayWidth)) / Double(max(1, displayHeight)))
  }
  func setCropRatioLocked(_ locked: Bool) {
    guard canEditCrop else { return }
    if !locked, cropDraft != nil {
      var draft = currentDisplayedCrop
      let ratio = draft.ratio
      draft.aspect = .free
      draft.portrait = false
      draft.freeRatio = ratio
      updateDisplayedCropDraft(draft)
    }
    cropRatioLocked = locked
  }
  func selectCropRatio(_ ratio: Double, aspect: CropAspectRatio = .free) {
    guard canEditCrop, ratio.isFinite, ratio > 0 else { return }
    var draft = currentDisplayedCrop
    draft.aspect = aspect
    draft.portrait = false
    draft.freeRatio = aspect == .free ? ratio : nil
    updateDisplayedCropDraft(draft)
    cropRatioLocked = true
  }
  func swapCropRatio() {
    var draft = currentDisplayedCrop
    draft.portrait.toggle()
    updateDisplayedCropDraft(draft)
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
    guard canEditCrop else { return }
    cropRatioLocked = true
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
  func commitCrop() {
    guard canEditCrop,
      let old = project, let folder, let frame = activeFrame else { return }
    let url = folder.appendingPathComponent(frame.filename)
    if prepareGeometryIfNeeded([url], then: { self.commitCrop() }) { return }
    do {
      let metadata = try geometryMetadata(url)
      let crop = try cropDraft?.sourceCoordinates(sourceWidth: sourceWidth,
        sourceHeight: sourceHeight, orientation: orientation)
      var next = old
      guard let index = next.frames.firstIndex(where: { $0.id == frame.id }), !frame.isMissing else {
        throw PrintroomError.invalid("裁剪照片不可用")
      }
      try next.frames[index].applyManualCrop(crop, sourceWidth: metadata.width, sourceHeight: metadata.height)
      retainCropPreview()
      let changed = next.frames != old.frames
      if changed { registerUndo(old: old, name: "裁剪照片"); project = next; dirty = true }
      isCropping = false
      cropDraft = nil
      cropViewportToken += 1
      render()
      if changed { refreshThumbnails(affectedIDs: [frame.id]); scheduleSave(immediate: true) }
    } catch { errorMessage = error.localizedDescription }
  }
  // Prepared dimensions live only for the synchronous commit following this background job.
  var rawGeometryMetadataLoader: @Sendable (URL) throws -> TIFFMetadata = {
    try SourceImageIO.metadata(url: $0)
  }
  private var preparedGeometryMetadata: [URL: TIFFMetadata] = [:]
  @Published private(set) var isPreparingGeometry = false { didSet { schedulePreviewWarmup() } }
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
  func sampleDisplayedBase(_ rect: PixelRect) {
    guard hasImage else { return }
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
        guard try SourceStamp(url: url) == stamp else {
          throw PrintroomError.invalid("源图像已改变，请重新打开照片后取样")
        }
        let samples = try await imageService.neutralSample(url, sourceX: sx, sourceY: sy)
        try Task.checkCancellation()
        guard try SourceStamp(url: url) == stamp else {
          throw PrintroomError.invalid("取样期间源图像已改变，请重新打开照片")
        }
        guard contextIsCurrent() else { return }
        let worker = Task.detached(priority: .userInitiated) {
          try Task.checkCancellation()
          return try solve(samples, project.calibration, frame.adjustments, assets.lut(for: frame.adjustments.cineonLogLUT), assets.profile)
        }
        let result: FrameAdjustments
        do {
          result = try await withTaskCancellationHandler {
            try await worker.value
          } onCancel: { worker.cancel() }
        } catch {
          // An unsuccessful neutral fit is a no-op, not a reload-photo alert.
          return
        }
        try Task.checkCancellation()
        guard contextIsCurrent() else { return }
        guard try SourceStamp(url: url) == stamp else {
          throw PrintroomError.invalid("标定期间源图像已改变，请重新打开照片")
        }
        // edit() is the same atomic frame transaction used by manual controls.
        edit(actionName: "标定 Final 中性点") { $0 = result }
      } catch {
        if !Task.isCancelled, contextIsCurrent() { errorMessage = error.localizedDescription }
      }
    }
  }
  var sprocketWhitening: SprocketWhiteningSettings { project?.sprocketWhitening ?? .init() }
  var canAdjustSprocketWhitening: Bool {
    guard let project else { return false }
    return project.calibration.isCalibrated
      && project.frames.contains { !$0.isMissing && $0.crop != nil }
      && !isLoading && !isCropping && !isAutoCropping && !isExporting && !sampling
  }
  private var effectiveSprocketWhitening: SprocketWhiteningSettings {
    guard hasFilmBase, !sampling, !isCropping else { return .init() }
    return sprocketWhitening
  }
  func setSprocketWhitening(_ settings: SprocketWhiteningSettings) {
    guard var next = project, settings != next.sprocketWhitening else { return }
    guard !settings.enabled || canAdjustSprocketWhitening else { return }
    do { try settings.validate() } catch { errorMessage = error.localizedDescription; return }
    let old = next
    next.sprocketWhitening = settings
    if gestureBefore == nil { registerUndo(old: old, name: "齿孔置白") }
    project = next
    dirty = true
    render()
    scheduleSave(immediate: gestureBefore == nil)
    if gestureBefore == nil { refreshThumbnails() }
  }
  func beginAdjustment() {
    cancelPreviewWarmup()
    if gestureBefore == nil { gestureBefore = project }
  }
  func endAdjustment() {
    if let old = gestureBefore, let current = project,
      old.frames != current.frames || old.sprocketWhitening != current.sprocketWhitening {
      registerUndo(old: old, name: old.sprocketWhitening != current.sprocketWhitening ? "齿孔置白" : "调整参数")
      refreshThumbnails(changedFrom: old, to: current)
    }
    gestureBefore = nil
    scheduleSave(immediate: true)
    schedulePreviewWarmup()
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
    cancelRollTiming()
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
    var restored = value
    restored.name = old.name
    restored.exportSettings = old.exportSettings
    project = restored
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
  }
  func redo() {
    stopTimingKey()
    if isCropping { cancelCrop(); return }
    undoManager.redo()
    undoRevision += 1
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
      var next = old
      if syncTiming || syncContrast || syncLUT {
        next = try ParameterSnapshot(frame: source).applying(to: old, targets: targets,
          timing: syncTiming, contrast: syncContrast, lut: syncLUT)
      }
      for index in next.frames.indices where targets.contains(next.frames[index].id) {
        let url = folder.appendingPathComponent(next.frames[index].filename)
        guard FileManager.default.fileExists(atPath: url.path) else {
          throw PrintroomError.invalid("目标文件已丢失：\(url.lastPathComponent)")
        }
        if syncCrop {
          let metadata = try geometryMetadata(url)
          try next.frames[index].applyManualCrop(crop,
            sourceWidth: metadata.width, sourceHeight: metadata.height)
        }
      }
      guard next.frames != old.frames else {
        showSync = false
        return true
      }
      registerUndo(old: old, name: "同步到其余 \(targets.count) 张")
      project = next
      dirty = true
      refreshThumbnails(affectedIDs: targets)
      scheduleSave(immediate: true)
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
        return
      }
      registerUndo(old: project, name: "应用到 \(targets.count) 张")
      self.project = next
      dirty = true
      render()
      refreshThumbnails(affectedIDs: targets)
      scheduleSave(immediate: true)
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
      // Older projects can retain a base sampled under a different CMOS matrix.
      // Re-read that selection as well before promising alignment under the current one.
      if target.cmosMatrix == target.sampledCMOSMatrix {
        target = try Pipeline.recalibrate(target, matrix: target.matrix)
        commitMatrixCalibration(target, name: "切换\(kind.label)并对齐片基")
        return
      }
      guard let rect = target.selection, let sourceID = target.sourceFrameID else {
        throw PrintroomError.invalid("片基采样记录不完整。")
      }
      let sourceURL = try calibrationSource(current)
      let requested = target
      let revision = sampleRevision
      pendingMatrixCalibration = requested
      sampleTask = Task {
        do {
          let result = try await imageService.sample(sourceURL, rect: rect,
            matrix: requested.matrix, frameID: sourceID, cmosMatrix: requested.cmosMatrix)
          guard !Task.isCancelled, revision == sampleRevision,
            let latest = self.project, latest.id == current.id,
            latest.calibration == current.calibration else { return }
          _ = try calibrationSource(latest)
          guard result.sourceWidth == requested.sourceWidth,
            result.sourceHeight == requested.sourceHeight else {
            throw PrintroomError.invalid("片基采样来源的尺寸与选区记录不匹配。")
          }
          pendingMatrixCalibration = nil
          commitMatrixCalibration(result, name: "切换矩阵并对齐片基")
        } catch {
          guard !Task.isCancelled, revision == sampleRevision else { return }
          pendingMatrixCalibration = nil
          errorMessage = error.localizedDescription
        }
      }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func calibrationSource(_ roll: RollProject) throws -> URL {
    guard let folder,
      let source = roll.frames.first(where: { $0.id == roll.calibration.sourceFrameID }),
      !source.isMissing else {
      throw PrintroomError.invalid("无法读取片基采样来源。")
    }
    let url = folder.appendingPathComponent(source.filename)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw PrintroomError.invalid("无法读取片基采样来源。")
    }
    return url
  }

  private func commitMatrixCalibration(_ calibration: FilmCalibration, name: String) {
    guard let old = project, var next = project, old.calibration != calibration else { return }
    next.calibration = calibration
    registerUndo(old: old, name: name)
    project = next
    dirty = true
    render()
    refreshThumbnails()
    scheduleSave(immediate: true)
  }
  private var pendingMatrixCalibration: FilmCalibration? { didSet { schedulePreviewWarmup() } }

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
    cancelPreviewWarmup()
    sampleTask = Task {
      do {
        let result = try await imageService.sample(
          folder.appendingPathComponent(frame.filename), rect: rect, matrix: matrix, frameID: id, cmosMatrix: cmos)
        guard !Task.isCancelled, revision == sampleRevision, var next = self.project, next.id == rollID else { return }
        guard next.calibration.matrix == matrix, next.calibration.cmosMatrix == cmos else { return }
        let firstCalibration = !next.calibration.isCalibrated
        next.calibration = result
        next.calibrationNeedsReview = false
        if let old = self.project { registerUndo(old: old, name: "片基校准") }
        self.project = next
        if firstCalibration { stage = .final }
        dirty = true
        render()
        refreshThumbnails()
        scheduleSave(immediate: true)
      } catch {
        if !Task.isCancelled && revision == sampleRevision {
          errorMessage = error.localizedDescription
        }
      }
    }
  }
  func scheduleSave(immediate: Bool = false) {
    persistence.cancel()
    if immediate {
      _ = flushSave()
      return
    }
    persistence.schedule { [weak self] in _ = self?.flushSave() }
  }
  @discardableResult func flushSave() -> Bool {
    persistence.cancel()
    guard dirty, let folder, let project else { return true }
    do {
      try persistence.save(project, folder: folder)
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
    next.name = backup.name
    next.sprocketWhitening = backup.sprocketWhitening
    next.calibration = backup.calibration
    next.calibrationNeedsReview = false
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
    persistence.expectedModification = saved
    dirty = false
    saveFailure = false
    errorMessage = nil
    render()
    refreshThumbnails(changedFrom: previous, to: next)
  }
  var rollName: String { project?.name ?? folder?.lastPathComponent ?? "Printroom" }

  func nameNewRollIfNeeded() {
    guard let id = newRollNamingID, project?.id == id else { return }
    newRollNamingID = nil
    renameRollPanel()
  }

  func openRollFolderInFinder() {
    guard let folder else { return }
    if !NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path) {
      errorMessage = "无法在 Finder 中打开底片文件夹。"
    }
  }

  func renameRollPanel(recent: RecentRoll? = nil) {
    guard let target = recent?.url ?? folder else { return }
    NSApp.keyWindow?.makeFirstResponder(nil)
    stopTimingKey()
    endAdjustment()
    let isCurrent = folder?.standardizedFileURL.resolvingSymlinksInPath() == target.standardizedFileURL.resolvingSymlinksInPath()
    do {
      let original = try isCurrent ? project : ProjectStore.open(folder: target)
      guard let original else { return }
      let dialog = NSAlert()
      dialog.messageText = "命名胶卷"
      let field = NSTextField(string: original.name ?? "")
      field.placeholderString = target.lastPathComponent
      field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
      dialog.accessoryView = field
      dialog.addButton(withTitle: "保存")
      dialog.addButton(withTitle: "取消")
      dialog.window.initialFirstResponder = field
      let complete: (NSApplication.ModalResponse) -> Void = { [weak self] response in
        guard response == .alertFirstButtonReturn, let self else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let name: String? = text.isEmpty ? nil : text
        if isCurrent {
          guard self.project?.id == original.id else { return }
          self.project?.name = name
          self.dirty = true
          if self.flushSave() { self.recentRolls?.updateName(folder: target, name: name) }
        } else {
          do {
            var updated = original
            updated.name = name
            _ = try ProjectStore.save(updated, folder: target, expectedModification: original.loadedModificationDate)
            self.recentRolls?.updateName(folder: target, name: name)
          } catch { self.errorMessage = error.localizedDescription }
        }
      }
      if let window = NSApp.keyWindow { dialog.beginSheetModal(for: window, completionHandler: complete) }
      else { complete(dialog.runModal()) }
    } catch { errorMessage = error.localizedDescription }
  }

  func exportPanel() {
    guard let project, let frame = activeFrame, folder != nil, !isExporting, !isCropping else { return }
    showExportPanel(project: project, targets: [frame.id])
  }
  func batchExportPanel(allFrames: Bool) {
    guard let project, !isExporting, !isCropping else { return }
    let targets = allFrames ? Set(project.frames.map(\.id)) : selection.selectedFrameIDs
    guard !targets.isEmpty else { return }
    showExportPanel(project: project, targets: targets)
  }
  private func showExportPanel(project: RollProject, targets: Set<UUID>) {
    guard !showExportDialog else { return }
    let options = ExportOptionsView(settings: project.exportSettings, filenamePrefix: rollName)
    guard let window = NSApp.keyWindow ?? NSApp.mainWindow, window.attachedSheet == nil else { return }
    let dialog = ExportDialogController(options: options, start: { [weak self] in
      guard let self, self.project?.id == project.id, !self.isExporting,
        options.isValid, let directory = options.destinationURL else { return }
      self.setExportSettings(options.settings)
      guard self.flushSave() else {
        self.exportDialog?.finish(message: "导出失败：设置未保存", detail: self.errorMessage)
        self.errorMessage = nil
        return
      }
      self.startExport(targetIDs: targets, directory: directory, filenamePrefix: options.filenamePrefix)
    }, cancel: { [weak self] in self?.cancelExport() }, close: { [weak self] in
      self?.showExportDialog = false
      self?.exportDialog = nil
    })
    exportDialog = dialog
    showExportDialog = true
    dialog.present(on: window)
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
      exportDialog?.showProgress(fraction: 0, detail: exportDetail)
      exportTask = Task {
        do {
          let summary = try await exportEngine.run(request, lut: assets.lut, p3Profile: assets.profile, fujifilmLUT: assets.fujifilmLUT,
            resolveConflict: { destination in
              try Task.checkCancellation()
              return await MainActor.run {
                guard !Task.isCancelled else { return .cancel }
                let alert = NSAlert()
                alert.messageText = "文件已存在，是否覆盖？"
                alert.informativeText = destination.lastPathComponent
                alert.addButton(withTitle: "是，覆盖")
                alert.addButton(withTitle: "否，自动重命名")
                alert.addButton(withTitle: "取消导出")
                switch alert.runModal() {
                case .alertFirstButtonReturn: return .overwrite
                case .alertSecondButtonReturn: return .rename
                default: return .cancel
                }
              }
            }) { progress in
            Task { @MainActor [weak self] in
              guard let self, self.exportGeneration == generation, self.isExporting,
                progress.fraction >= self.exportProgress else { return }
              self.exportProgress = progress.fraction
              self.exportDetail = "\(progress.processedCount)/\(progress.totalCount) · \(progress.currentName ?? "")"
              self.exportDialog?.showProgress(fraction: progress.fraction, detail: self.exportDetail)
            }
          }
          exportSummary = summary
          if summary.wasCancelled {
            exportDetail = "导出已取消 · 已完成 \(summary.completedCount) 张"
          } else if summary.failedCount > 0 {
            exportDetail = "导出失败 · 成功 \(summary.completedCount) 张，失败 \(summary.failedCount) 张"
          } else {
            exportDetail = "导出成功 · \(summary.completedCount) 张"
          }
          exportDialog?.finish(message: exportDetail,
            detail: summary.results.compactMap(\.error).first)
        } catch {
          exportDetail = "导出失败"
          if let exportDialog { exportDialog.finish(message: exportDetail, detail: error.localizedDescription) }
          else { errorMessage = error.localizedDescription }
        }
        isExporting = false
      }
    } catch {
      exportDetail = "导出失败"
      if let exportDialog { exportDialog.finish(message: exportDetail, detail: error.localizedDescription) }
      else { errorMessage = error.localizedDescription }
    }
  }
  func cancelExport() {
    exportTask?.cancel()
    exportDetail = "正在取消…"
    exportDialog?.showProgress(fraction: exportProgress, detail: exportDetail)
  }
  private func refreshThumbnails(changedFrom old: RollProject, to next: RollProject) {
    guard old.calibration == next.calibration,
      old.sprocketWhitening == next.sprocketWhitening else { refreshThumbnails(); return }
    let previous = Dictionary(uniqueKeysWithValues: old.frames.map { ($0.id, $0) })
    refreshThumbnails(affectedIDs: Set(next.frames.filter { previous[$0.id] != $0 }.map(\.id)))
  }
  private func refreshThumbnails(affectedIDs: Set<UUID>? = nil) {
    guard let project, let folder, let assets else { return }
    cancelPreviewWarmup()
    let available = Set(project.frames.filter { !$0.isMissing }.map(\.id))
    pendingThumbnailIDs.formUnion(affectedIDs ?? available)
    pendingThumbnailIDs.formIntersection(available)
    if thumbnails.keys.contains(where: { !available.contains($0) }) {
      thumbnails = thumbnails.filter { available.contains($0.key) }
    }
    thumbnailTask?.cancel()
    thumbnailGeneration = UUID()
    let generation = thumbnailGeneration
    let frames = project.frames.filter { pendingThumbnailIDs.contains($0.id) }
      .sorted { $0.id == selection.activeFrameID && $1.id != selection.activeFrameID }
    let cache = DiskThumbnailCache.forRoll(folder: folder, projectID: project.id)
    thumbnailTask = Task {
      defer {
        if generation == thumbnailGeneration {
          thumbnailTask = nil
          schedulePreviewWarmup()
        }
      }
      if affectedIDs == nil {
        try? await cache.migrateLegacy(from: folder)
        _ = try? await cache.maintain()
      }
      for frame in frames {
        guard !Task.isCancelled, generation == thumbnailGeneration else { return }
        do {
          let sourceURL = folder.appendingPathComponent(frame.filename)
          let stamp = try SourceStamp(url: sourceURL)
          let presentationKey = PreviewPresentationKey(source: stamp, frameID: frame.id,
            calibration: project.calibration, adjustments: frame.adjustments,
            orientation: frame.orientation, crop: frame.crop, stage: .final,
            sprocketWhitening: project.sprocketWhitening,
            protectedCrop: frame.crop)
          let encoder = JSONEncoder()
          encoder.outputFormatting = .sortedKeys
          let keyData = try encoder.encode(
            ThumbnailKey(
              filename: frame.filename,
              modified: stamp.modified?.timeIntervalSince1970 ?? 0,
              size: stamp.size,
              inode: stamp.inode,
              calibration: project.calibration, adjustments: frame.adjustments,
              orientation: frame.orientation,
              crop: frame.crop,
              sprocketWhitening: project.sprocketWhitening,
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
            assets: assets, original: !project.calibration.isCalibrated,
            orientation: frame.orientation, crop: frame.crop,
            sourceWidth: source.1, sourceHeight: source.2,
            sprocketWhitening: project.sprocketWhitening,
            protectedCrop: frame.crop)
          guard !Task.isCancelled, generation == thumbnailGeneration else { return }
          publishThumbnail(output.image, key: presentationKey)
          // Expendable disk cache failures never prevent editing or project save.
          try? await cache.store(output.image, for: key)
          guard !Task.isCancelled, generation == thumbnailGeneration else { return }
          pendingThumbnailIDs.remove(frame.id)
        } catch {
          // Keep the frame pending for a later refresh; disposable thumbnails
          // must not interrupt editing or replace the main preview's error.
        }
      }
    }
  }
  func relocatePanel(_ frameID: UUID) {
    guard let frame = project?.frames.first(where: { $0.id == frameID }), frame.isMissing else { return }
    let panel = NSOpenPanel()
    panel.title = "重新定位 \(frame.filename) · 选择本卷中的 TIFF 或 RAW"
    panel.allowedContentTypes = SourceImageIO.supportedContentTypes
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
    let sprocketWhitening: SprocketWhiteningSettings
    let algorithm: String
    let icc: String
    let lut: String
    let dimension: Int
    let presentationVersion: String
    let rawProcessing: RAWProcessingIdentity?
  }
  let adjustmentKeyboard = AdjustmentKeyboard()
}
