import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PrintroomCore

// MARK: - Snapshots & DTOs
public struct WinMatrixOptionDTO: Codable, Sendable {
  public let id: String
  public let name: String
  public let isBuiltIn: Bool
  public let isSnapshot: Bool
  public let values: [Float]
}

public struct WinCropDTO: Codable, Sendable {
  public let aspect: String
  public let centerX: Double
  public let centerY: Double
  public let width: Double
  public let angleDegrees: Double
  public let portrait: Bool
  public let freeRatio: Double?
  public let ratio: Double
  public let rectX: Double
  public let rectY: Double
  public let rectW: Double
  public let rectH: Double
}

public struct WinHistogramDTO: Codable, Sendable {
  public let stage: Int
  public let sampleCount: Int
  public let binsR: [UInt64]
  public let binsG: [UInt64]
  public let binsB: [UInt64]
}

public struct WinFrameDTO: Codable, Sendable {
  public let id: String
  public let filename: String
  public let isMissing: Bool
  public let needsReview: Bool
  public let thumbnailRevision: UInt64
}

public struct WinExportSettingsDTO: Codable, Sendable {
  public let format: String
  public let profile: String
  public let compression: String
  public let applyCrop: Bool
  public let overwriteExisting: Bool
  public let destinationPath: String?
  public let filenamePrefix: String?
  public let rollDefaultPrefix: String
}

public struct WinRecentRollDTO: Codable, Sendable {
  public let path: String
  public let projectID: String
  public let openedAtUnix: Double
  public let name: String?
  public let displayName: String
  public let isAvailable: Bool
}

public struct WinUIStateSnapshot: Codable, Sendable {
  public var revision: UInt64
  public var isImporting: Bool
  public var importCompleted: Int
  public var importTotal: Int
  public var importFailure: String?
  public var hasProject: Bool
  public var projectID: String?
  public var rollName: String
  public var folderPath: String?
  public var needsInitialRollNaming: Bool
  public var dirty: Bool
  public var saveFailure: Bool
  public var errorMessage: String?
  public var isLoading: Bool
  public var isRendering: Bool
  public var isPreviewPlaceholder: Bool
  public var isPreparingGeometry: Bool
  public var isAutoCropping: Bool
  public var autoCropProgressText: String
  public var autoCropCompletedRun: Int
  public var isAnalyzingRollTiming: Bool
  public var showMissingFilmBaseDialog: Bool
  public var showRollTimingConfirmation: Bool
  public var showRollTimingDialog: Bool
  public var rollTimingProgress: String
  public var rollTimingError: String?
  public var isExporting: Bool
  public var exportProgress: Double
  public var exportDetail: String
  public var exportFinished: Bool
  public var exportResultMessage: String?
  public var exportResultDetail: String?
  public var canUndo: Bool
  public var canRedo: Bool
  public var undoActionName: String?
  public var redoActionName: String?
  public var activeFrameID: String?
  public var selectedFrameIDs: [String]
  public var activeFilename: String?
  public var hasImage: Bool
  public var hasFilmBase: Bool
  public var canAdjustColors: Bool
  public var canPickNeutral: Bool
  public var canApply: Bool
  public var canSync: Bool
  public var canChangeSelectedOrientations: Bool
  public var canStartAutoCrop: Bool
  public var canStartRollTiming: Bool
  public var canOpenRollTiming: Bool
  public var sampling: Bool
  public var neutralPicking: Bool
  public var isNeutralSampling: Bool
  public var stage: Int
  public var histogramStage: Int
  public var cropPreviewEnabled: Bool
  public var sprocketWhiteningEnabled: Bool
  public var sprocketWhiteningThreshold: Double
  public var canAdjustSprocketWhitening: Bool
  public var sourceWidth: Int
  public var sourceHeight: Int
  public var displayWidth: Int
  public var displayHeight: Int
  public var isCropping: Bool
  public var canEditCrop: Bool
  public var cropRatioLocked: Bool
  public var cropViewportToken: Int
  public var presentsCrop: Bool
  public var cropTransitionSizeWidth: Int?
  public var cropTransitionSizeHeight: Int?
  public var presentedCropDisplay: WinCropDTO?
  public var cropReviewAvailable: Bool
  public var reviewOnlyPendingCrops: Bool
  public var pendingAutoCropFrameIDs: [String]
  public var previewBitmapRevision: UInt64
  public var previewWidth: Int
  public var previewHeight: Int
  public var histogram: WinHistogramDTO?
  public var histogramProbe: [Float]?
  public var cmosMatrixID: String
  public var cmosOptions: [WinMatrixOptionDTO]
  public var densityMatrixID: String
  public var densityOptions: [WinMatrixOptionDTO]
  public var matrixLibraryError: String?
  public var cmosCalibBusy: Bool
  public var cmosCalibValues: [Float]?
  public var cmosCalibIdentifications: [String]
  public var cmosCalibError: String?
  public var cmosCalibSuggestedName: String?
  public var timingMode: String
  public var simpleExposure: Double
  public var simpleTemperature: Double
  public var simpleTint: Double
  public var timingMaster: Int
  public var timingRed: Int
  public var timingGreen: Int
  public var timingBlue: Int
  public var contrastMaster: Float
  public var contrastRed: Float
  public var contrastGreen: Float
  public var contrastBlue: Float
  public var cineonLogLUT: String
  public var copiedSourceName: String?
  public var frames: [WinFrameDTO]
  public var exportSettings: WinExportSettingsDTO
  public var recentRolls: [WinRecentRollDTO]
  public var removedRecentRoll: WinRecentRollDTO?
  public var cacheLimitGB: Double
  public var cacheRetentionDays: Int
  public var cacheBytes: Int64?
  public var cacheError: String?
  public var availableUpdateVersion: String?
}

public struct WinCommand: Decodable, Sendable {
  public var action: String
  public var path: String?
  public var paths: [String]?
  public var replacingPath: String?
  public var frameID: String?
  public var ctrl: Bool?
  public var shift: Bool?
  public var delta: Int?
  public var name: String?
  public var boolValue: Bool?
  public var intValue: Int?
  public var doubleValue: Double?
  public var floatValue: Float?
  public var stringValue: String?
  public var x: Int?
  public var y: Int?
  public var width: Int?
  public var height: Int?
  public var operation: String?
  public var axis: String?
  public var channel: String?
  public var key: String?
  public var step: Int?
  public var kind: String?
  public var id: String?
  public var values: [Float]?
  public var apply: Bool?
  public var centerX: Double?
  public var centerY: Double?
  public var cropWidth: Double?
  public var angleDegrees: Double?
  public var aspect: String?
  public var portrait: Bool?
  public var freeRatio: Double?
  public var dx: Double?
  public var dy: Double?
  public var preserveExisting: Bool?
  public var inwardPercent: Double?
  public var aspectRatio: Double?
  public var autoExposure: Bool?
  public var preserveEdited: Bool?
  public var timing: Bool?
  public var contrast: Bool?
  public var lut: Bool?
  public var crop: Bool?
  public var allFrames: Bool?
  public var explicitDestination: String?
  public var filenamePrefix: String?
  public var format: String?
  public var profile: String?
  public var compression: String?
  public var applyCrop: Bool?
  public var overwriteExisting: Bool?
  public var limitGB: Double?
  public var retentionDays: Int?
}

// MARK: - Controller
public final class WinEditorController: @unchecked Sendable {
  public static let appVersion = "1.0.4"

  private struct UndoEntry {
    let snapshot: RollProject
    let name: String
  }

  private struct CropPreviewTransition {
    let size: Foundation.CGSize
    let isCropping: Bool
    let geometry: CropGeometry?
  }

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
    let assets: WinAppAssets
    let context: PreviewContext
    let adjustments: FrameAdjustments
    let revision: Int
  }

  private struct PendingExportConfig {
    let format: ExportFormat
    let profile: OutputColorProfile
    let compression: TIFFCompression
    let applyCrop: Bool
    let overwriteExisting: Bool
    let destinationPath: String
    let filenamePrefix: String
  }

  private let lock = NSLock()
  private var assets: WinAppAssets?
  private var stateRevision: UInt64 = 1

  // Roll & project state
  private let matrixStore = MatrixLibraryStore()
  private var matrixLibrary: [MatrixLibraryEntry] = []
  private var matrixLibraryError: String?
  private var project: RollProject?
  private var folder: URL?
  private var needsInitialRollNaming = false
  private var selection = SelectionState()
  private var snapshot: ParameterSnapshot?
  private let recentRolls = WinRecentRolls()
  private let defaults = UserDefaults.standard

  // Undo / redo stacks
  private var undoStack: [UndoEntry] = []
  private var redoStack: [UndoEntry] = []
  private var gestureBefore: RollProject?

  // Timing mode
  private var timingMode: TimingMode

  // Preview, bitmaps, geometry & histogram
  private var previewBitmap: WinDisplayBitmap?
  private var previewBitmapRevision: UInt64 = 0
  private var thumbnailBitmaps: [UUID: WinDisplayBitmap] = [:]
  private var thumbnailRevisions: [UUID: UInt64] = [:]
  private var cropPreviewTransition: CropPreviewTransition?
  private var isPreviewPlaceholder = false
  private var histogram: HistogramStatistics?
  private var histogramProbe: SIMD3<Float>?
  private var histogramProbeSnapshot: PreviewRequest?
  private var histogramProbePoint: Foundation.CGPoint?
  private var histogramStage: PipelineStage = .final
  private var stage: PipelineStage = .final
  private var sampling = false
  private var cropPreviewEnabled = true
  private var isCropping = false
  private var cropRatioLocked = true
  private var cropDraft: FrameCrop?
  private var cropViewportToken = 0

  // Services & background tasks
  private let imageService = WinImageService()
  private let previewRenderer = WinPreviewRenderService()
  private let thumbnailCoordinator = WinThumbnailCoordinator()
  private let exportEngine = ExportEngine()
  private let persistence = WinProjectPersistence()

  private var previewInput: PixelBuffer?
  private var previewInputIdentity = UUID()
  private var previewSourceStamp: SourceStamp?
  private var presentationCache = WinPreviewPresentationCache()
  private var previewContext: PreviewContext?
  private var pendingPreview: PreviewRequest?
  private var sourceWidth = 0
  private var sourceHeight = 0

  private var loadRevision = 0
  private var renderRevision = 0
  private var renderGeneration = UUID()
  private var loadTask: Task<Void, Never>?
  private var renderTask: Task<Void, Never>?
  private var previewWarmupTask: Task<Void, Never>?
  private var previewWarmupGeneration = UUID()

  private var proxyPreparationTask: Task<Void, Never>?
  private var importGeneration = UUID()
  private var importURL: URL?
  private var importReplacingRecent: String?
  private var isImporting = false
  private var importCompleted = 0
  private var importTotal = 0
  private var importFailure: String?

  private var isLoading = false
  private var isRendering = false
  private var dirty = false
  private var saveFailure = false
  private var errorMessage: String?

  // Calibration, neutral, roll timing, auto crop
  private var sampleTask: Task<Void, Never>?
  private var sampleRevision = 0
  private var pendingMatrixCalibration: FilmCalibration?
  private var neutralPicking = false
  private var isNeutralSampling = false
  private var neutralTask: Task<Void, Never>?
  private var neutralRevision = 0

  private var showMissingFilmBaseDialog = false
  private var showRollTimingConfirmation = false
  private var continueRollTimingAfterFilmBase = false
  private var showRollTimingDialog = false
  private var isAnalyzingRollTiming = false
  private var rollTimingProgress = ""
  private var rollTimingError: String?
  private var rollTimingTask: Task<Void, Never>?
  private var rollTimingGeneration = UUID()
  private var rollTimingSnapshot: RollProject?
  private var rollTimingResult: WinRollTimingResult?
  private var rollTimingAutoExposure = false

  private var isAutoCropping = false
  private var autoCropProgressText = ""
  private var autoCropCompletedRun = 0
  private var reviewOnlyPendingCrops = false
  private var cropReviewSession = false
  private var autoCropTask: Task<Void, Never>?
  private var autoCropGeneration = UUID()

  private var preparedGeometryMetadata: [URL: TIFFMetadata] = [:]
  private var isPreparingGeometry = false
  private var geometryPreparationTask: Task<Void, Never>?
  private var geometryPreparationToken = UUID()

  // CMOS 3-photo calibration task
  private var cmosCalibBusy = false
  private var cmosCalibValues: [Float]?
  private var cmosCalibIdentifications: [String] = []
  private var cmosCalibError: String?
  private var cmosCalibSuggestedName: String?
  private var cmosCalibTask: Task<Void, Never>?
  private var cmosCalibGeneration = UUID()

  // Export
  private var isExporting = false
  private var exportProgress = 0.0
  private var exportDetail = ""
  private var exportFinished = false
  private var exportResultMessage: String?
  private var exportResultDetail: String?
  private var exportTask: Task<Void, Never>?
  private var exportGeneration = UUID()

  // Cache & updates
  private var cachePolicy = DiskCachePolicy.load()
  private var cacheBytes: Int64?
  private var cacheError: String?
  private var cacheSizeBusy = false
  private var maintenanceTimerTask: Task<Void, Never>?
  private var availableUpdateVersion: String?
  private var updateChecked = false

  public init(assetsRoot: String? = nil) throws {
    self.timingMode = TimingMode(rawValue: defaults.string(forKey: TimingMode.preferenceKey) ?? "") ?? .simple
    do { self.matrixLibrary = try matrixStore.load() }
    catch { self.matrixLibraryError = error.localizedDescription }
    self.assets = try WinAppAssets(explicitRoot: assetsRoot)
    startBackgroundMaintenance()
    checkForUpdatesIfNeeded()
  }

  deinit {
    maintenanceTimerTask?.cancel()
    loadTask?.cancel()
    renderTask?.cancel()
    previewWarmupTask?.cancel()
    proxyPreparationTask?.cancel()
    rollTimingTask?.cancel()
    autoCropTask?.cancel()
    cmosCalibTask?.cancel()
    exportTask?.cancel()
    sampleTask?.cancel()
    neutralTask?.cancel()
    geometryPreparationTask?.cancel()
    thumbnailCoordinator.reset()
    persistence.cancel()
  }

  private func bumpLocked() {
    stateRevision &+= 1
  }

  private func startBackgroundMaintenance() {
    SourceProxyService.shared.scheduleMaintenance()
    maintenanceTimerTask = Task.detached(priority: .utility) {
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(3600)) } catch { return }
        guard !Task.isCancelled else { return }
        SourceProxyService.shared.scheduleMaintenance()
      }
    }
  }

  public func setHWND(_ hwnd: Int) {
    let changed = lock.withLock { assets?.displayColor.updateHWND(hwnd) ?? false }
    if changed {
      lock.withLock {
        presentationCache.clear()
        renderLocked()
        refreshThumbnailsLocked()
        bumpLocked()
      }
    }
  }

  public func pollStateIfChanged(lastRevision: UInt64) -> String? {
    let snapshot: WinUIStateSnapshot? = lock.withLock {
      guard stateRevision != lastRevision else { return nil }
      return makeSnapshotLocked()
    }
    guard let snapshot else { return nil }
    let encoder = JSONEncoder()
    guard let data = try? encoder.encode(snapshot) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  public func copyPreviewBGRA(
    outWidth: UnsafeMutablePointer<Int32>,
    outHeight: UnsafeMutablePointer<Int32>,
    outRevision: UnsafeMutablePointer<UInt64>,
    destBuffer: UnsafeMutablePointer<UInt8>?,
    destCapacity: Int
  ) -> Int32 {
    return lock.withLock {
      guard let bmp = previewBitmap else {
        outWidth.pointee = 0
        outHeight.pointee = 0
        outRevision.pointee = previewBitmapRevision
        return 0
      }
      outWidth.pointee = Int32(bmp.width)
      outHeight.pointee = Int32(bmp.height)
      outRevision.pointee = previewBitmapRevision
      let needed = bmp.bgra8.count
      guard let destBuffer, destCapacity >= needed else {
        return -Int32(needed)
      }
      bmp.bgra8.withUnsafeBytes { src in
        UnsafeMutableRawPointer(destBuffer).copyMemory(from: src.baseAddress!, byteCount: needed)
      }
      return Int32(needed)
    }
  }

  public func copyThumbnailBGRA(
    frameIDString: String,
    outWidth: UnsafeMutablePointer<Int32>,
    outHeight: UnsafeMutablePointer<Int32>,
    destBuffer: UnsafeMutablePointer<UInt8>?,
    destCapacity: Int
  ) -> Int32 {
    guard let uuid = UUID(uuidString: frameIDString) else { return 0 }
    return lock.withLock {
      guard let bmp = thumbnailBitmaps[uuid] else {
        outWidth.pointee = 0
        outHeight.pointee = 0
        return 0
      }
      outWidth.pointee = Int32(bmp.width)
      outHeight.pointee = Int32(bmp.height)
      let needed = bmp.bgra8.count
      guard let destBuffer, destCapacity >= needed else {
        return -Int32(needed)
      }
      bmp.bgra8.withUnsafeBytes { src in
        UnsafeMutableRawPointer(destBuffer).copyMemory(from: src.baseAddress!, byteCount: needed)
      }
      return Int32(needed)
    }
  }

  // MARK: - Command Dispatch
  public func dispatch(json: String) -> String {
    guard let data = json.data(using: .utf8) else {
      return encodeReply(ok: false, error: "命令编码无效")
    }
    do {
      let cmd = try JSONDecoder().decode(WinCommand.self, from: data)
      return try handleCommand(cmd)
    } catch {
      return encodeReply(ok: false, error: error.localizedDescription)
    }
  }

  private func encodeReply(ok: Bool, error: String? = nil, payload: [String: Any]? = nil) -> String {
    var dict: [String: Any] = ["ok": ok]
    if let error { dict["error"] = error }
    if let payload {
      for (k, v) in payload { dict[k] = v }
    }
    if let d = try? JSONSerialization.data(withJSONObject: dict),
       let s = String(data: d, encoding: .utf8) {
      return s
    }
    return "{\"ok\":false,\"error\":\"Serialization failed\"}"
  }

  private func handleCommand(_ cmd: WinCommand) throws -> String {
    switch cmd.action {
    case "openFolder":
      guard let p = cmd.path else { return encodeReply(ok: false, error: "缺少路径") }
      lock.withLock {
        openLocked(URL(fileURLWithPath: p), replacingRecent: cmd.replacingPath)
        bumpLocked()
      }
      return encodeReply(ok: true)

    case "openRecent":
      guard let p = cmd.path else { return encodeReply(ok: false, error: "缺少路径") }
      var needRelocate = false
      var projID = ""
      var lastName = ""
      lock.withLock {
        let entry = recentRolls.entries.first { $0.path == p }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue {
          openLocked(URL(fileURLWithPath: p, isDirectory: true))
          bumpLocked()
        } else {
          needRelocate = true
          projID = entry?.projectID.uuidString ?? ""
          lastName = URL(fileURLWithPath: p).lastPathComponent
        }
      }
      return encodeReply(ok: true, payload: [
        "needsRelocate": needRelocate,
        "projectID": projID,
        "lastName": lastName,
      ])

    case "relocateRecent":
      guard let oldPath = cmd.replacingPath, let newPath = cmd.path,
            let entry = lock.withLock({ recentRolls.entries.first { $0.path == oldPath } })
      else { return encodeReply(ok: false, error: "找不到最近打开记录") }
      let newURL = URL(fileURLWithPath: newPath, isDirectory: true)
      do {
        let roll = try ProjectStore.open(folder: newURL)
        guard roll.id == entry.projectID else {
          let msg = "所选文件夹不是这卷胶卷。请选取包含原胶卷设置的文件夹，或使用打开按钮打开其他胶卷。"
          lock.withLock { errorMessage = msg; bumpLocked() }
          return encodeReply(ok: false, error: msg)
        }
        lock.withLock {
          openLocked(newURL, replacingRecent: oldPath)
          bumpLocked()
        }
        return encodeReply(ok: true)
      } catch {
        lock.withLock { errorMessage = error.localizedDescription; bumpLocked() }
        return encodeReply(ok: false, error: error.localizedDescription)
      }

    case "cancelImport":
      lock.withLock { cancelImportLocked(); bumpLocked() }
      return encodeReply(ok: true)

    case "retryImport":
      lock.withLock { retryImportLocked(); bumpLocked() }
      return encodeReply(ok: true)

    case "returnHome":
      lock.withLock { returnHomeLocked(); bumpLocked() }
      return encodeReply(ok: true)

    case "clearNewRollNaming":
      lock.withLock { needsInitialRollNaming = false; bumpLocked() }
      return encodeReply(ok: true)

    case "removeRecentRoll":
      if let p = cmd.path {
        lock.withLock {
          if let entry = recentRolls.entries.first(where: { $0.path == p }) {
            recentRolls.removeEntry(entry) { [weak self] in
              guard let self else { return }
              self.lock.withLock {
                self.recentRolls.clearExpiredRemoval()
                self.bumpLocked()
              }
            }
          }
          bumpLocked()
        }
      }
      return encodeReply(ok: true)

    case "undoRemoveRecentRoll":
      lock.withLock {
        recentRolls.undoRemoval()
        bumpLocked()
      }
      return encodeReply(ok: true)

    case "renameRoll":
      let targetPath = cmd.path
      let rawText = cmd.name ?? ""
      let errMsg: String? = lock.withLock {
        guard let target = targetPath.map({ URL(fileURLWithPath: $0, isDirectory: true) }) ?? folder else {
          return "没有可命名的胶卷"
        }
        stopTimingKeyLocked()
        endAdjustmentLocked()
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let newName: String? = trimmed.isEmpty ? nil : trimmed
        let isCurrent = folder.map { PlatformFS.sameDirectory($0, target) } ?? false
        if isCurrent, project != nil {
          project?.name = newName
          dirty = true
          if flushSaveLocked() {
            recentRolls.updateName(folder: target, name: newName)
          }
          bumpLocked()
          return saveFailure ? errorMessage : nil
        } else {
          do {
            var updated = try ProjectStore.open(folder: target)
            updated.name = newName
            _ = try ProjectStore.save(updated, folder: target)
            recentRolls.updateName(folder: target, name: newName)
            bumpLocked()
            return nil
          } catch {
            errorMessage = error.localizedDescription
            bumpLocked()
            return error.localizedDescription
          }
        }
      }
      return errMsg == nil ? encodeReply(ok: true) : encodeReply(ok: false, error: errMsg)

    case "selectFrame":
      guard let idStr = cmd.frameID, let uuid = UUID(uuidString: idStr) else {
        return encodeReply(ok: false, error: "无效照片 ID")
      }
      lock.withLock {
        selectLocked(uuid, command: cmd.ctrl == true, shift: cmd.shift == true)
        bumpLocked()
      }
      return encodeReply(ok: true)

    case "selectAdjacent":
      lock.withLock {
        selectAdjacentFrameLocked(cmd.delta ?? 0)
        bumpLocked()
      }
      return encodeReply(ok: true)

    case "selectAll":
      lock.withLock {
        selectAllLocked()
        bumpLocked()
      }
      return encodeReply(ok: true)

    case "relocateFrame":
      guard let idStr = cmd.frameID, let uuid = UUID(uuidString: idStr), let p = cmd.path else {
        return encodeReply(ok: false, error: "参数不完整")
      }
      lock.withLock {
        relocateLocked(uuid, to: URL(fileURLWithPath: p))
        bumpLocked()
      }
      return encodeReply(ok: true)

    case "setStage":
      if let raw = cmd.intValue, let s = PipelineStage(rawValue: raw) {
        lock.withLock {
          if stage != s {
            stage = s
            previewBitmap = nil
            isPreviewPlaceholder = false
            renderLocked()
            showCachedPreviewLocked()
            bumpLocked()
          }
        }
      }
      return encodeReply(ok: true)

    case "setHistogramStage":
      if let raw = cmd.intValue, let s = PipelineStage(rawValue: raw) {
        lock.withLock {
          if histogramStage != s {
            histogramStage = s
            renderLocked()
            bumpLocked()
          }
        }
      }
      return encodeReply(ok: true)

    case "setCropPreviewEnabled":
      if let enabled = cmd.boolValue {
        lock.withLock {
          if cropPreviewEnabled != enabled {
            retainCropPreviewLocked()
            cropPreviewEnabled = enabled
            cropViewportToken += 1
            renderLocked(preservingHistogram: true)
            bumpLocked()
          }
        }
      }
      return encodeReply(ok: true)

    case "setSampling":
      if let v = cmd.boolValue {
        lock.withLock {
          setSamplingLocked(v)
          bumpLocked()
        }
      }
      return encodeReply(ok: true)

    case "beginFilmBaseSelection":
      lock.withLock {
        beginFilmBaseSelectionLocked(continueToRollTiming: cmd.boolValue == true)
        bumpLocked()
      }
      return encodeReply(ok: true)

    case "sampleDisplayedBase":
      guard let x = cmd.x, let y = cmd.y, let w = cmd.width, let h = cmd.height else {
        return encodeReply(ok: false, error: "选区参数缺失")
      }
      lock.withLock {
        sampleDisplayedBaseLocked(PixelRect(x: x, y: y, width: w, height: h))
        bumpLocked()
      }
      return encodeReply(ok: true)

    case "toggleNeutralPicker":
      lock.withLock {
        toggleNeutralPickerLocked()
        bumpLocked()
      }
      return encodeReply(ok: true)

    case "cancelNeutralPicker":
      lock.withLock {
        cancelNeutralPickerLocked()
        bumpLocked()
      }
      return encodeReply(ok: true)

    case "pickNeutralDisplayed":
      if let x = cmd.x, let y = cmd.y {
        lock.withLock {
          pickNeutralDisplayedLocked(x: x, y: y)
          bumpLocked()
        }
      }
      return encodeReply(ok: true)

    case "probeHistogram":
      if let x = cmd.x, let y = cmd.y {
        lock.withLock {
          if probeHistogramLocked(displayX: x, displayY: y) {
            bumpLocked()
          }
        }
      }
      return encodeReply(ok: true)

    case "clearHistogramProbe":
      lock.withLock {
        if clearHistogramProbeLocked() { bumpLocked() }
      }
      return encodeReply(ok: true)

    case "setTimingMode":
      if let raw = cmd.stringValue, let mode = TimingMode(rawValue: raw) {
        lock.withLock {
          if timingMode != mode {
            stopTimingKeyLocked()
            timingMode = mode
            defaults.set(mode.rawValue, forKey: TimingMode.preferenceKey)
            bumpLocked()
          }
        }
      }
      return encodeReply(ok: true)

    case "beginAdjustment":
      lock.withLock {
        beginAdjustmentLocked()
        bumpLocked()
      }
      return encodeReply(ok: true)

    case "endAdjustment":
      lock.withLock {
        endAdjustmentLocked()
        bumpLocked()
      }
      return encodeReply(ok: true)

    case "setSimpleTiming":
      guard let axisStr = cmd.axis, let val = cmd.doubleValue,
            let axis = parseSimpleAxis(axisStr) else {
        return encodeReply(ok: false, error: "无效简易 Timing 参数")
      }
      lock.withLock {
        editLocked { $0.timing = axis.setting(val, in: $0.timing) }
        bumpLocked()
      }
      return encodeReply(ok: true)

    case "setRGBTiming":
      guard let ch = cmd.channel, let val = cmd.intValue else {
        return encodeReply(ok: false, error: "无效 RGB Timing 参数")
      }
      let clamped = min(TimingParameters.range.upperBound, max(TimingParameters.range.lowerBound, val))
      lock.withLock {
        editLocked { a in
          switch ch {
          case "master": a.timing.master = clamped
          case "red": a.timing.red = clamped
          case "green": a.timing.green = clamped
          case "blue": a.timing.blue = clamped
          default: break
          }
        }
        bumpLocked()
      }
      return encodeReply(ok: true)

    case "setContrast":
      guard let ch = cmd.channel, let val = cmd.doubleValue, val.isFinite else {
        return encodeReply(ok: false, error: "无效 Contrast 参数")
      }
      let clamped = Float(min(2.0, max(0.25, val)))
      lock.withLock {
        editLocked { a in
          switch ch {
          case "master": a.contrast.master = clamped
          case "red": a.contrast.red = clamped
          case "green": a.contrast.green = clamped
          case "blue": a.contrast.blue = clamped
          default: break
          }
        }
        bumpLocked()
      }
      return encodeReply(ok: true)

    case "setLUT":
      guard let raw = cmd.stringValue, let lut = CineonLogLUT(rawValue: raw) else {
        return encodeReply(ok: false, error: "无效 LUT 选项")
      }
      lock.withLock {
        editLocked { $0.cineonLogLUT = lut }
        bumpLocked()
      }
      return encodeReply(ok: true)

    case "stepTimingKey":
      if let k = cmd.key {
        lock.withLock {
          handleTimingKeyLocked(k, step: cmd.step ?? 1)
          bumpLocked()
        }
      }
      return encodeReply(ok: true)

    case "stepContrastKey":
      if let k = cmd.key {
        lock.withLock {
          handleContrastKeyLocked(k, steps: cmd.step ?? 1)
          bumpLocked()
        }
      }
      return encodeReply(ok: true)

    case "resetAdjustments":
      lock.withLock {
        editLocked { $0 = .init() }
        bumpLocked()
      }
      return encodeReply(ok: true)

    case "setSprocketWhitening":
      if let enabled = cmd.boolValue, let threshold = cmd.doubleValue {
        lock.withLock {
          setSprocketWhiteningLocked(SprocketWhiteningSettings(enabled: enabled, thresholdPercent: threshold))
          bumpLocked()
        }
      }
      return encodeReply(ok: true)

    case "changeOrientation":
      if let op = parseOrientationOp(cmd.operation) {
        lock.withLock {
          changeOrientationLocked(op)
          bumpLocked()
        }
      }
      return encodeReply(ok: true)

    case "changeSelectedOrientations":
      if let op = parseOrientationOp(cmd.operation) {
        lock.withLock {
          changeSelectedOrientationsLocked(op)
          bumpLocked()
        }
      }
      return encodeReply(ok: true)

    case "beginCrop":
      lock.withLock {
        beginCropLocked()
        bumpLocked()
      }
      return encodeReply(ok: true)

    case "updateDisplayedCrop":
      guard let cx = cmd.centerX, let cy = cmd.centerY, let w = cmd.cropWidth, let deg = cmd.angleDegrees else {
        return encodeReply(ok: false, error: "裁剪参数不完整")
      }
      let aspect = CropAspectRatio(rawValue: cmd.aspect ?? "free") ?? .free
      let draft = FrameCrop(
        aspect: aspect, portrait: cmd.portrait == true,
        centerX: cx, centerY: cy, width: w, angleDegrees: deg,
        geometryVersion: 1, freeRatio: cmd.freeRatio)
      lock.withLock {
        updateDisplayedCropDraftLocked(draft)
        bumpLocked()
      }
      return encodeReply(ok: true)

    case "setCropRatioLocked":
      if let locked = cmd.boolValue {
        lock.withLock {
          setCropRatioLockedLocked(locked)
          bumpLocked()
        }
      }
      return encodeReply(ok: true)

    case "selectCropRatio":
      if let r = cmd.doubleValue {
        let aspect = CropAspectRatio(rawValue: cmd.aspect ?? "free") ?? .free
        lock.withLock {
          selectCropRatioLocked(r, aspect: aspect)
          bumpLocked()
        }
      }
      return encodeReply(ok: true)

    case "swapCropRatio":
      lock.withLock {
        swapCropRatioLocked()
        bumpLocked()
      }
      return encodeReply(ok: true)

    case "nudgeCropDraft":
      lock.withLock {
        nudgeCropDraftLocked(horizontal: cmd.dx ?? 0, vertical: cmd.dy ?? 0)
        bumpLocked()
      }
      return encodeReply(ok: true)

    case "nudgeCropAngle":
      if let d = cmd.doubleValue {
        lock.withLock {
          nudgeCropAngleLocked(d)
          bumpLocked()
        }
      }
      return encodeReply(ok: true)

    case "resetCropDraft":
      lock.withLock {
        resetCropDraftLocked()
        bumpLocked()
      }
      return encodeReply(ok: true)

    case "cancelCrop":
      lock.withLock {
        cancelCropLocked()
        bumpLocked()
      }
      return encodeReply(ok: true)

    case "commitCrop":
      lock.withLock {
        commitCropLocked()
        bumpLocked()
      }
      return encodeReply(ok: true)

    case "performCropPrimaryAction":
      lock.withLock {
        performCropPrimaryActionLocked()
        bumpLocked()
      }
      return encodeReply(ok: true)

    case "confirmCropAndAdvance":
      lock.withLock {
        confirmCropAndAdvanceLocked()
        bumpLocked()
      }
      return encodeReply(ok: true)

    case "reviewAutoCrops":
      lock.withLock {
        reviewAutoCropsLocked()
        bumpLocked()
      }
      return encodeReply(ok: true)

    case "setReviewOnlyPendingCrops":
      if let v = cmd.boolValue {
        lock.withLock {
          reviewOnlyPendingCrops = v
          bumpLocked()
        }
      }
      return encodeReply(ok: true)

    case "startAutoCrop":
      lock.withLock {
        startAutoCropLocked(
          preserveExisting: cmd.preserveExisting ?? true,
          inwardPercent: cmd.inwardPercent ?? 0,
          aspectRatio: cmd.aspectRatio ?? 1.5)
        bumpLocked()
      }
      return encodeReply(ok: true)

    case "cancelAutoCrop":
      lock.withLock {
        cancelAutoCropLocked()
        bumpLocked()
      }
      return encodeReply(ok: true)

    case "openRollTimingFlow":
      lock.withLock {
        stopTimingKeyLocked()
        endAdjustmentLocked()
        if !(project?.calibration.isCalibrated == true) {
          showMissingFilmBaseDialog = true
        } else {
          requestRollTimingConfirmationLocked()
        }
        bumpLocked()
      }
      return encodeReply(ok: true)

    case "dismissRollTimingModals":
      lock.withLock {
        cancelRollTimingLocked()
        bumpLocked()
      }
      return encodeReply(ok: true)

    case "startRollTiming":
      lock.withLock {
        showRollTimingConfirmation = false
        startRollTimingLocked(autoExposure: cmd.autoExposure ?? true)
        bumpLocked()
      }
      return encodeReply(ok: true)

    case "applyRollTiming":
      lock.withLock {
        applyRollTimingLocked(preserveEdited: cmd.preserveEdited ?? false)
        bumpLocked()
      }
      return encodeReply(ok: true)

    case "cancelRollTiming":
      lock.withLock {
        cancelRollTimingLocked()
        bumpLocked()
      }
      return encodeReply(ok: true)

    case "copyParameters":
      lock.withLock {
        copyParametersLocked()
        bumpLocked()
      }
      return encodeReply(ok: true)

    case "applyParameters":
      lock.withLock {
        applyParametersLocked()
        bumpLocked()
      }
      return encodeReply(ok: true)

    case "syncSettings":
      let ok = lock.withLock { () -> Bool in
        let res = syncCurrentSettingsLocked(
          timing: cmd.timing == true, contrast: cmd.contrast == true,
          lut: cmd.lut == true, crop: cmd.crop == true)
        bumpLocked()
        return res
      }
      return encodeReply(ok: ok)

    case "undo":
      lock.withLock {
        undoLocked()
        bumpLocked()
      }
      return encodeReply(ok: true)

    case "redo":
      lock.withLock {
        redoLocked()
        bumpLocked()
      }
      return encodeReply(ok: true)

    case "setMatrixPreset":
      guard let kStr = cmd.kind, let kind = MatrixKind(rawValue: kStr), let idStr = cmd.id else {
        return encodeReply(ok: false, error: "无效矩阵选择")
      }
      lock.withLock {
        if let preset = matrixOptionsLocked(kind).first(where: { $0.id == idStr }) {
          setMatrixPresetLocked(preset, kind: kind)
          bumpLocked()
        }
      }
      return encodeReply(ok: true)

    case "reloadMatrixLibrary":
      lock.withLock {
        reloadMatrixLibraryLocked()
        bumpLocked()
      }
      return encodeReply(ok: true)

    case "saveMatrix":
      guard let kStr = cmd.kind, let kind = MatrixKind(rawValue: kStr),
            let id = cmd.id, let name = cmd.name, let vals = cmd.values else {
        return encodeReply(ok: false, error: "矩阵保存参数不完整")
      }
      do {
        let matrix = try RGBMatrix(vals)
        let preset = try MatrixPreset(id: id, name: name, coefficients: matrix)
        try lock.withLock {
          try saveMatrixLocked(preset, kind: kind, apply: cmd.apply == true)
          bumpLocked()
        }
        return encodeReply(ok: true)
      } catch {
        return encodeReply(ok: false, error: error.localizedDescription)
      }

    case "deleteMatrix":
      guard let id = cmd.id else { return encodeReply(ok: false, error: "缺少矩阵 ID") }
      do {
        try lock.withLock {
          try deleteMatrixLocked(id: id)
          bumpLocked()
        }
        return encodeReply(ok: true)
      } catch {
        return encodeReply(ok: false, error: error.localizedDescription)
      }

    case "computeCMOSCalibration":
      let paths = cmd.paths ?? []
      guard paths.count == 3 else {
        let msg = "请选择恰好三张 TIFF / RAW 照片。"
        lock.withLock { cmosCalibError = msg; bumpLocked() }
        return encodeReply(ok: false, error: msg)
      }
      startCMOSCalibration(paths: paths)
      return encodeReply(ok: true)

    case "cancelCMOSCalibration":
      lock.withLock {
        cmosCalibGeneration = UUID()
        cmosCalibTask?.cancel()
        cmosCalibTask = nil
        cmosCalibBusy = false
        cmosCalibError = nil
        bumpLocked()
      }
      return encodeReply(ok: true)

    case "updateExportSettings":
      lock.withLock {
        var next = exportSettingsLocked
        if let f = cmd.format, let fmt = ExportFormat(rawValue: f) { next.format = fmt }
        if let p = cmd.profile, let prof = OutputColorProfile(rawValue: p) { next.profile = prof }
        if let c = cmd.compression, let comp = TIFFCompression(rawValue: c) { next.compression = comp }
        if let ac = cmd.applyCrop { next.applyCrop = ac }
        if let ow = cmd.overwriteExisting { next.overwriteExisting = ow }
        if let dp = cmd.path { next.destinationPath = dp }
        if let fp = cmd.filenamePrefix {
          let trimmed = fp.trimmingCharacters(in: .whitespacesAndNewlines)
          next.filenamePrefix = trimmed.isEmpty ? nil : trimmed
        }
        setExportSettingsLocked(next)
        bumpLocked()
      }
      return encodeReply(ok: true)

    case "startExport":
      guard let destDir = cmd.path else {
        return encodeReply(ok: false, error: "请选择导出目标文件夹")
      }
      let ok = startExportCommand(cmd: cmd, destinationPath: destDir)
      return encodeReply(ok: ok)

    case "cancelExport":
      lock.withLock {
        cancelExportLocked()
        bumpLocked()
      }
      return encodeReply(ok: true)

    case "resetExportDialogState":
      lock.withLock {
        if !isExporting {
          exportProgress = 0
          exportDetail = ""
          exportFinished = false
          exportResultMessage = nil
          exportResultDetail = nil
          bumpLocked()
        }
      }
      return encodeReply(ok: true)

    case "flushSave":
      let saved = lock.withLock { () -> Bool in
        let res = flushSaveLocked()
        bumpLocked()
        return res
      }
      return encodeReply(ok: saved, error: saved ? nil : lock.withLock { errorMessage })

    case "reloadDiscardingUnsaved":
      lock.withLock {
        if let folder {
          errorMessage = nil
          openLocked(folder, discardUnsaved: true)
          bumpLocked()
        }
      }
      return encodeReply(ok: true)

    case "clearError":
      lock.withLock {
        errorMessage = nil
        bumpLocked()
      }
      return encodeReply(ok: true)

    case "saveBackup":
      guard let targetPath = cmd.path else { return encodeReply(ok: false, error: "缺少保存路径") }
      let url = URL(fileURLWithPath: targetPath)
      do {
        try lock.withLock {
          guard let project else { throw PrintroomError.invalid("当前没有打开的胶卷") }
          if let folder,
             url.standardizedFileURL.resolvingSymlinksInPath()
              == folder.appendingPathComponent(ProjectStore.filename).standardizedFileURL.resolvingSymlinksInPath() {
            throw PrintroomError.invalid("请为设置副本选择不同文件名，不能覆盖当前项目")
          }
          let encoder = JSONEncoder()
          encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
          let data = try encoder.encode(project)
          try PlatformFS.atomicWrite(data, to: url)
          errorMessage = nil
          bumpLocked()
        }
        return encodeReply(ok: true)
      } catch {
        lock.withLock { errorMessage = error.localizedDescription; bumpLocked() }
        return encodeReply(ok: false, error: error.localizedDescription)
      }

    case "restoreBackup":
      guard let srcPath = cmd.path else { return encodeReply(ok: false, error: "缺少备份文件路径") }
      do {
        let data = try Data(contentsOf: URL(fileURLWithPath: srcPath))
        try lock.withLock {
          try restoreBackupLocked(data: data)
          bumpLocked()
        }
        return encodeReply(ok: true)
      } catch {
        lock.withLock { errorMessage = error.localizedDescription; bumpLocked() }
        return encodeReply(ok: false, error: error.localizedDescription)
      }

    case "refreshCacheInfo":
      refreshCacheSizeAsync()
      return encodeReply(ok: true)

    case "setCachePolicy":
      let err: String? = lock.withLock {
        if let limitGB = cmd.limitGB {
          guard limitGB.isFinite, (0.1...100_000).contains(limitGB) else {
            cacheError = "请输入 0.1–100000 之间的 GB 数值。"
            bumpLocked()
            return cacheError
          }
          cachePolicy.limitGB = limitGB
        }
        if let days = cmd.retentionDays {
          cachePolicy.retentionDays = days
        }
        cachePolicy.save()
        cacheError = nil
        SourceProxyService.shared.scheduleMaintenance()
        bumpLocked()
        return nil
      }
      refreshCacheSizeAsync()
      return err == nil ? encodeReply(ok: true) : encodeReply(ok: false, error: err)

    case "checkForUpdates":
      checkForUpdatesIfNeeded()
      return encodeReply(ok: true)

    default:
      return encodeReply(ok: false, error: "未知命令：\(cmd.action)")
    }
  }

  private func parseSimpleAxis(_ raw: String) -> SimpleTimingAxis? {
    switch raw {
    case "exposure": return .exposure
    case "temperature": return .temperature
    case "tint": return .tint
    default: return nil
    }
  }

  private func parseOrientationOp(_ raw: String?) -> OrientationOperation? {
    switch raw {
    case "rotateCounterclockwise": return .rotateCounterclockwise
    case "rotateClockwise": return .rotateClockwise
    case "flipHorizontal": return .flipHorizontal
    case "flipVertical": return .flipVertical
    default: return nil
    }
  }

  // MARK: - Core Controller Methods (called under `lock`)
  private var activeFrameLocked: FrameRecord? {
    project?.frames.first { $0.id == selection.activeFrameID }
  }
  private var hasFilmBaseLocked: Bool { project?.calibration.isCalibrated == true }
  private var hasImageLocked: Bool {
    previewBitmap != nil && activeFrameLocked != nil && !isPreviewPlaceholder && !isLoading && cropPreviewTransition == nil
  }
  private var canEditCropLocked: Bool {
    isCropping && !isLoading && !isPreviewPlaceholder && sourceWidth > 0 && sourceHeight > 0
  }
  private var canAdjustColorsLocked: Bool { hasFilmBaseLocked && activeFrameLocked != nil }
  private var canPickNeutralLocked: Bool {
    hasFilmBaseLocked && hasImageLocked && !isCropping && !sampling && !isNeutralSampling && !isRendering
  }
  private var canApplyLocked: Bool { hasFilmBaseLocked && snapshot != nil && !selection.selectedFrameIDs.isEmpty }
  private var orientationLocked: FrameOrientation { activeFrameLocked?.orientation ?? .identity }
  private var displayedCropLocked: FrameCrop? { isCropping || sampling || !cropPreviewEnabled ? nil : activeFrameLocked?.crop }
  private var displayGeometryLocked: CropGeometry? {
    try? CropGeometry(crop: displayedCropLocked, sourceWidth: sourceWidth,
                      sourceHeight: sourceHeight, orientation: orientationLocked)
  }
  private var displayWidthLocked: Int { displayGeometryLocked?.outputWidth ?? 0 }
  private var displayHeightLocked: Int { displayGeometryLocked?.outputHeight ?? 0 }
  private var cropDraftGeometryLocked: CropGeometry? {
    guard isCropping else { return nil }
    return try? CropGeometry(crop: cropDraft, sourceWidth: sourceWidth,
                             sourceHeight: sourceHeight, orientation: orientationLocked)
  }
  private var displayedCropDraftLocked: FrameCrop? { cropDraftGeometryLocked?.displayCrop }
  private var exportSettingsLocked: ProjectExportSettings { project?.exportSettings ?? .init() }
  private var pendingAutoCropFrameIDsLocked: Set<UUID> {
    Set(project?.frames.filter { !$0.isMissing && $0.cropNeedsReview }.map(\.id) ?? [])
  }
  private var cropReviewAvailableLocked: Bool { cropReviewSession || !pendingAutoCropFrameIDsLocked.isEmpty }
  private var canStartAutoCropLocked: Bool {
    project != nil && !isAutoCropping && !isCropping && !isLoading && !isExporting
      && project?.frames.contains(where: { !$0.isMissing }) == true
  }
  private var canOpenRollTimingLocked: Bool {
    guard let p = project else { return false }
    return p.frames.contains { !$0.isMissing }
      && !isCropping && !isLoading && !isAutoCropping && !isExporting
      && !showRollTimingDialog && !showMissingFilmBaseDialog && !showRollTimingConfirmation
      && !isNeutralSampling && !sampling && pendingMatrixCalibration == nil
  }
  private var canStartRollTimingLocked: Bool {
    guard let p = project else { return false }
    return canOpenRollTimingLocked && p.calibration.isCalibrated
      && p.calibration.cmosMatrix == p.calibration.sampledCMOSMatrix
      && p.calibration.matrix == p.calibration.sampledDensityMatrix
  }
  private var sprocketWhiteningLocked: SprocketWhiteningSettings { project?.sprocketWhitening ?? .init() }
  private var canAdjustSprocketWhiteningLocked: Bool {
    guard let project else { return false }
    return project.calibration.isCalibrated
      && project.frames.contains { !$0.isMissing && $0.crop != nil }
      && !isLoading && !isCropping && !isAutoCropping && !isExporting && !sampling
  }
  private var effectiveSprocketWhiteningLocked: SprocketWhiteningSettings {
    guard hasFilmBaseLocked, !sampling, !isCropping else { return .init() }
    return sprocketWhiteningLocked
  }

  private func retainCropPreviewLocked() {
    guard cropPreviewTransition == nil, previewBitmap != nil else { return }
    cropPreviewTransition = CropPreviewTransition(
      size: Foundation.CGSize(width: Double(displayWidthLocked), height: Double(displayHeightLocked)),
      isCropping: isCropping,
      geometry: cropDraftGeometryLocked)
  }

  private func setSamplingLocked(_ newValue: Bool) {
    guard sampling != newValue else { return }
    sampling = newValue
    if !sampling { continueRollTimingAfterFilmBase = false }
    schedulePreviewWarmupLocked()
    if sampling { cancelNeutralPickerLocked() }
    let changesGeometry = activeFrameLocked?.crop != nil || isCropping
    if sampling { isCropping = false; cropDraft = nil }
    guard changesGeometry else { return }
    previewBitmap = nil
    cropPreviewTransition = nil
    cropViewportToken += 1
    renderLocked()
  }

  private func openLocked(_ url: URL, discardUnsaved: Bool = false, replacingRecent: String? = nil) {
    stopTimingKeyLocked()
    guard !isExporting else {
      errorMessage = "请先完成或取消当前导出"
      return
    }
    guard discardUnsaved || (saveCropBeforeSwitchingLocked() && flushSaveLocked()) else { return }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
      errorMessage = "文件不存在：\(url.lastPathComponent)"
      return
    }
    cancelRollTimingLocked()
    cancelAutoCropLocked()
    resetAutoCropReviewLocked()
    cancelGeometryPreparationLocked()
    let targetFolder = isDirectory.boolValue ? url : url.deletingLastPathComponent()
    let preferred = isDirectory.boolValue ? nil : url
    do {
      let roll = try ProjectStore.open(folder: targetFolder, preferredFile: preferred)
      beginImportLocked(roll, folder: targetFolder, preferred: preferred, replacingRecent: replacingRecent)
    } catch { errorMessage = error.localizedDescription }
  }

  private func beginImportLocked(
    _ roll: RollProject, folder targetFolder: URL, preferred: URL?, replacingRecent: String?
  ) {
    resetEditorLocked()
    cancelImportLocked()
    let urls = roll.frames.filter { !$0.isMissing }
      .map { targetFolder.appendingPathComponent($0.filename) }
    guard !urls.isEmpty else {
      activateRollLocked(roll, folder: targetFolder, preferred: preferred, replacingRecent: replacingRecent)
      return
    }
    isImporting = true
    importCompleted = 0
    importTotal = urls.count
    importURL = preferred ?? targetFolder
    importReplacingRecent = replacingRecent
    let generation = UUID()
    importGeneration = generation
    proxyPreparationTask = Task.detached(priority: .userInitiated) { [weak self] in
      let failures = await WinSourcePrewarmer.prepare(urls, progress: { [weak self] completed in
        guard let self else { return }
        self.lock.withLock {
          if self.importGeneration == generation && self.isImporting {
            self.importCompleted = completed
            self.bumpLocked()
          }
        }
      })
      guard let self, !Task.isCancelled else { return }
      self.lock.withLock {
        guard self.importGeneration == generation else { return }
        self.proxyPreparationTask = nil
        guard failures.isEmpty else {
          self.importFailure = failures.map { "\($0.url.lastPathComponent)：\($0.message)" }.joined(separator: "\n")
          self.bumpLocked()
          return
        }
        self.isImporting = false
        self.importURL = nil
        self.activateRollLocked(roll, folder: targetFolder, preferred: preferred, replacingRecent: replacingRecent)
        self.bumpLocked()
      }
    }
  }

  private func cancelImportLocked() {
    importGeneration = UUID()
    proxyPreparationTask?.cancel()
    proxyPreparationTask = nil
    isImporting = false
    importFailure = nil
    importURL = nil
  }

  private func retryImportLocked() {
    guard let importURL else { return }
    openLocked(importURL, replacingRecent: importReplacingRecent)
  }

  private func returnHomeLocked() {
    if isImporting { cancelImportLocked(); return }
    guard project != nil, !isExporting else { return }
    stopTimingKeyLocked()
    endAdjustmentLocked()
    guard saveCropBeforeSwitchingLocked(), flushSaveLocked() else { return }
    resetEditorLocked()
  }

  private func resetEditorLocked() {
    cancelPreviewWarmupLocked()
    cancelRollTimingLocked()
    cancelAutoCropLocked()
    resetAutoCropReviewLocked()
    cancelGeometryPreparationLocked()
    project = nil
    folder = nil
    needsInitialRollNaming = false
    selection = SelectionState()
    snapshot = nil
    loadActiveLocked()
    thumbnailCoordinator.reset()
    thumbnailBitmaps = [:]
    thumbnailRevisions = [:]
    presentationCache.clear()
    preparedGeometryMetadata = [:]
    gestureBefore = nil
    undoStack.removeAll()
    redoStack.removeAll()
    exportResultMessage = nil
    exportResultDetail = nil
    exportFinished = false
    errorMessage = nil
  }

  private func activateRollLocked(
    _ roll: RollProject, folder targetFolder: URL, preferred: URL?, replacingRecent: String?
  ) {
    if folder.map({ !PlatformFS.sameDirectory($0, targetFolder) }) ?? true { snapshot = nil }
    thumbnailBitmaps = [:]
    thumbnailRevisions = [:]
    presentationCache.clear()
    loadTask?.cancel()
    renderTask?.cancel()
    thumbnailCoordinator.reset()
    persistence.cancel()
    folder = targetFolder
    project = roll
    recentRolls.record(folder: targetFolder, projectID: roll.id, replacing: replacingRecent, name: roll.name)
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
    undoStack.removeAll()
    redoStack.removeAll()
    dirty = true
    setSamplingLocked(false)
    _ = flushSaveLocked()
    loadActiveLocked()
    refreshThumbnailsLocked()
    if roll.loadedModificationDate == nil { needsInitialRollNaming = true }
  }

  private func selectLocked(_ id: UUID, command: Bool = false, shift: Bool = false) {
    stopTimingKeyLocked()
    guard let project else { return }
    let old = selection.activeFrameID
    var nextSelection = selection
    nextSelection.click(
      id, ordered: project.frames.filter { !$0.isMissing }.map(\.id), command: command, shift: shift)
    if old != nextSelection.activeFrameID, !saveCropBeforeSwitchingLocked() { return }
    if old != nextSelection.activeFrameID { retainCropPreviewLocked() }
    selection = nextSelection
    if old != selection.activeFrameID {
      loadActiveLocked(preservingCropMode: isCropping, preservingSamplingMode: sampling)
    }
    self.project?.lastActiveFrameID = selection.activeFrameID
    dirty = true
    scheduleSaveLocked()
  }

  private func selectAdjacentFrameLocked(_ delta: Int) {
    let frames = project?.frames.filter {
      !$0.isMissing && (!isCropping || !reviewOnlyPendingCrops || $0.cropNeedsReview)
    } ?? []
    guard !frames.isEmpty else { return }
    guard let index = frames.firstIndex(where: { $0.id == selection.activeFrameID }) else {
      selectLocked(frames[0].id)
      return
    }
    let next = index + delta
    guard frames.indices.contains(next), next != index else { return }
    selectLocked(frames[next].id)
  }

  private func selectAllLocked() {
    stopTimingKeyLocked()
    guard let project else { return }
    let before = selection.activeFrameID
    var nextSelection = selection
    nextSelection.selectAll(project.frames.filter { !$0.isMissing }.map(\.id))
    if before != nextSelection.activeFrameID { retainCropPreviewLocked() }
    selection = nextSelection
    if before != selection.activeFrameID { loadActiveLocked() }
  }

  private func saveCropBeforeSwitchingLocked(confirm: Bool = false) -> Bool {
    guard canEditCropLocked, var next = project,
          let index = next.frames.firstIndex(where: { $0.id == selection.activeFrameID })
    else { return true }
    do {
      next.frames[index].crop = try cropDraft?.sourceCoordinates(
        sourceWidth: sourceWidth, sourceHeight: sourceHeight, orientation: orientationLocked)
        .constrained(sourceWidth: sourceWidth, sourceHeight: sourceHeight)
      guard let old = project else { return true }
      if confirm || next.frames[index].crop != old.frames[index].crop {
        next.frames[index].cropOrigin = .manual
        next.frames[index].cropNeedsReview = false
      }
      guard next.frames != old.frames else { return true }
      registerUndoLocked(old: old, name: "裁剪照片")
      project = next
      dirty = true
      refreshThumbnailsLocked(affectedIDs: [next.frames[index].id])
      scheduleSaveLocked(immediate: true)
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  private func loadActiveLocked(preservingCropMode: Bool = false, preservingSamplingMode: Bool = false) {
    guard !isImporting else { return }
    cancelPreviewWarmupLocked()
    retainCropPreviewLocked()
    cancelGeometryPreparationLocked()
    isCropping = preservingCropMode
    cropDraft = nil
    if !preservingSamplingMode {
      sampling = false
      continueRollTimingAfterFilmBase = false
    }
    cancelSamplingLocked()
    cancelNeutralPickerLocked()
    isRendering = false
    loadTask?.cancel()
    cancelPreviewWorkerLocked()
    previewContext = nil
    loadRevision += 1
    renderRevision += 1
    let revision = loadRevision
    histogramProbeSnapshot = nil
    _ = clearHistogramProbeLocked()
    isPreviewPlaceholder = previewBitmap != nil
    previewSourceStamp = nil
    previewInput = nil
    sourceWidth = 0
    sourceHeight = 0
    guard let frame = activeFrameLocked, let folder else {
      histogram = nil
      previewBitmap = nil
      cropPreviewTransition = nil
      isPreviewPlaceholder = false
      isLoading = false
      isRendering = false
      return
    }
    isLoading = true
    let url = folder.appendingPathComponent(frame.filename)
    let initialStamp = try? SourceStamp(url: url)
    previewSourceStamp = initialStamp
    showCachedPreviewLocked()
    let imgSvc = imageService
    loadTask = Task.detached(priority: .userInitiated) { [weak self] in
      guard let self else { return }
      do {
        let result = try await imgSvc.preview(url)
        try Task.checkCancellation()
        let stamp = try SourceStamp(url: url)
        self.lock.withLock {
          guard revision == self.loadRevision else { return }
          guard stamp == self.previewSourceStamp else {
            self.isLoading = false
            self.histogram = nil
            self.previewBitmap = nil
            self.cropPreviewTransition = nil
            self.isPreviewPlaceholder = false
            self.errorMessage = PrintroomError.invalid("读取期间源图像已改变，请重新打开照片").localizedDescription
            self.bumpLocked()
            return
          }
          self.previewInput = result.0
          self.previewInputIdentity = UUID()
          self.sourceWidth = result.1
          self.sourceHeight = result.2
          if self.isCropping && self.cropDraft == nil {
            self.cropRatioLocked = true
            let initial = frame.crop ?? FrameCrop(aspect: .free, freeRatio: Double(self.sourceWidth) / Double(self.sourceHeight))
            self.cropDraft = try? initial.sourceCoordinates(
              sourceWidth: self.sourceWidth, sourceHeight: self.sourceHeight, orientation: frame.orientation)
            self.cropViewportToken += 1
          }
          if SourceImageIO.isRAW(url), let index = self.project?.frames.firstIndex(where: { $0.id == frame.id }) {
            let identity = try? SourceImageIO.processingIdentity(url: url)
            self.project?.frames[index].rawProcessing = identity
            self.dirty = true
            self.scheduleSaveLocked()
          }
          self.isLoading = false
          self.renderLocked()
          self.bumpLocked()
        }
      } catch {
        if !(error is CancellationError) {
          self.lock.withLock {
            guard revision == self.loadRevision else { return }
            self.isLoading = false
            self.histogram = nil
            self.previewBitmap = nil
            self.cropPreviewTransition = nil
            self.isPreviewPlaceholder = false
            self.errorMessage = error.localizedDescription
            self.bumpLocked()
          }
        }
      }
    }
  }

  private func cancelPreviewWorkerLocked() {
    renderTask?.cancel()
    renderTask = nil
    pendingPreview = nil
    renderGeneration = UUID()
  }

  private func presentationKeyLocked(stage overrideStage: PipelineStage? = nil) -> WinPreviewPresentationKey? {
    guard let source = previewSourceStamp, let frame = activeFrameLocked, let project else { return nil }
    return WinPreviewPresentationKey(
      source: source, frameID: frame.id, calibration: project.calibration,
      adjustments: frame.adjustments, orientation: frame.orientation, crop: displayedCropLocked,
      stage: overrideStage ?? self.stage, sprocketWhitening: effectiveSprocketWhiteningLocked,
      protectedCrop: sampling ? nil : frame.crop)
  }

  private func showCachedPreviewLocked() {
    guard isLoading || isRendering, previewBitmap == nil || isPreviewPlaceholder,
          let key = presentationKeyLocked() else { return }
    if let entry = presentationCache.image(for: key) {
      sourceWidth = entry.sourceWidth
      sourceHeight = entry.sourceHeight
      if isCropping {
        cropRatioLocked = true
        let initial = activeFrameLocked?.crop ?? FrameCrop(
          aspect: .free, freeRatio: Double(sourceWidth) / Double(sourceHeight))
        cropDraft = try? initial.sourceCoordinates(
          sourceWidth: sourceWidth, sourceHeight: sourceHeight, orientation: orientationLocked)
      }
      cropPreviewTransition = nil
      histogram = !isCropping && entry.histogram?.stage == histogramStage ? entry.histogram : nil
      histogramProbeSnapshot = nil
      _ = clearHistogramProbeLocked()
      previewBitmap = entry.bitmap
      previewBitmapRevision &+= 1
      isPreviewPlaceholder = true
    }
  }

  private func renderLocked(preservingHistogram: Bool = false) {
    cancelPreviewWarmupLocked()
    cancelNeutralPickerLocked()
    if histogram?.stage != histogramStage { histogram = nil }
    renderRevision += 1
    guard let input = previewInput, let project, let frame = activeFrameLocked, let assets else { return }
    let context = PreviewContext(
      source: previewInputIdentity, frameID: frame.id,
      calibration: project.calibration, stage: stage, histogramStage: histogramStage,
      orientation: frame.orientation, crop: displayedCropLocked,
      histogramCrop: sampling ? nil : frame.crop,
      sprocketWhitening: effectiveSprocketWhiteningLocked,
      sourceWidth: sourceWidth, sourceHeight: sourceHeight)
    if context != previewContext {
      if !preservingHistogram && !isPreviewPlaceholder && cropPreviewTransition == nil { histogram = nil }
      _ = clearHistogramProbeLocked()
      cancelPreviewWorkerLocked()
      previewContext = context
    }
    pendingPreview = PreviewRequest(
      input: input, assets: assets, context: context,
      adjustments: frame.adjustments, revision: renderRevision)
    isRendering = true
    guard renderTask == nil else { return }
    let generation = renderGeneration
    let renderer = previewRenderer
    renderTask = Task.detached(priority: .userInitiated) { [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        let request: PreviewRequest? = self.lock.withLock {
          guard generation == self.renderGeneration else { return nil }
          let req = self.pendingPreview
          self.pendingPreview = nil
          return req
        }
        guard let request else { break }
        do {
          let croppingNow = self.lock.withLock { self.isCropping }
          let result = try await renderer.render(
            request.input,
            calibration: request.context.calibration,
            adjustments: request.adjustments,
            assets: request.assets,
            stage: request.context.stage,
            original: !request.context.calibration.isCalibrated,
            orientation: request.context.orientation,
            inputIdentity: request.context.source,
            crop: request.context.crop,
            sourceWidth: request.context.sourceWidth,
            sourceHeight: request.context.sourceHeight,
            includeHistogram: !croppingNow,
            histogramStage: request.context.histogramStage,
            histogramCrop: request.context.histogramCrop,
            sprocketWhitening: request.context.sprocketWhitening,
            protectedCrop: request.context.histogramCrop)
          try Task.checkCancellation()
          var shouldWarm = false
          self.lock.withLock {
            guard generation == self.renderGeneration,
                  self.previewContext == request.context,
                  self.activeFrameLocked?.id == request.context.frameID else { return }
            self.cropPreviewTransition = nil
            self.histogram = result.histogram
            self.histogramProbeSnapshot = result.histogram == nil ? nil : request
            _ = self.clearHistogramProbeLocked()
            self.previewBitmap = result.bitmap
            self.previewBitmapRevision &+= 1
            self.isPreviewPlaceholder = false
            if let source = self.previewSourceStamp {
              let key = WinPreviewPresentationKey(
                source: source, frameID: request.context.frameID,
                calibration: request.context.calibration, adjustments: request.adjustments,
                orientation: request.context.orientation, crop: request.context.crop,
                stage: request.context.stage,
                sprocketWhitening: request.context.sprocketWhitening,
                protectedCrop: request.context.histogramCrop)
              self.presentationCache.store(.init(
                key: key, bitmap: result.bitmap,
                sourceWidth: request.context.sourceWidth, sourceHeight: request.context.sourceHeight,
                histogram: result.histogram))
            }
            if request.revision == self.renderRevision {
              self.isRendering = false
              shouldWarm = true
            }
            self.bumpLocked()
          }
          if shouldWarm {
            self.lock.withLock { self.schedulePreviewWarmupLocked() }
          }
        } catch {
          if error is CancellationError { return }
          self.lock.withLock {
            guard generation == self.renderGeneration else { return }
            if request.revision == self.renderRevision {
              self.isRendering = false
              self.errorMessage = error.localizedDescription
              self.bumpLocked()
            }
          }
        }
      }
      self.lock.withLock {
        if generation == self.renderGeneration {
          self.renderTask = nil
          if self.isRendering && self.pendingPreview == nil {
            self.isRendering = false
            self.bumpLocked()
          }
        }
      }
    }
  }

  private var canWarmPreviewsLocked: Bool {
    project != nil && folder != nil && hasImageLocked && assets != nil
      && !isImporting && !isLoading && !isRendering && !isExporting && !isCropping
      && !sampling && !neutralPicking && !isNeutralSampling && !isAutoCropping
      && !isAnalyzingRollTiming && !isPreparingGeometry && pendingMatrixCalibration == nil
      && gestureBefore == nil && !thumbnailCoordinator.isRunning
  }

  private func cancelPreviewWarmupLocked() {
    previewWarmupTask?.cancel()
    previewWarmupTask = nil
    previewWarmupGeneration = UUID()
  }

  private func schedulePreviewWarmupLocked() {
    cancelPreviewWarmupLocked()
    guard canWarmPreviewsLocked else { return }
    let generation = previewWarmupGeneration
    previewWarmupTask = Task.detached(priority: .utility) { [weak self] in
      do { try await Task.sleep(for: .seconds(1)) } catch { return }
      guard let self, !Task.isCancelled else { return }
      await self.warmPreviewCache(generation: generation)
      self.lock.withLock {
        if generation == self.previewWarmupGeneration { self.previewWarmupTask = nil }
      }
    }
  }

  private func warmPreviewCache(generation: UUID) async {
    let snapshot: (roll: RollProject, folder: URL, assets: WinAppAssets, candidates: [FrameRecord], stage: PipelineStage, hStage: PipelineStage, cropPrev: Bool, cacheLimit: Int)? = lock.withLock {
      guard generation == previewWarmupGeneration, canWarmPreviewsLocked,
            let roll = project, let folder, let assets else { return nil }
      let frames = roll.frames.filter { !$0.isMissing }
      let activeIndex = frames.firstIndex { $0.id == selection.activeFrameID } ?? 0
      let sorted = frames.enumerated().sorted {
        let lhs = abs($0.offset - activeIndex), rhs = abs($1.offset - activeIndex)
        return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
      }.prefix(presentationCache.countLimit).map(\.element)
      return (roll, folder, assets, sorted, stage, histogramStage, cropPreviewEnabled, presentationCache.countLimit)
    }
    guard let s = snapshot else { return }
    let renderer = WinPreviewRenderService()
    for frame in s.candidates {
      let ok = lock.withLock { generation == previewWarmupGeneration && canWarmPreviewsLocked }
      guard !Task.isCancelled, ok else { return }
      do {
        let url = s.folder.appendingPathComponent(frame.filename)
        let source = try SourceStamp(url: url)
        let crop = s.cropPrev ? frame.crop : nil
        let key = WinPreviewPresentationKey(
          source: source, frameID: frame.id, calibration: s.roll.calibration,
          adjustments: frame.adjustments, orientation: frame.orientation,
          crop: crop, stage: s.stage,
          sprocketWhitening: s.roll.calibration.isCalibrated ? s.roll.sprocketWhitening : .init(),
          protectedCrop: frame.crop)
        let input = try await imageService.preview(url)
        let stillValid = lock.withLock { generation == previewWarmupGeneration && canWarmPreviewsLocked }
        guard !Task.isCancelled, stillValid else { return }
        let alreadyCached = lock.withLock {
          presentationCache.contains(key, histogramStage: s.roll.calibration.isCalibrated ? s.hStage : nil)
        }
        if !alreadyCached {
          let result = try await renderer.render(
            input.0, calibration: s.roll.calibration, adjustments: frame.adjustments,
            assets: s.assets, stage: s.stage, original: !s.roll.calibration.isCalibrated,
            orientation: frame.orientation, inputIdentity: UUID(), crop: crop,
            sourceWidth: input.1, sourceHeight: input.2,
            includeHistogram: true, histogramStage: s.hStage, histogramCrop: frame.crop,
            sprocketWhitening: key.sprocketWhitening, protectedCrop: frame.crop)
          lock.withLock {
            guard generation == previewWarmupGeneration, canWarmPreviewsLocked,
                  let curFolder = self.folder, PlatformFS.sameDirectory(curFolder, s.folder),
                  self.project?.id == s.roll.id,
                  self.project?.calibration == s.roll.calibration,
                  self.project?.sprocketWhitening == s.roll.sprocketWhitening,
                  self.project?.frames.first(where: { $0.id == frame.id }) == frame,
                  self.stage == s.stage, self.histogramStage == s.hStage,
                  self.cropPreviewEnabled == s.cropPrev,
                  (try? SourceStamp(url: url)) == source else { return }
            if let activeKey = self.presentationKeyLocked() {
              _ = self.presentationCache.image(for: activeKey)
            }
            self.presentationCache.store(.init(
              key: key, bitmap: result.bitmap,
              sourceWidth: input.1, sourceHeight: input.2, histogram: result.histogram))
          }
        }
        try await Task.sleep(for: .milliseconds(120))
      } catch is CancellationError {
        return
      } catch {
        continue
      }
    }
  }

  private func clearHistogramProbeLocked() -> Bool {
    histogramProbePoint = nil
    if histogramProbe != nil {
      histogramProbe = nil
      return true
    }
    return false
  }

  private func probeHistogramLocked(displayX: Int, displayY: Int) -> Bool {
    guard !isCropping, !sampling, !isPreviewPlaceholder, cropPreviewTransition == nil,
          previewBitmap != nil, histogram != nil, let request = histogramProbeSnapshot,
          request.context == previewContext, request.context.frameID == activeFrameLocked?.id,
          let geometry = displayGeometryLocked,
          displayX >= 0, displayY >= 0,
          displayX < geometry.outputWidth, displayY < geometry.outputHeight else {
      return clearHistogramProbeLocked()
    }
    let point = geometry.sourcePoint(outputX: Double(displayX) + 0.5, outputY: Double(displayY) + 0.5)
    let x = max(0, min(request.context.sourceWidth - 1, Int(floor(point.x))))
    let y = max(0, min(request.context.sourceHeight - 1, Int(floor(point.y))))
    let sourcePoint = Foundation.CGPoint(x: x, y: y)
    guard histogramProbePoint != sourcePoint else { return false }
    histogramProbePoint = sourcePoint
    let samples = WinImageService.neutralSample(
      request.input,
      sourceWidth: request.context.sourceWidth,
      sourceHeight: request.context.sourceHeight,
      sourceX: x, sourceY: y)
    let value = try? HistogramProbe.median(
      samples,
      calibration: request.context.calibration,
      adjustments: request.adjustments,
      lut: request.assets.lut(for: request.adjustments.cineonLogLUT),
      stage: request.context.histogramStage)
    if value != histogramProbe {
      histogramProbe = value
      return true
    }
    return false
  }

  // MARK: - Edits, Undo & Adjustments
  private func stopTimingKeyLocked() {
    // Keyboard hold repeat runs on WPF UI side and calls begin/endAdjustment; nothing extra needed here
  }

  private func beginAdjustmentLocked() {
    cancelPreviewWarmupLocked()
    if gestureBefore == nil { gestureBefore = project }
  }

  private func endAdjustmentLocked() {
    if let old = gestureBefore, let current = project,
       old.frames != current.frames || old.sprocketWhitening != current.sprocketWhitening {
      registerUndoLocked(old: old, name: old.sprocketWhitening != current.sprocketWhitening ? "齿孔置白" : "调整参数")
      refreshThumbnailsLocked(changedFrom: old, to: current)
    }
    gestureBefore = nil
    scheduleSaveLocked(immediate: true)
    schedulePreviewWarmupLocked()
  }

  private func editLocked(actionName: String = "调整参数", _ mutate: (inout FrameAdjustments) -> Void) {
    guard var next = project,
          let index = next.frames.firstIndex(where: { $0.id == selection.activeFrameID }) else { return }
    let old = next
    mutate(&next.frames[index].adjustments)
    do { try Pipeline.validate(next.frames[index].adjustments) } catch {
      errorMessage = error.localizedDescription
      return
    }
    guard next.frames[index].adjustments != old.frames[index].adjustments else { return }
    if gestureBefore == nil { registerUndoLocked(old: old, name: actionName) }
    project = next
    dirty = true
    renderLocked()
    scheduleSaveLocked()
    if gestureBefore == nil { refreshThumbnailsLocked(affectedIDs: [next.frames[index].id]) }
  }

  private func handleTimingKeyLocked(_ key: String, step: Int = 1) {
    guard activeFrameLocked != nil else { return }
    let step = max(0, min(TimingParameters.range.count - 1, step))
    if timingMode == .simple {
      let axis: SimpleTimingAxis
      let sign: Int
      switch key.lowercased() {
      case "w": axis = .exposure; sign = 1
      case "s": axis = .exposure; sign = -1
      case "q": axis = .temperature; sign = -1
      case "e": axis = .temperature; sign = 1
      case "a": axis = .tint; sign = -1
      case "d": axis = .tint; sign = 1
      default: return
      }
      editLocked { $0.timing = axis.moving(sign * step, in: $0.timing) }
      return
    }
    editLocked { a in
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

  private func handleContrastKeyLocked(_ key: String, steps: Int = 1) {
    guard activeFrameLocked != nil else { return }
    let step = Float(max(0, min(175, steps))) * 0.01
    func adjusted(_ value: Float, _ direction: Float) -> Float {
      min(2, max(0.25, ((value + direction * step) * 100).rounded() / 100))
    }
    editLocked { a in
      switch key.lowercased() {
      case "q": a.contrast.red = adjusted(a.contrast.red, -1)
      case "e": a.contrast.red = adjusted(a.contrast.red, 1)
      case "a": a.contrast.green = adjusted(a.contrast.green, -1)
      case "d": a.contrast.green = adjusted(a.contrast.green, 1)
      case "z": a.contrast.blue = adjusted(a.contrast.blue, -1)
      case "c": a.contrast.blue = adjusted(a.contrast.blue, 1)
      case "w": a.contrast.master = adjusted(a.contrast.master, 1)
      case "s": a.contrast.master = adjusted(a.contrast.master, -1)
      default: break
      }
    }
  }

  private func registerUndoLocked(old: RollProject, name: String) {
    undoStack.append(UndoEntry(snapshot: old, name: name))
    if undoStack.count > 200 { undoStack.removeFirst() }
    redoStack.removeAll()
  }

  private func applyRestoredProjectLocked(_ value: RollProject) {
    guard let old = project else { return }
    cancelRollTimingLocked()
    cancelAutoCropLocked()
    resetAutoCropReviewLocked()
    cancelSamplingLocked()
    sampling = false
    isCropping = false
    cropDraft = nil
    let oldFrame = old.frames.first(where: { $0.id == selection.activeFrameID })
    let newFrame = value.frames.first(where: { $0.id == selection.activeFrameID })
    if oldFrame?.orientation != newFrame?.orientation || oldFrame?.crop != newFrame?.crop {
      previewBitmap = nil
      cropPreviewTransition = nil
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
    if old.frames.map({ $0.filename }) != value.frames.map({ $0.filename }) { loadActiveLocked() }
    else { renderLocked() }
    refreshThumbnailsLocked(changedFrom: old, to: value)
    scheduleSaveLocked(immediate: true)
  }

  private func undoLocked() {
    if isCropping { cancelCropLocked(); return }
    guard let current = project, let entry = undoStack.popLast() else { return }
    redoStack.append(UndoEntry(snapshot: current, name: entry.name))
    applyRestoredProjectLocked(entry.snapshot)
  }

  private func redoLocked() {
    if isCropping { cancelCropLocked(); return }
    guard let current = project, let entry = redoStack.popLast() else { return }
    undoStack.append(UndoEntry(snapshot: current, name: entry.name))
    applyRestoredProjectLocked(entry.snapshot)
  }

  // MARK: - Orientation, Crop, AutoCrop, Calibration, Neutral, RollTiming, Sprocket, Sync
  private func changeOrientationLocked(_ operation: OrientationOperation) {
    guard !isCropping, var next = project,
          let index = next.frames.firstIndex(where: { $0.id == selection.activeFrameID }) else { return }
    let old = next
    next.frames[index].orientation = next.frames[index].orientation.applying(operation)
    do {
      if next.frames[index].crop?.geometryVersion == 1 {
        next.frames[index].crop = try next.frames[index].crop?.sourceCoordinates(
          sourceWidth: sourceWidth, sourceHeight: sourceHeight, orientation: old.frames[index].orientation)
      }
    } catch { errorMessage = error.localizedDescription; return }
    guard next.frames != old.frames else { return }
    registerUndoLocked(old: old, name: "调整方向")
    cancelSamplingLocked()
    previewBitmap = nil
    cropPreviewTransition = nil
    project = next
    dirty = true
    renderLocked()
    refreshThumbnailsLocked(affectedIDs: [next.frames[index].id])
    scheduleSaveLocked(immediate: true)
  }

  private func changeSelectedOrientationsLocked(_ operation: OrientationOperation) {
    guard project != nil && !selection.selectedFrameIDs.isEmpty && !isCropping && !isLoading,
          let old = project, let folder else { return }
    let targets = selection.selectedFrameIDs
    let legacyURLs = old.frames.filter { targets.contains($0.id) && $0.crop?.geometryVersion == 1 }
      .map { folder.appendingPathComponent($0.filename) }
    if prepareGeometryIfNeededLocked(legacyURLs, then: { self.changeSelectedOrientationsLocked(operation) }) { return }
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
          let metadata = try geometryMetadataLocked(url)
          next.frames[index].crop = try frame.crop?.sourceCoordinates(
            sourceWidth: metadata.width, sourceHeight: metadata.height, orientation: frame.orientation)
        }
        next.frames[index].orientation = frame.orientation.applying(operation)
      }
      guard next.frames != old.frames else { return }
      registerUndoLocked(old: old, name: "调整\(targets.count)张底片方向")
      cancelSamplingLocked()
      previewBitmap = nil
      cropPreviewTransition = nil
      project = next
      dirty = true
      renderLocked()
      refreshThumbnailsLocked(affectedIDs: targets)
      scheduleSaveLocked(immediate: true)
    } catch { errorMessage = error.localizedDescription }
  }

  private func resetAutoCropReviewLocked() {
    reviewOnlyPendingCrops = false
    cropReviewSession = false
  }

  private func cancelAutoCropLocked() {
    autoCropTask?.cancel()
    autoCropTask = nil
    autoCropGeneration = UUID()
    isAutoCropping = false
    autoCropProgressText = ""
  }

  private func startAutoCropLocked(preserveExisting: Bool, inwardPercent: Double, aspectRatio: Double) {
    guard canStartAutoCropLocked, let old = project, let folder else { return }
    guard inwardPercent.isFinite, (0...5).contains(inwardPercent) else {
      errorMessage = "向内裁剪百分比必须在 0% 到 5% 之间。"
      return
    }
    guard aspectRatio.isFinite, (0.1...10).contains(aspectRatio) else {
      errorMessage = "画幅比例必须在 1:10 到 10:1 之间。"
      return
    }
    endAdjustmentLocked()
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
    autoCropTask = Task.detached(priority: .userInitiated) { [weak self] in
      guard let self else { return }
      do {
        let results = try await WinAutoCropService.run(inputs: inputs, targets: targets, aspectRatio: aspectRatio) { text in
          self.lock.withLock {
            if self.autoCropGeneration == generation {
              self.autoCropProgressText = text
              self.bumpLocked()
            }
          }
        }
        try Task.checkCancellation()
        self.lock.withLock {
          guard self.autoCropGeneration == generation,
                var next = self.project, next.id == old.id,
                let curFolder = self.folder, PlatformFS.sameDirectory(curFolder, folder) else { return }
          do {
            guard Set(results.map(\.id)) == targets, results.count == targets.count else {
              throw PrintroomError.invalid("自动裁剪未得到完整结果，原裁剪已保留。")
            }
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
            if let current = self.project, current.frames != next.frames {
              self.registerUndoLocked(old: current, name: "自动裁剪 \(results.count) 张")
              self.retainCropPreviewLocked()
              self.project = next
              self.dirty = true
              self.cropViewportToken += 1
              self.renderLocked()
              self.refreshThumbnailsLocked(affectedIDs: targets)
              self.scheduleSaveLocked(immediate: true)
            }
            self.isAutoCropping = false
            self.autoCropProgressText = ""
            self.autoCropTask = nil
            self.autoCropCompletedRun += 1
            self.bumpLocked()
          } catch {
            self.isAutoCropping = false
            self.autoCropProgressText = ""
            self.autoCropTask = nil
            self.errorMessage = error.localizedDescription
            self.bumpLocked()
          }
        }
      } catch {
        if !(error is CancellationError) {
          self.lock.withLock {
            guard self.autoCropGeneration == generation else { return }
            self.isAutoCropping = false
            self.autoCropProgressText = ""
            self.autoCropTask = nil
            self.errorMessage = error.localizedDescription
            self.bumpLocked()
          }
        }
      }
    }
  }

  private func reviewAutoCropsLocked() {
    guard !isAutoCropping, let frames = project?.frames.filter({ !$0.isMissing }), !frames.isEmpty else { return }
    let target = frames.first(where: { $0.cropNeedsReview })
      ?? frames.first(where: { $0.cropOrigin == .automatic }) ?? frames.first!
    guard saveCropBeforeSwitchingLocked() else { return }
    cropReviewSession = true
    reviewOnlyPendingCrops = !pendingAutoCropFrameIDsLocked.isEmpty
    retainCropPreviewLocked()
    selection.click(target.id, ordered: frames.map(\.id))
    project?.lastActiveFrameID = target.id
    dirty = true
    scheduleSaveLocked()
    loadActiveLocked(preservingCropMode: true)
  }

  private func performCropPrimaryActionLocked() {
    if cropReviewAvailableLocked && !pendingAutoCropFrameIDsLocked.isEmpty {
      confirmCropAndAdvanceLocked()
    } else {
      commitCropLocked()
    }
  }

  private func confirmCropAndAdvanceLocked() {
    guard canEditCropLocked, let id = selection.activeFrameID,
          let frames = project?.frames.filter({ !$0.isMissing }),
          let index = frames.firstIndex(where: { $0.id == id }),
          saveCropBeforeSwitchingLocked(confirm: true) else { return }
    let remaining = project?.frames.filter { !$0.isMissing && (!reviewOnlyPendingCrops || $0.cropNeedsReview) } ?? []
    let after = Set(frames.dropFirst(index + 1).map(\.id))
    if let next = remaining.first(where: { after.contains($0.id) }) {
      selectLocked(next.id)
    } else if reviewOnlyPendingCrops, let next = remaining.first {
      selectLocked(next.id)
    } else {
      reviewOnlyPendingCrops = false
      commitCropLocked()
      cropReviewSession = false
    }
  }

  private func beginCropLocked() {
    guard !isAutoCropping, !isCropping, !isLoading, !isPreviewPlaceholder, activeFrameLocked != nil,
          sourceWidth > 0, sourceHeight > 0 else { return }
    stopTimingKeyLocked()
    cancelSamplingLocked()
    sampling = false
    continueRollTimingAfterFilmBase = false
    let initial = activeFrameLocked?.crop ?? FrameCrop(aspect: .free, freeRatio: Double(sourceWidth) / Double(sourceHeight))
    do {
      let draft = try initial.sourceCoordinates(
        sourceWidth: sourceWidth, sourceHeight: sourceHeight, orientation: orientationLocked)
      retainCropPreviewLocked()
      cropDraft = draft
      cropRatioLocked = true
      isCropping = true
      cropViewportToken += 1
      renderLocked()
    } catch { errorMessage = error.localizedDescription }
  }

  private func updateDisplayedCropDraftLocked(_ value: FrameCrop) {
    guard canEditCropLocked else { return }
    do {
      cropDraft = try value.sourceCoordinates(
        sourceWidth: sourceWidth, sourceHeight: sourceHeight, orientation: orientationLocked)
    } catch { errorMessage = error.localizedDescription }
  }

  private var currentDisplayedCropLocked: FrameCrop {
    displayedCropDraftLocked ?? FrameCrop(
      aspect: .free, geometryVersion: 1,
      freeRatio: Double(max(1, displayWidthLocked)) / Double(max(1, displayHeightLocked)))
  }

  private func setCropRatioLockedLocked(_ locked: Bool) {
    guard canEditCropLocked else { return }
    if !locked, cropDraft != nil {
      var draft = currentDisplayedCropLocked
      let ratio = draft.ratio
      draft.aspect = .free
      draft.portrait = false
      draft.freeRatio = ratio
      updateDisplayedCropDraftLocked(draft)
    }
    cropRatioLocked = locked
  }

  private func selectCropRatioLocked(_ ratio: Double, aspect: CropAspectRatio = .free) {
    guard canEditCropLocked, ratio.isFinite, ratio > 0 else { return }
    var draft = currentDisplayedCropLocked
    draft.aspect = aspect
    draft.portrait = false
    draft.freeRatio = aspect == .free ? ratio : nil
    updateDisplayedCropDraftLocked(draft)
    cropRatioLocked = true
  }

  private func swapCropRatioLocked() {
    guard canEditCropLocked else { return }
    var draft = currentDisplayedCropLocked
    draft.portrait.toggle()
    updateDisplayedCropDraftLocked(draft)
  }

  private func nudgeCropDraftLocked(horizontal: Double, vertical: Double) {
    guard isCropping, let displayed = displayedCropDraftLocked else { return }
    var next = displayed
    next.centerX += horizontal
    next.centerY += vertical
    updateDisplayedCropDraftLocked(next)
  }

  private func nudgeCropAngleLocked(_ delta: Double) {
    guard isCropping, delta.isFinite else { return }
    var draft = displayedCropDraftLocked ?? FrameCrop(
      aspect: .free, geometryVersion: 1,
      freeRatio: Double(displayWidthLocked) / Double(max(1, displayHeightLocked)))
    draft.angleDegrees = (min(10, max(-10, draft.angleDegrees + delta)) * 100).rounded() / 100
    updateDisplayedCropDraftLocked(draft)
  }

  private func resetCropDraftLocked() {
    guard canEditCropLocked else { return }
    cropRatioLocked = true
    cropDraft = nil
  }

  private func cancelCropLocked() {
    guard isCropping else { return }
    retainCropPreviewLocked()
    isCropping = false
    cropDraft = nil
    cropViewportToken += 1
    renderLocked()
  }

  private func commitCropLocked() {
    guard canEditCropLocked, let old = project, let folder, let frame = activeFrameLocked else { return }
    let url = folder.appendingPathComponent(frame.filename)
    if prepareGeometryIfNeededLocked([url], then: { self.commitCropLocked() }) { return }
    do {
      let metadata = try geometryMetadataLocked(url)
      let crop = try cropDraft?.sourceCoordinates(
        sourceWidth: sourceWidth, sourceHeight: sourceHeight, orientation: orientationLocked)
      var next = old
      guard let index = next.frames.firstIndex(where: { $0.id == frame.id }), !frame.isMissing else {
        throw PrintroomError.invalid("裁剪照片不可用")
      }
      try next.frames[index].applyManualCrop(crop, sourceWidth: metadata.width, sourceHeight: metadata.height)
      retainCropPreviewLocked()
      let changed = next.frames != old.frames
      if changed { registerUndoLocked(old: old, name: "裁剪照片"); project = next; dirty = true }
      isCropping = false
      cropDraft = nil
      cropViewportToken += 1
      renderLocked()
      if changed { refreshThumbnailsLocked(affectedIDs: [frame.id]); scheduleSaveLocked(immediate: true) }
    } catch { errorMessage = error.localizedDescription }
  }

  private func cancelGeometryPreparationLocked() {
    geometryPreparationToken = UUID()
    geometryPreparationTask?.cancel()
    geometryPreparationTask = nil
    isPreparingGeometry = false
  }

  private func geometryProjectSnapshotLocked(_ value: RollProject) -> Data? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try? encoder.encode(value)
  }

  private func geometrySourceRevisionsLocked(_ urls: [URL]) -> [URL: String] {
    Dictionary(uniqueKeysWithValues: Set(urls).map { url in
      let st = try? PlatformFS.lstat(url)
      return (url, "\(st?.size ?? -1):\(st?.fileID ?? 0):\(st?.mtimeSec ?? -1):\(st?.mtimeNsec ?? -1)")
    })
  }

  private func geometryMetadataLocked(_ url: URL) throws -> TIFFMetadata {
    if let value = preparedGeometryMetadata[url] { return value }
    guard !SourceImageIO.isRAW(url) else { throw PrintroomError.invalid("RAW 尺寸尚未准备") }
    return try TIFFCodec.metadata(url: url)
  }

  @discardableResult
  private func prepareGeometryIfNeededLocked(_ urls: [URL], then commit: @escaping @Sendable () -> Void) -> Bool {
    let rawURLs = Array(Set(urls.filter { SourceImageIO.isRAW($0) && preparedGeometryMetadata[$0] == nil }))
    guard !rawURLs.isEmpty, let previous = project, let capturedFolder = folder else { return false }
    let encoded = geometryProjectSnapshotLocked(previous)
    let revisions = geometrySourceRevisionsLocked(urls)
    let active = selection.activeFrameID, selected = selection.selectedFrameIDs
    let draft = cropDraft, cropping = isCropping
    cancelGeometryPreparationLocked()
    let token = UUID()
    geometryPreparationToken = token
    isPreparingGeometry = true
    geometryPreparationTask = Task.detached(priority: .userInitiated) { [weak self] in
      guard let self else { return }
      do {
        var result: [URL: TIFFMetadata] = [:]
        for url in rawURLs {
          try Task.checkCancellation()
          result[url] = try SourceImageIO.metadata(url: url)
          try Task.checkCancellation()
        }
        try Task.checkCancellation()
        self.lock.withLock {
          if self.geometryPreparationToken == token {
            self.isPreparingGeometry = false
            self.geometryPreparationTask = nil
          }
          guard self.geometryPreparationToken == token,
                let curFolder = self.folder, PlatformFS.sameDirectory(curFolder, capturedFolder),
                self.project.flatMap({ self.geometryProjectSnapshotLocked($0) }) == encoded,
                self.selection.activeFrameID == active,
                self.selection.selectedFrameIDs == selected,
                self.cropDraft == draft, self.isCropping == cropping,
                self.geometrySourceRevisionsLocked(urls) == revisions else { return }
          self.preparedGeometryMetadata = result
          defer { self.preparedGeometryMetadata.removeAll() }
          commit()
          self.bumpLocked()
        }
      } catch {
        if !(error is CancellationError) {
          self.lock.withLock {
            if self.geometryPreparationToken == token {
              self.isPreparingGeometry = false
              self.geometryPreparationTask = nil
              if let curFolder = self.folder, PlatformFS.sameDirectory(curFolder, capturedFolder) {
                self.errorMessage = error.localizedDescription
              }
              self.bumpLocked()
            }
          }
        }
      }
    }
    return true
  }

  private func requestRollTimingConfirmationLocked() {
    guard canStartRollTimingLocked else { return }
    showRollTimingConfirmation = true
  }

  private func beginFilmBaseSelectionLocked(continueToRollTiming: Bool) {
    showMissingFilmBaseDialog = false
    guard hasImageLocked, !isCropping else { return }
    stopTimingKeyLocked()
    endAdjustmentLocked()
    setSamplingLocked(true)
    continueRollTimingAfterFilmBase = continueToRollTiming
  }

  private func cancelRollTimingLocked() {
    rollTimingTask?.cancel(); rollTimingTask = nil
    rollTimingGeneration = UUID()
    showMissingFilmBaseDialog = false
    showRollTimingConfirmation = false
    showRollTimingDialog = false
    isAnalyzingRollTiming = false
    rollTimingSnapshot = nil
    rollTimingResult = nil
    rollTimingError = nil
  }

  private func startRollTimingLocked(autoExposure: Bool) {
    guard canStartRollTimingLocked, let folder, let assets, let old = project else { return }
    endAdjustmentLocked()
    cancelSamplingLocked()
    neutralPicking = false
    rollTimingAutoExposure = autoExposure
    rollTimingSnapshot = old; rollTimingResult = nil; rollTimingError = nil
    let generation = UUID()
    rollTimingGeneration = generation
    showRollTimingDialog = true; isAnalyzingRollTiming = true
    rollTimingProgress = "正在分析…"
    rollTimingTask = Task.detached(priority: .userInitiated) { [weak self] in
      guard let self else { return }
      do {
        let result = try await WinRollTimingService.run(project: old, folder: folder, assets: assets, autoExposure: autoExposure) { text in
          self.lock.withLock {
            if self.rollTimingGeneration == generation {
              self.rollTimingProgress = text
              self.bumpLocked()
            }
          }
        }
        try Task.checkCancellation()
        self.lock.withLock {
          guard self.rollTimingGeneration == generation else { return }
          self.rollTimingResult = result
          self.isAnalyzingRollTiming = false
          self.rollTimingTask = nil
          self.bumpLocked()
        }
      } catch {
        if !(error is CancellationError) {
          self.lock.withLock {
            guard self.rollTimingGeneration == generation else { return }
            self.rollTimingError = error.localizedDescription
            self.isAnalyzingRollTiming = false
            self.rollTimingTask = nil
            self.bumpLocked()
          }
        }
      }
    }
  }

  private func applyRollTimingLocked(preserveEdited: Bool) {
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
        registerUndoLocked(old: current, name: "整卷自动调色")
        project = next; dirty = true
        renderLocked(); refreshThumbnailsLocked(affectedIDs: targets); scheduleSaveLocked(immediate: true)
      }
      cancelRollTimingLocked()
    } catch { rollTimingError = error.localizedDescription; rollTimingResult = nil }
  }

  private func cancelSamplingLocked() {
    continueRollTimingAfterFilmBase = false
    pendingMatrixCalibration = nil
    cancelNeutralPickerLocked()
    sampleTask?.cancel()
    sampleRevision += 1
  }

  private func sampleDisplayedBaseLocked(_ rect: PixelRect) {
    guard hasImageLocked else { return }
    do {
      let inv = try orientationLocked.inverseRect(rect, sourceWidth: sourceWidth, sourceHeight: sourceHeight)
      sampleBaseLocked(inv)
    } catch { errorMessage = error.localizedDescription }
  }

  private func sampleBaseLocked(_ rect: PixelRect) {
    guard let folder, let frame = activeFrameLocked, let project else { return }
    let continueToRollTiming = continueRollTimingAfterFilmBase
    cancelSamplingLocked()
    let revision = sampleRevision
    let id = frame.id
    let matrix = project.calibration.matrix
    let cmos = project.calibration.cmosMatrix
    let rollID = project.id
    sampling = false
    cancelPreviewWarmupLocked()
    let fileURL = folder.appendingPathComponent(frame.filename)
    let imgSvc = imageService
    sampleTask = Task.detached(priority: .userInitiated) { [weak self] in
      guard let self else { return }
      do {
        let result = try await imgSvc.sample(fileURL, rect: rect, matrix: matrix, frameID: id, cmosMatrix: cmos)
        try Task.checkCancellation()
        self.lock.withLock {
          guard revision == self.sampleRevision, var next = self.project, next.id == rollID else { return }
          guard next.calibration.matrix == matrix, next.calibration.cmosMatrix == cmos else { return }
          let firstCalibration = !next.calibration.isCalibrated
          next.calibration = result
          next.calibrationNeedsReview = false
          if let old = self.project { self.registerUndoLocked(old: old, name: "片基校准") }
          self.project = next
          if firstCalibration { self.stage = .final }
          self.dirty = true
          self.renderLocked()
          self.refreshThumbnailsLocked()
          self.scheduleSaveLocked(immediate: true)
          if continueToRollTiming && self.errorMessage == nil {
            self.requestRollTimingConfirmationLocked()
          }
          self.bumpLocked()
        }
      } catch {
        if !(error is CancellationError) {
          self.lock.withLock {
            if revision == self.sampleRevision {
              self.errorMessage = error.localizedDescription
              self.bumpLocked()
            }
          }
        }
      }
    }
  }

  private func toggleNeutralPickerLocked() {
    if neutralPicking || isNeutralSampling { cancelNeutralPickerLocked(); return }
    guard canPickNeutralLocked else { return }
    neutralPicking = true
  }

  private func cancelNeutralPickerLocked() {
    neutralTask?.cancel()
    neutralTask = nil
    neutralRevision += 1
    neutralPicking = false
    isNeutralSampling = false
  }

  private func pickNeutralDisplayedLocked(x: Int, y: Int) {
    guard neutralPicking, canPickNeutralLocked, let geometry = displayGeometryLocked,
          let frame = activeFrameLocked, let project, let folder, let assets,
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

    func contextIsCurrentLocked() -> Bool {
      token == neutralRevision && revision == renderRevision && loadID == loadRevision
        && self.folder.map({ PlatformFS.sameDirectory($0, folder) }) == true
        && activeFrameLocked == frame && self.project?.id == project.id
        && self.project?.calibration == project.calibration
        && sourceWidth == width && sourceHeight == height && stage == expectedStage
        && !sampling && !isCropping && previewSourceStamp == stamp
    }

    let imgSvc = imageService
    neutralTask = Task.detached(priority: .userInitiated) { [weak self] in
      guard let self else { return }
      defer {
        self.lock.withLock {
          if token == self.neutralRevision {
            self.isNeutralSampling = false
            self.neutralTask = nil
            self.bumpLocked()
          }
        }
      }
      do {
        try Task.checkCancellation()
        guard self.lock.withLock({ contextIsCurrentLocked() }) else { return }
        guard try SourceStamp(url: url) == stamp else {
          throw PrintroomError.invalid("源图像已改变，请重新打开照片后取样")
        }
        let samples = try await imgSvc.neutralSample(url, sourceX: sx, sourceY: sy)
        try Task.checkCancellation()
        guard try SourceStamp(url: url) == stamp else {
          throw PrintroomError.invalid("取样期间源图像已改变，请重新打开照片")
        }
        guard self.lock.withLock({ contextIsCurrentLocked() }) else { return }
        let solved: FrameAdjustments
        do {
          solved = try NeutralTiming.solve(
            samples, calibration: project.calibration, adjustments: frame.adjustments,
            lut: assets.lut(for: frame.adjustments.cineonLogLUT), p3Profile: assets.profile)
        } catch {
          return
        }
        try Task.checkCancellation()
        self.lock.withLock {
          guard contextIsCurrentLocked() else { return }
          guard (try? SourceStamp(url: url)) == stamp else {
            self.errorMessage = PrintroomError.invalid("标定期间源图像已改变，请重新打开照片").localizedDescription
            self.bumpLocked()
            return
          }
          self.editLocked(actionName: "标定 Final 中性点") { $0 = solved }
          self.bumpLocked()
        }
      } catch {
        if !(error is CancellationError) {
          self.lock.withLock {
            if contextIsCurrentLocked() {
              self.errorMessage = error.localizedDescription
              self.bumpLocked()
            }
          }
        }
      }
    }
  }

  private func setSprocketWhiteningLocked(_ settings: SprocketWhiteningSettings) {
    guard var next = project, settings != next.sprocketWhitening else { return }
    guard !settings.enabled || canAdjustSprocketWhiteningLocked else { return }
    do { try settings.validate() } catch { errorMessage = error.localizedDescription; return }
    let old = next
    next.sprocketWhitening = settings
    if gestureBefore == nil { registerUndoLocked(old: old, name: "齿孔置白") }
    project = next
    dirty = true
    renderLocked()
    scheduleSaveLocked(immediate: gestureBefore == nil)
    if gestureBefore == nil { refreshThumbnailsLocked() }
  }

  private func copyParametersLocked() {
    guard let frame = activeFrameLocked else { return }
    snapshot = ParameterSnapshot(frame: frame)
  }

  private func applyParametersLocked() {
    guard let snapshot, let project, !selection.selectedFrameIDs.isEmpty, let folder else { return }
    do {
      let targets = selection.selectedFrameIDs
      let next = try BatchEditTransaction.applying(snapshot, to: project, targets: targets, folder: folder)
      guard next.frames != project.frames else { return }
      registerUndoLocked(old: project, name: "应用到 \(targets.count) 张")
      self.project = next
      dirty = true
      renderLocked()
      refreshThumbnailsLocked(affectedIDs: targets)
      scheduleSaveLocked(immediate: true)
    } catch { errorMessage = error.localizedDescription }
  }

  private var syncTargetIDsLocked: Set<UUID> {
    selection.selectedFrameIDs.subtracting(selection.activeFrameID.map { [$0] } ?? [])
  }
  private var canSyncLocked: Bool {
    activeFrameLocked != nil && !syncTargetIDsLocked.isEmpty && !isCropping && !isLoading
  }

  private func syncCurrentSettingsLocked(timing: Bool, contrast: Bool, lut: Bool, crop: Bool) -> Bool {
    guard canSyncLocked, (timing || contrast || lut || crop),
          let source = activeFrameLocked, let old = project, let folder else { return false }
    let targets = syncTargetIDsLocked
    let urls = old.frames.filter { targets.contains($0.id) || $0.id == source.id }
      .map { folder.appendingPathComponent($0.filename) }
    if crop, prepareGeometryIfNeededLocked(urls, then: {
      _ = self.syncCurrentSettingsLocked(timing: timing, contrast: contrast, lut: lut, crop: crop)
    }) { return false }
    do {
      let next = try BatchEditTransaction.synchronize(
        project: old, source: source, targets: targets, folder: folder,
        options: .init(timing: timing, contrast: contrast, lut: lut, crop: crop),
        metadata: { try self.geometryMetadataLocked($0) })
      guard next.frames != old.frames else { return true }
      registerUndoLocked(old: old, name: "同步到其余 \(targets.count) 张")
      project = next
      dirty = true
      refreshThumbnailsLocked(affectedIDs: targets)
      scheduleSaveLocked(immediate: true)
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  // MARK: - Matrices
  private func matrixOptionsLocked(_ kind: MatrixKind) -> [MatrixPreset] {
    var result = kind.builtIns + matrixLibrary.filter { $0.kind == kind }.map(\.preset)
    let selected = kind == .cmos ? (project?.calibration.cmosMatrix ?? .identity) : (project?.calibration.matrix ?? .identity)
    if !result.contains(selected) { result.append(selected) }
    return result
  }

  private func isMatrixSnapshotLocked(_ value: MatrixPreset, kind: MatrixKind) -> Bool {
    !value.isBuiltIn && !matrixLibrary.contains { $0.kind == kind && $0.preset == value }
  }

  private func reloadMatrixLibraryLocked() {
    do { matrixLibrary = try matrixStore.load(); matrixLibraryError = nil }
    catch { matrixLibraryError = error.localizedDescription }
  }

  private func saveMatrixLocked(_ preset: MatrixPreset, kind: MatrixKind, apply: Bool) throws {
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
    if apply { setMatrixPresetLocked(preset, kind: kind) }
  }

  private func deleteMatrixLocked(id: String) throws {
    guard matrixLibraryError == nil,
          let match = matrixLibrary.first(where: { $0.preset.id == id }), !match.preset.isBuiltIn else {
      throw PrintroomError.invalid("内置矩阵不可删除；矩阵库读取失败时请先重新载入。")
    }
    let next = matrixLibrary.filter { $0.preset.id != id }
    try matrixStore.save(next, replacing: matrixLibrary)
    matrixLibrary = next
  }

  private func setMatrixPresetLocked(_ preset: MatrixPreset, kind: MatrixKind) {
    guard let current = project, !preset.isBuiltIn || kind.builtIns.contains(preset) else { return }
    var target = pendingMatrixCalibration ?? current.calibration
    if kind == .cmos {
      guard target.cmosMatrix != preset else { return }
      target.cmosMatrix = preset
    } else {
      guard target.matrix != preset else { return }
      target.matrix = preset
    }
    cancelSamplingLocked()
    guard target != current.calibration else { return }
    do {
      guard target.isCalibrated else {
        commitMatrixCalibrationLocked(target, name: "切换\(kind.label)")
        return
      }
      if target.cmosMatrix == target.sampledCMOSMatrix {
        target = try Pipeline.recalibrate(target, matrix: target.matrix)
        commitMatrixCalibrationLocked(target, name: "切换\(kind.label)并对齐片基")
        return
      }
      guard let rect = target.selection, let sourceID = target.sourceFrameID else {
        throw PrintroomError.invalid("片基采样记录不完整。")
      }
      let sourceURL = try calibrationSourceLocked(current)
      let requested = target
      let revision = sampleRevision
      pendingMatrixCalibration = requested
      let imgSvc = imageService
      sampleTask = Task.detached(priority: .userInitiated) { [weak self] in
        guard let self else { return }
        do {
          let result = try await imgSvc.sample(
            sourceURL, rect: rect, matrix: requested.matrix, frameID: sourceID, cmosMatrix: requested.cmosMatrix)
          try Task.checkCancellation()
          self.lock.withLock {
            guard revision == self.sampleRevision,
                  let latest = self.project, latest.id == current.id,
                  latest.calibration == current.calibration else { return }
            _ = try? self.calibrationSourceLocked(latest)
            guard result.sourceWidth == requested.sourceWidth,
                  result.sourceHeight == requested.sourceHeight else {
              self.pendingMatrixCalibration = nil
              self.errorMessage = PrintroomError.invalid("片基采样来源的尺寸与选区记录不匹配。").localizedDescription
              self.bumpLocked()
              return
            }
            self.pendingMatrixCalibration = nil
            self.commitMatrixCalibrationLocked(result, name: "切换矩阵并对齐片基")
            self.bumpLocked()
          }
        } catch {
          if !(error is CancellationError) {
            self.lock.withLock {
              guard revision == self.sampleRevision else { return }
              self.pendingMatrixCalibration = nil
              self.errorMessage = error.localizedDescription
              self.bumpLocked()
            }
          }
        }
      }
    } catch { errorMessage = error.localizedDescription }
  }

  private func calibrationSourceLocked(_ roll: RollProject) throws -> URL {
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

  private func commitMatrixCalibrationLocked(_ calibration: FilmCalibration, name: String) {
    guard let old = project, var next = project, old.calibration != calibration else { return }
    next.calibration = calibration
    registerUndoLocked(old: old, name: name)
    project = next
    dirty = true
    renderLocked()
    refreshThumbnailsLocked()
    scheduleSaveLocked(immediate: true)
  }

  private func startCMOSCalibration(paths: [String]) {
    let urls = paths.map { URL(fileURLWithPath: $0) }
    let gen = UUID()
    lock.withLock {
      cmosCalibGeneration = gen
      cmosCalibTask?.cancel()
      cmosCalibBusy = true
      cmosCalibError = nil
      cmosCalibValues = nil
      cmosCalibIdentifications = []
      bumpLocked()
    }
    let task = Task.detached(priority: .userInitiated) { [weak self] in
      guard let self else { return }
      do {
        let result = try CMOSCalibration.make(sources: urls)
        try Task.checkCancellation()
        let ids = result.sourceIndices.enumerated().map { channel, index in
          "\(["R", "G", "B"][channel]) 光源：\(urls[index].lastPathComponent)"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
        let suggested = "CMOS \(formatter.string(from: Date()))"
        self.lock.withLock {
          guard self.cmosCalibGeneration == gen else { return }
          self.cmosCalibValues = result.coefficients.values
          self.cmosCalibIdentifications = ids
          self.cmosCalibSuggestedName = suggested
          self.cmosCalibBusy = false
          self.cmosCalibTask = nil
          self.bumpLocked()
        }
      } catch {
        if !(error is CancellationError) {
          self.lock.withLock {
            guard self.cmosCalibGeneration == gen else { return }
            self.cmosCalibBusy = false
            self.cmosCalibError = error.localizedDescription
            self.cmosCalibTask = nil
            self.bumpLocked()
          }
        }
      }
    }
    lock.withLock { cmosCalibTask = task }
  }

  // MARK: - Persistence & Thumbnails
  private func scheduleSaveLocked(immediate: Bool = false) {
    persistence.cancel()
    if immediate {
      _ = flushSaveLocked()
      return
    }
    persistence.schedule { [weak self] in
      guard let self else { return }
      self.lock.withLock {
        _ = self.flushSaveLocked()
        self.bumpLocked()
      }
    }
  }

  @discardableResult
  private func flushSaveLocked() -> Bool {
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

  private func restoreBackupLocked(data: Data) throws {
    guard let folder, let previous = project else { throw PrintroomError.invalid("请先打开对应胶卷") }
    let backup = try ProjectStore.decodeSnapshot(data)
    let urls = backup.frames.filter { $0.crop?.geometryVersion == 1 }
      .map { folder.appendingPathComponent($0.filename) }
      .filter { FileManager.default.fileExists(atPath: $0.path) }
    if prepareGeometryIfNeededLocked(urls, then: {
      do { try self.restoreBackupLocked(data: data) } catch { self.errorMessage = error.localizedDescription }
    }) { return }
    var next = try ProjectStore.open(folder: folder, preferredFile: nil)
    guard next.id == backup.id else { throw PrintroomError.invalid("设置副本属于另一卷底片") }
    for i in next.frames.indices {
      if let source = backup.frames.first(where: { $0.id == next.frames[i].id }) {
        next.frames[i].adjustments = source.adjustments
        next.frames[i].orientation = source.orientation
        next.frames[i].crop = source.crop
        if let crop = source.crop, crop.geometryVersion == 1, !next.frames[i].isMissing,
           let metadata = try? geometryMetadataLocked(folder.appendingPathComponent(next.frames[i].filename)) {
          next.frames[i].crop = try crop.sourceCoordinates(
            sourceWidth: metadata.width, sourceHeight: metadata.height, orientation: source.orientation)
        }
      }
    }
    next.exportSettings = backup.exportSettings
    next.name = backup.name
    next.sprocketWhitening = backup.sprocketWhitening
    next.calibration = backup.calibration
    next.calibrationNeedsReview = false
    try ProjectStore.save(next, folder: folder)
    cancelSamplingLocked()
    isCropping = false
    cropDraft = nil
    sampling = false
    previewBitmap = nil
    cropPreviewTransition = nil
    cropViewportToken += 1
    registerUndoLocked(old: previous, name: "恢复设置副本")
    project = next
    dirty = false
    saveFailure = false
    errorMessage = nil
    renderLocked()
    refreshThumbnailsLocked(changedFrom: previous, to: next)
  }

  private func relocateLocked(_ frameID: UUID, to url: URL) {
    guard let previous = project, let capturedFolder = folder else { return }
    cancelGeometryPreparationLocked()
    if SourceImageIO.isRAW(url) {
      let encoded = geometryProjectSnapshotLocked(previous)
      let token = UUID()
      geometryPreparationToken = token
      isPreparingGeometry = true
      geometryPreparationTask = Task.detached(priority: .userInitiated) { [weak self] in
        guard let self else { return }
        do {
          try Task.checkCancellation()
          let next = try ProjectStore.relocate(previous, frameID: frameID, to: url, folder: capturedFolder)
          try Task.checkCancellation()
          self.lock.withLock {
            if self.geometryPreparationToken == token {
              self.isPreparingGeometry = false
              self.geometryPreparationTask = nil
            }
            guard self.geometryPreparationToken == token,
                  let curFolder = self.folder, PlatformFS.sameDirectory(curFolder, capturedFolder),
                  self.project.flatMap({ self.geometryProjectSnapshotLocked($0) }) == encoded else { return }
            self.finishRelocationLocked(previous: previous, next: next, frameID: frameID)
            self.bumpLocked()
          }
        } catch {
          if !(error is CancellationError) {
            self.lock.withLock {
              if self.geometryPreparationToken == token {
                self.isPreparingGeometry = false
                self.geometryPreparationTask = nil
                if let curFolder = self.folder, PlatformFS.sameDirectory(curFolder, capturedFolder) {
                  self.errorMessage = error.localizedDescription
                }
                self.bumpLocked()
              }
            }
          }
        }
      }
    } else {
      do {
        let next = try ProjectStore.relocate(previous, frameID: frameID, to: url, folder: capturedFolder)
        finishRelocationLocked(previous: previous, next: next, frameID: frameID)
      } catch { errorMessage = error.localizedDescription }
    }
  }

  private func finishRelocationLocked(previous: RollProject, next: RollProject, frameID: UUID) {
    registerUndoLocked(old: previous, name: "重新定位照片")
    project = next
    dirty = true
    selection = SelectionState()
    selection.click(frameID, ordered: next.frames.filter { !$0.isMissing }.map(\.id))
    project?.lastActiveFrameID = frameID
    loadActiveLocked()
    refreshThumbnailsLocked()
    scheduleSaveLocked(immediate: true)
  }

  private func refreshThumbnailsLocked(changedFrom old: RollProject, to next: RollProject) {
    guard old.calibration == next.calibration,
          old.sprocketWhitening == next.sprocketWhitening else {
      refreshThumbnailsLocked()
      return
    }
    let previous = Dictionary(uniqueKeysWithValues: old.frames.map { ($0.id, $0) })
    refreshThumbnailsLocked(affectedIDs: Set(next.frames.filter { previous[$0.id] != $0 }.map(\.id)))
  }

  private func refreshThumbnailsLocked(affectedIDs: Set<UUID>? = nil) {
    guard let project, let folder, let assets else { return }
    cancelPreviewWarmupLocked()
    let available = Set(project.frames.filter { !$0.isMissing }.map(\.id))
    thumbnailBitmaps = thumbnailBitmaps.filter { available.contains($0.key) }
    thumbnailCoordinator.refresh(
      project: project, folder: folder, assets: assets,
      activeFrameID: selection.activeFrameID, affectedIDs: affectedIDs,
      publish: { [weak self] bitmap, key in
        guard let self else { return false }
        return self.lock.withLock {
          guard let curFolder = self.folder, PlatformFS.sameDirectory(curFolder, folder),
                let current = self.project, current.id == project.id,
                current.calibration == key.calibration,
                current.sprocketWhitening == key.sprocketWhitening,
                let frame = current.frames.first(where: { $0.id == key.frameID }),
                !frame.isMissing,
                frame.filename == project.frames.first(where: { $0.id == key.frameID })?.filename,
                frame.adjustments == key.adjustments, frame.orientation == key.orientation,
                frame.crop == key.crop else { return false }
          self.thumbnailBitmaps[key.frameID] = bitmap
          self.thumbnailRevisions[key.frameID] = (self.thumbnailRevisions[key.frameID] ?? 0) &+ 1
          self.bumpLocked()
          return true
        }
      },
      finished: { [weak self] in
        guard let self else { return }
        self.lock.withLock { self.schedulePreviewWarmupLocked() }
      })
  }

  // MARK: - Export
  private func setExportSettingsLocked(_ settings: ProjectExportSettings) {
    guard project != nil, exportSettingsLocked != settings else { return }
    project?.exportSettings = settings
    dirty = true
    scheduleSaveLocked(immediate: true)
  }

  private func startExportCommand(cmd: WinCommand, destinationPath: String) -> Bool {
    let setup: (request: ExportRequest, assets: WinAppAssets, generation: UUID)? = lock.withLock {
      guard !isExporting, let curProject = project, let assets else { return nil }
      var settings = curProject.exportSettings
      if let f = cmd.format, let fmt = ExportFormat(rawValue: f) { settings.format = fmt }
      if let p = cmd.profile, let prof = OutputColorProfile(rawValue: p) { settings.profile = prof }
      if let c = cmd.compression, let comp = TIFFCompression(rawValue: c) { settings.compression = comp }
      if let ac = cmd.applyCrop { settings.applyCrop = ac }
      if let ow = cmd.overwriteExisting { settings.overwriteExisting = ow }
      settings.destinationPath = destinationPath
      let trimmedPrefix = cmd.filenamePrefix?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if cmd.filenamePrefix != nil {
        settings.filenamePrefix = trimmedPrefix.isEmpty ? nil : trimmedPrefix
      }
      setExportSettingsLocked(settings)
      guard flushSaveLocked() else {
        exportFinished = true
        exportResultMessage = "导出失败：设置未保存"
        exportResultDetail = errorMessage
        errorMessage = nil
        bumpLocked()
        return nil
      }
      guard let latestProject = self.project else { return nil }
      let targets: Set<UUID>
      if cmd.allFrames == true {
        targets = Set(latestProject.frames.map(\.id))
      } else if cmd.boolValue == true { // currentOnly
        targets = activeFrameLocked.map { [$0.id] } ?? []
      } else {
        targets = selection.selectedFrameIDs
      }
      let dirURL = URL(fileURLWithPath: destinationPath, isDirectory: true)
      let explicitURL = cmd.explicitDestination.map { URL(fileURLWithPath: $0) }
      let prefixToUse = trimmedPrefix.isEmpty ? rollNameLocked : trimmedPrefix
      do {
        let request = try ExportRequest(
          project: latestProject, targetIDs: targets, destinationDirectory: dirURL,
          explicitDestination: explicitURL, filenamePrefix: prefixToUse)
        let gen = UUID()
        exportGeneration = gen
        isExporting = true
        exportProgress = 0
        exportDetail = "准备导出 \(targets.count) 张"
        exportFinished = false
        exportResultMessage = nil
        exportResultDetail = nil
        bumpLocked()
        return (request, assets, gen)
      } catch {
        exportFinished = true
        exportResultMessage = "导出失败"
        exportResultDetail = error.localizedDescription
        isExporting = false
        bumpLocked()
        return nil
      }
    }
    guard let setup else { return false }
    let task = Task.detached(priority: .userInitiated) { [weak self] in
      guard let self else { return }
      do {
        let summary = try await self.exportEngine.run(
          setup.request, lut: setup.assets.lut, p3Profile: setup.assets.profile,
          fujifilmLUT: setup.assets.fujifilmLUT) { progress in
          self.lock.withLock {
            guard self.exportGeneration == setup.generation, self.isExporting,
                  progress.fraction >= self.exportProgress else { return }
            self.exportProgress = progress.fraction
            self.exportDetail = "\(progress.processedCount)/\(progress.totalCount)"
            self.bumpLocked()
          }
        }
        self.lock.withLock {
          guard self.exportGeneration == setup.generation else { return }
          if summary.wasCancelled {
            self.exportDetail = "导出已取消 · 已完成 \(summary.completedCount) 张"
          } else if summary.failedCount > 0 {
            self.exportDetail = "导出失败 · 成功 \(summary.completedCount) 张，失败 \(summary.failedCount) 张"
          } else {
            self.exportDetail = "导出成功 · \(summary.completedCount) 张"
          }
          self.exportFinished = true
          self.exportResultMessage = self.exportDetail
          self.exportResultDetail = summary.results.compactMap(\.error).first
          self.isExporting = false
          self.exportTask = nil
          self.bumpLocked()
        }
      } catch {
        self.lock.withLock {
          guard self.exportGeneration == setup.generation else { return }
          self.exportFinished = true
          self.exportResultMessage = "导出失败"
          self.exportResultDetail = error.localizedDescription
          self.isExporting = false
          self.exportTask = nil
          self.bumpLocked()
        }
      }
    }
    lock.withLock { exportTask = task }
    return true
  }

  private func cancelExportLocked() {
    exportTask?.cancel()
    exportDetail = "正在取消…"
  }

  // MARK: - Cache & Updates
  private func refreshCacheSizeAsync() {
    let start = lock.withLock { () -> Bool in
      if cacheSizeBusy { return false }
      cacheSizeBusy = true
      return true
    }
    guard start else { return }
    Task.detached(priority: .utility) { [weak self] in
      guard let self else { return }
      do {
        let sz = try ManagedDiskCache.size()
        self.lock.withLock {
          self.cacheBytes = sz
          self.cacheError = nil
          self.cacheSizeBusy = false
          self.bumpLocked()
        }
      } catch {
        self.lock.withLock {
          self.cacheError = "无法统计缓存：\(error.localizedDescription)"
          self.cacheSizeBusy = false
          self.bumpLocked()
        }
      }
    }
  }

  private struct GitHubRelease: Decodable {
    let tag_name: String
    let draft: Bool
    let prerelease: Bool
  }

  private func checkForUpdatesIfNeeded() {
    let shouldRun = lock.withLock { () -> Bool in
      if updateChecked { return false }
      updateChecked = true
      return true
    }
    guard shouldRun else { return }
    Task.detached(priority: .utility) { [weak self] in
      guard let self,
            let url = URL(string: "https://api.github.com/repos/karasuyasabou/Printroom/releases/latest") else { return }
      var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
      req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
      req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
      req.setValue("Printroom", forHTTPHeaderField: "User-Agent")
      do {
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
        let rel = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard !rel.draft, !rel.prerelease else { return }
        let tagClean = rel.tag_name.hasPrefix("v") ? String(rel.tag_name.dropFirst()) : rel.tag_name
        let tagParts = tagClean.split(separator: ".").compactMap { Int($0) }
        let curParts = Self.appVersion.split(separator: ".").compactMap { Int($0) }
        guard tagParts.count == 3, curParts.count == 3,
              curParts.lexicographicallyPrecedes(tagParts) else { return }
        let verStr = "v" + tagParts.map(String.init).joined(separator: ".")
        self.lock.withLock {
          self.availableUpdateVersion = verStr
          self.bumpLocked()
        }
      } catch {
        // Ignore offline/rate-limited errors silently
      }
    }
  }

  // MARK: - Snapshot Builder (under `lock`)
  private var rollNameLocked: String { project?.name ?? folder?.lastPathComponent ?? "Printroom" }

  private func makeCropDTO(_ geom: CropGeometry?) -> WinCropDTO? {
    guard let g = geom, let c = g.displayCrop else { return nil }
    return WinCropDTO(
      aspect: c.aspect.rawValue,
      centerX: c.centerX,
      centerY: c.centerY,
      width: c.width,
      angleDegrees: c.angleDegrees,
      portrait: c.portrait,
      freeRatio: c.freeRatio,
      ratio: c.ratio,
      rectX: Double(g.rect.minX),
      rectY: Double(g.rect.minY),
      rectW: Double(g.rect.width),
      rectH: Double(g.rect.height))
  }

  private func makeSnapshotLocked() -> WinUIStateSnapshot {
    let adj = activeFrameLocked?.adjustments ?? .init()
    let cmosOpts = matrixOptionsLocked(.cmos).map {
      WinMatrixOptionDTO(
        id: $0.id, name: $0.name, isBuiltIn: $0.isBuiltIn,
        isSnapshot: isMatrixSnapshotLocked($0, kind: .cmos), values: $0.coefficients.values)
    }
    let denOpts = matrixOptionsLocked(.density).map {
      WinMatrixOptionDTO(
        id: $0.id, name: $0.name, isBuiltIn: $0.isBuiltIn,
        isSnapshot: isMatrixSnapshotLocked($0, kind: .density), values: $0.coefficients.values)
    }
    let histDTO = histogram.map { h in
      WinHistogramDTO(
        stage: h.stage.rawValue, sampleCount: h.sampleCount,
        binsR: h.channels[0].bins, binsG: h.channels[1].bins, binsB: h.channels[2].bins)
    }
    let frameDTOs = (project?.frames ?? []).map { f in
      WinFrameDTO(
        id: f.id.uuidString, filename: f.filename, isMissing: f.isMissing,
        needsReview: f.cropNeedsReview, thumbnailRevision: thumbnailRevisions[f.id] ?? 0)
    }
    let es = exportSettingsLocked
    let rawPrefix = Self.safeExportPrefix(rollNameLocked)
    let esDTO = WinExportSettingsDTO(
      format: es.format.rawValue, profile: es.profile.rawValue,
      compression: es.compression.rawValue, applyCrop: es.applyCrop,
      overwriteExisting: es.overwriteExisting, destinationPath: es.destinationPath,
      filenamePrefix: es.filenamePrefix, rollDefaultPrefix: rawPrefix)
    let recentDTOs = recentRolls.entries.map { e in
      var isDir: ObjCBool = false
      let avail = FileManager.default.fileExists(atPath: e.path, isDirectory: &isDir) && isDir.boolValue
      return WinRecentRollDTO(
        path: e.path, projectID: e.projectID.uuidString,
        openedAtUnix: e.openedAt.timeIntervalSince1970,
        name: e.name, displayName: e.displayName, isAvailable: avail)
    }
    let remDTO = recentRolls.removed.map { e in
      WinRecentRollDTO(
        path: e.path, projectID: e.projectID.uuidString,
        openedAtUnix: e.openedAt.timeIntervalSince1970,
        name: e.name, displayName: e.displayName, isAvailable: true)
    }
    let presentsCrop = cropPreviewTransition?.isCropping ?? isCropping
    let activeGeom = cropPreviewTransition?.geometry ?? cropDraftGeometryLocked

    return WinUIStateSnapshot(
      revision: stateRevision,
      isImporting: isImporting,
      importCompleted: importCompleted,
      importTotal: importTotal,
      importFailure: importFailure,
      hasProject: project != nil,
      projectID: project?.id.uuidString,
      rollName: rollNameLocked,
      folderPath: folder?.path,
      needsInitialRollNaming: needsInitialRollNaming,
      dirty: dirty,
      saveFailure: saveFailure,
      errorMessage: errorMessage,
      isLoading: isLoading,
      isRendering: isRendering,
      isPreviewPlaceholder: isPreviewPlaceholder,
      isPreparingGeometry: isPreparingGeometry,
      isAutoCropping: isAutoCropping,
      autoCropProgressText: autoCropProgressText,
      autoCropCompletedRun: autoCropCompletedRun,
      isAnalyzingRollTiming: isAnalyzingRollTiming,
      showMissingFilmBaseDialog: showMissingFilmBaseDialog,
      showRollTimingConfirmation: showRollTimingConfirmation,
      showRollTimingDialog: showRollTimingDialog,
      rollTimingProgress: rollTimingProgress,
      rollTimingError: rollTimingError,
      isExporting: isExporting,
      exportProgress: exportProgress,
      exportDetail: exportDetail,
      exportFinished: exportFinished,
      exportResultMessage: exportResultMessage,
      exportResultDetail: exportResultDetail,
      canUndo: !undoStack.isEmpty,
      canRedo: !redoStack.isEmpty,
      undoActionName: undoStack.last?.name,
      redoActionName: redoStack.last?.name,
      activeFrameID: selection.activeFrameID?.uuidString,
      selectedFrameIDs: selection.selectedFrameIDs.map(\.uuidString),
      activeFilename: activeFrameLocked?.filename,
      hasImage: hasImageLocked,
      hasFilmBase: hasFilmBaseLocked,
      canAdjustColors: canAdjustColorsLocked,
      canPickNeutral: canPickNeutralLocked,
      canApply: canApplyLocked,
      canSync: canSyncLocked,
      canChangeSelectedOrientations: project != nil && !selection.selectedFrameIDs.isEmpty && !isCropping && !isLoading,
      canStartAutoCrop: canStartAutoCropLocked,
      canStartRollTiming: canStartRollTimingLocked,
      canOpenRollTiming: canOpenRollTimingLocked,
      sampling: sampling,
      neutralPicking: neutralPicking,
      isNeutralSampling: isNeutralSampling,
      stage: stage.rawValue,
      histogramStage: histogramStage.rawValue,
      cropPreviewEnabled: cropPreviewEnabled,
      sprocketWhiteningEnabled: sprocketWhiteningLocked.enabled,
      sprocketWhiteningThreshold: sprocketWhiteningLocked.thresholdPercent,
      canAdjustSprocketWhitening: canAdjustSprocketWhiteningLocked,
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
      displayWidth: displayWidthLocked,
      displayHeight: displayHeightLocked,
      isCropping: isCropping,
      canEditCrop: canEditCropLocked,
      cropRatioLocked: cropRatioLocked,
      cropViewportToken: cropViewportToken,
      presentsCrop: presentsCrop,
      cropTransitionSizeWidth: cropPreviewTransition.map { Int($0.size.width) },
      cropTransitionSizeHeight: cropPreviewTransition.map { Int($0.size.height) },
      presentedCropDisplay: makeCropDTO(activeGeom),
      cropReviewAvailable: cropReviewAvailableLocked,
      reviewOnlyPendingCrops: reviewOnlyPendingCrops,
      pendingAutoCropFrameIDs: pendingAutoCropFrameIDsLocked.map(\.uuidString),
      previewBitmapRevision: previewBitmapRevision,
      previewWidth: previewBitmap?.width ?? 0,
      previewHeight: previewBitmap?.height ?? 0,
      histogram: histDTO,
      histogramProbe: histogramProbe.map { [$0.x, $0.y, $0.z] },
      cmosMatrixID: (project?.calibration.cmosMatrix ?? .identity).id,
      cmosOptions: cmosOpts,
      densityMatrixID: (project?.calibration.matrix ?? .identity).id,
      densityOptions: denOpts,
      matrixLibraryError: matrixLibraryError,
      cmosCalibBusy: cmosCalibBusy,
      cmosCalibValues: cmosCalibValues,
      cmosCalibIdentifications: cmosCalibIdentifications,
      cmosCalibError: cmosCalibError,
      cmosCalibSuggestedName: cmosCalibSuggestedName,
      timingMode: timingMode.rawValue,
      simpleExposure: SimpleTimingAxis.exposure.value(in: adj.timing),
      simpleTemperature: SimpleTimingAxis.temperature.value(in: adj.timing),
      simpleTint: SimpleTimingAxis.tint.value(in: adj.timing),
      timingMaster: adj.timing.master,
      timingRed: adj.timing.red,
      timingGreen: adj.timing.green,
      timingBlue: adj.timing.blue,
      contrastMaster: adj.contrast.master,
      contrastRed: adj.contrast.red,
      contrastGreen: adj.contrast.green,
      contrastBlue: adj.contrast.blue,
      cineonLogLUT: adj.cineonLogLUT.rawValue,
      copiedSourceName: snapshot?.sourceName,
      frames: frameDTOs,
      exportSettings: esDTO,
      recentRolls: recentDTOs,
      removedRecentRoll: remDTO,
      cacheLimitGB: cachePolicy.limitGB,
      cacheRetentionDays: cachePolicy.retentionDays,
      cacheBytes: cacheBytes,
      cacheError: cacheError,
      availableUpdateVersion: availableUpdateVersion)
  }

  private static func safeExportPrefix(_ name: String) -> String {
    let cleaned = String(name.map { ch in
      ch == "/" || ch == ":" || ch == "\\" || ch.isNewline || ch == "\0" ? "_" : ch
    }).trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned.isEmpty ? "Printroom" : cleaned
  }
}
