import Darwin
import Foundation

public struct ExportFrameSnapshot: Sendable {
  public let id: UUID
  public let sourceName: String
  public let rollNumber: Int
  public let sourceURL: URL
  public let adjustments: FrameAdjustments
  public let orientation: FrameOrientation
  public let crop: FrameCrop?
  public let sourceSize: Int64
  public let sourceModified: Double
  public let rawProcessing: RAWProcessingIdentity?

  public init(frame: FrameRecord, folder: URL, rollNumber: Int = 1) throws {
    self.rollNumber = rollNumber
    id = frame.id
    sourceName = frame.filename
    sourceURL = folder.appendingPathComponent(frame.filename)
    rawProcessing = try SourceImageIO.processingIdentity(url: sourceURL)
    if let previous = frame.rawProcessing, previous != rawProcessing {
      throw PrintroomError.invalid("RAW 处理版本已改变，请重新载入照片后导出。")
    }
    adjustments = frame.adjustments
    orientation = frame.orientation
    crop = frame.crop
    sourceSize = frame.sourceSize
    sourceModified = frame.sourceModified
  }
}

/// All values, including the full roll's protected source paths, are captured at
/// creation. Subsequent UI edits never reach a running export.
public struct ExportRequest: Sendable {
  public let id: UUID
  public let frames: [ExportFrameSnapshot]
  public let calibration: FilmCalibration
  public let settings: ProjectExportSettings
  public let sprocketWhitening: SprocketWhiteningSettings
  public let destinationDirectory: URL
  public let filenamePrefix: String?
  public let explicitDestination: URL?
  public let protectedSourceURLs: [URL]

  public init(
    project: RollProject, targetIDs: Set<UUID>, destinationDirectory: URL,
    explicitDestination: URL? = nil, filenamePrefix: String? = nil
  ) throws {
    guard let folder = project.sourceFolderURL, !targetIDs.isEmpty,
      destinationDirectory.isFileURL,
      project.frames.filter({ targetIDs.contains($0.id) }).count == targetIDs.count,
      explicitDestination == nil || (targetIDs.count == 1 && explicitDestination!.isFileURL)
    else { throw PrintroomError.invalid("导出目标或照片集合无效。") }
    id = UUID()
    if let filenamePrefix {
      guard !filenamePrefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        !filenamePrefix.contains(where: { $0 == "/" || $0 == ":" || $0.isNewline || $0.asciiValue == 0 })
      else { throw PrintroomError.invalid("文件名前缀不能为空，也不能包含 /、: 或换行。") }
    }
    self.filenamePrefix = filenamePrefix
    frames = try project.frames.enumerated().filter { targetIDs.contains($0.element.id) }.map {
      try ExportFrameSnapshot(frame: $0.element, folder: folder, rollNumber: $0.offset + 1)
    }
    calibration = project.calibration
    sprocketWhitening = project.sprocketWhitening
    try sprocketWhitening.validate()
    settings = project.exportSettings
    self.destinationDirectory = destinationDirectory
    self.explicitDestination = explicitDestination
    protectedSourceURLs = project.frames.map { folder.appendingPathComponent($0.filename) }
  }

  /// A standalone caller still uses the exact same queue, renderer, converter and
  /// writer. The app's roll UI uses the project initializer to protect every frame.
  public init(
    source: URL, destination: URL, calibration: FilmCalibration,
    adjustments: FrameAdjustments, orientation: FrameOrientation = .identity,
    settings: ProjectExportSettings = .init(), crop: FrameCrop? = nil,
    sprocketWhitening: SprocketWhiteningSettings = .init()
  ) throws {
    let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
    guard source.isFileURL, destination.isFileURL,
      let size = (attributes[.size] as? NSNumber)?.int64Value,
      let date = attributes[.modificationDate] as? Date
    else { throw PrintroomError.invalid("无法固定单张导出的源文件身份。") }
    var frame = FrameRecord(
      filename: source.lastPathComponent, adjustments: adjustments,
      sourceSize: size, sourceModified: date.timeIntervalSince1970)
    frame.orientation = orientation
    frame.crop = crop
    id = UUID()
    frames = [try ExportFrameSnapshot(frame: frame, folder: source.deletingLastPathComponent())]
    self.calibration = calibration
    self.settings = settings
    try sprocketWhitening.validate()
    self.sprocketWhitening = sprocketWhitening
    destinationDirectory = destination.deletingLastPathComponent()
    explicitDestination = destination
    filenamePrefix = nil
    protectedSourceURLs = [source]
  }
}

public enum ExportConflictDecision: Sendable {
  case overwrite, rename, cancel
}

public enum ExportFrameStatus: String, Sendable {
  case completed, failed, cancelled, notStarted
}

public struct ExportFrameResult: Identifiable, Sendable {
  public let id: UUID
  public let sourceName: String
  public let destination: URL?
  public let status: ExportFrameStatus
  public let error: String?
}

public struct ExportProgress: Sendable {
  public let totalCount: Int
  public let processedCount: Int
  public let completedCount: Int
  public let failedCount: Int
  public let currentName: String?
  /// Sum of fractional work across the active frames (up to four).
  public let frameProgress: Double
  public var fraction: Double {
    totalCount == 0 ? 0 : min(1, (Double(processedCount) + frameProgress) / Double(totalCount))
  }
}

public struct ExportSummary: Sendable {
  public let results: [ExportFrameResult]
  public let wasCancelled: Bool
  public let elapsedSeconds: Double
  public var completedCount: Int { results.filter { $0.status == .completed }.count }
  public var failedCount: Int { results.filter { $0.status == .failed }.count }
  public var cancelledCount: Int {
    results.filter { $0.status == .cancelled || $0.status == .notStarted }.count
  }
}

/// A bounded pool, independent from the preview lane. Each worker owns its GPU
/// buffers and at most one original image. Results retain the request's order.
public actor ExportEngine {
  private let workers: [ExportWorker]
  private var running = false

  public init(useCPUReference: Bool = false, maximumConcurrentExports: Int = 4) {
    workers = (0..<max(1, min(4, maximumConcurrentExports))).map { _ in
      ExportWorker(useCPUReference: useCPUReference)
    }
  }

  /// Noninteractive callers retain their explicit no-replacement export behavior.
  public func run(
    _ request: ExportRequest, lut: CubeLUT, p3Profile: Data, fujifilmLUT: CubeLUT? = nil,
    progress: @Sendable @escaping (ExportProgress) -> Void = { _ in }
  ) async throws -> ExportSummary {
    try await run(request, lut: lut, p3Profile: p3Profile, fujifilmLUT: fujifilmLUT,
      resolveConflict: { _ in .rename }, progress: progress)
  }

  public func run(
    _ request: ExportRequest, lut: CubeLUT, p3Profile: Data, fujifilmLUT: CubeLUT? = nil,
    resolveConflict: @Sendable @escaping (URL) async throws -> ExportConflictDecision,
    progress: @Sendable @escaping (ExportProgress) -> Void = { _ in }
  ) async throws -> ExportSummary {
    guard !running else { throw PrintroomError.invalid("已有导出任务正在运行。") }
    running = true
    defer { running = false }
    guard [8, 16].contains(request.settings.bitsPerSample), request.settings.embedsICC,
      !request.settings.dithering,
      request.settings.profileSHA256 == request.settings.profile.profileSHA256
    else { throw PrintroomError.invalid("导出设置不符合当前 RGB TIFF/JPG 契约。") }
    let start = Date()
    let state = ExportProgressState(request: request, callback: progress)
    var results = [ExportFrameResult?](repeating: nil, count: request.frames.count)
    var cancelled = Task.isCancelled
    try await withThrowingTaskGroup(of: (Int, Int, ExportFrameResult).self) { group in
      var next = 0
      func enqueue(_ index: Int, lane: Int) {
        let worker = workers[lane]
        let frame = request.frames[index]
        group.addTask {
          let result = try await worker.run(frame, request: request, lut: lut,
            p3Profile: p3Profile, fujifilmLUT: fujifilmLUT, resolveConflict: resolveConflict) { fraction in
              state.update(index, fraction: fraction, name: frame.sourceName)
            }
          return (index, lane, result)
        }
      }
      if !cancelled {
        for lane in 0..<min(workers.count, request.frames.count) {
          enqueue(next, lane: lane)
          next += 1
        }
      }
      while let (index, lane, result) = try await group.next() {
        results[index] = result
        state.finish(index, result: result)
        if result.status == .cancelled || result.status == .notStarted || Task.isCancelled {
          cancelled = true
          group.cancelAll()
        }
        if !cancelled, next < request.frames.count {
          enqueue(next, lane: lane)
          next += 1
        }
      }
    }
    for index in results.indices where results[index] == nil {
      let frame = request.frames[index]
      let result = ExportFrameResult(id: frame.id, sourceName: frame.sourceName,
        destination: nil, status: .notStarted, error: "取消后未开始")
      results[index] = result
      state.finish(index, result: result)
    }
    return ExportSummary(results: results.compactMap { $0 },
      wasCancelled: cancelled || Task.isCancelled, elapsedSeconds: Date().timeIntervalSince(start))
  }
}

/// Worker callbacks are synchronous and can arrive concurrently. Serialize both
/// aggregation and delivery; keep progress monotonic across publication retries.
private final class ExportProgressState: @unchecked Sendable {
  private let lock = NSLock()
  private var fractions: [Double]
  private var finished: [Bool]
  private var processed = 0, completed = 0, failed = 0
  private let callback: @Sendable (ExportProgress) -> Void

  init(request: ExportRequest, callback: @Sendable @escaping (ExportProgress) -> Void) {
    fractions = Array(repeating: 0, count: request.frames.count)
    finished = Array(repeating: false, count: request.frames.count)
    self.callback = callback
  }

  func update(_ index: Int, fraction: Double, name: String?) {
    lock.lock()
    defer { lock.unlock() }
    guard !finished[index] else { return }
    fractions[index] = max(fractions[index], min(1, max(0, fraction)))
    publish(name: name)
  }

  func finish(_ index: Int, result: ExportFrameResult) {
    lock.lock()
    defer { lock.unlock() }
    finished[index] = true
    fractions[index] = 0
    processed += 1
    if result.status == .completed { completed += 1 }
    if result.status == .failed { failed += 1 }
    publish(name: nil)
  }

  private func publish(name: String?) {
    callback(ExportProgress(totalCount: fractions.count, processedCount: processed,
      completedCount: completed, failedCount: failed, currentName: name,
      frameProgress: fractions.reduce(0, +)))
  }
}

/// Independent from the image/preview actor. Only one original UInt16 image and
/// bounded Float32 row blocks are resident; the roll never becomes full-size RAM.
/// Cancel the caller's Task. Checks occur between strips, blocks and publication.
private actor ExportWorker {
  private var gpu: MetalPipeline?
  private let useCPUReference: Bool

  public init(useCPUReference: Bool = false) { self.useCPUReference = useCPUReference }

  func run(
    _ frame: ExportFrameSnapshot, request: ExportRequest, lut: CubeLUT,
    p3Profile: Data, fujifilmLUT: CubeLUT?,
    resolveConflict: @Sendable (URL) async throws -> ExportConflictDecision,
    progress: @Sendable @escaping (Double) -> Void
  ) async throws -> ExportFrameResult {
    if Task.isCancelled {
      return ExportFrameResult(id: frame.id, sourceName: frame.sourceName,
        destination: nil, status: .notStarted, error: "取消后未开始")
    }
    let converter = try OutputColorConverter(p3Profile: p3Profile, output: request.settings.profile)
    if !useCPUReference && gpu == nil { gpu = try MetalPipeline() }
    progress(0)
    do {
      let selectedLUT: CubeLUT
      if frame.adjustments.cineonLogLUT == .fujifilm3513DI {
        guard let fujifilmLUT else { throw PrintroomError.invalid("导出缺少 Fujifilm 3513DI LUT") }
        selectedLUT = fujifilmLUT
      } else { selectedLUT = lut }
      let destination = try await export(frame, request: request, converter: converter,
        lut: selectedLUT, resolveConflict: resolveConflict, progress: progress)
      return ExportFrameResult(id: frame.id, sourceName: frame.sourceName,
        destination: destination, status: .completed, error: nil)
    } catch is CancellationError {
      return ExportFrameResult(id: frame.id, sourceName: frame.sourceName,
        destination: nil, status: .cancelled, error: "已取消；未完成临时文件已清理")
    } catch {
      return ExportFrameResult(id: frame.id, sourceName: frame.sourceName,
        destination: nil, status: .failed, error: error.localizedDescription)
    }
  }

  private func export(
    _ frame: ExportFrameSnapshot, request: ExportRequest, converter: OutputColorConverter,
    lut: CubeLUT, resolveConflict: @Sendable (URL) async throws -> ExportConflictDecision,
    progress: @Sendable @escaping (Double) -> Void
  ) async throws -> URL {
    try Task.checkCancellation()
    try validateSource(frame)
    if let explicit = request.explicitDestination {
      try protect(explicit, request: request)
    }
    let image = try SourceImageIO.read(url: frame.sourceURL, expectedIdentity: frame.rawProcessing)
    try validateSource(frame)
    let geometry = try CropGeometry(crop: request.settings.applyCrop ? frame.crop : nil, sourceWidth: image.width,
                                    sourceHeight: image.height, orientation: frame.orientation)
    let size = (width: geometry.outputWidth, height: geometry.outputHeight)
    progress(0.08)
    let fileExtension = request.settings.format.fileExtension
    let initial =
      request.explicitDestination
      ?? request.destinationDirectory.appendingPathComponent(
        request.filenamePrefix.map { $0 + String(format: "-%02d", frame.rollNumber) + "." + fileExtension }
          ?? (frame.sourceName as NSString).deletingPathExtension + "-Printroom." + fileExtension)
    let basename = initial.deletingPathExtension().lastPathComponent
    let ext = initial.pathExtension.isEmpty ? fileExtension : initial.pathExtension
    // Once the user declines replacement, reserve a free suffixed name atomically.
    var allowRename = false
    var suffix = 0
    while suffix < 100_000 {
      try Task.checkCancellation()
      let destination = suffix == 0 ? initial : initial.deletingLastPathComponent()
        .appendingPathComponent(basename + "-\(suffix)." + ext)
      try protect(destination, request: request)
      var overwrite = false
      if occupied(destination) {
        if allowRename { suffix += 1; continue }
        switch try await resolveConflict(destination) {
        case .overwrite: overwrite = true
        case .rename: allowRename = true; suffix += 1; continue
        case .cancel: throw CancellationError()
        }
      }
      try Task.checkCancellation()
      // A private directory keeps the old destination intact until encoding succeeds.
      let staging = destination.deletingLastPathComponent()
        .appendingPathComponent(".printroom-replace-\(UUID()).tmp", isDirectory: true)
      if overwrite { try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false) }
      defer { if overwrite { try? FileManager.default.removeItem(at: staging) } }
      let writeURL = overwrite ? staging.appendingPathComponent("image." + ext) : destination
      do {
        let renderRows: (Range<Int>) throws -> PixelBuffer = { rows in
          try Task.checkCancellation()
          let input = try geometry.renderRows(image, rows: rows)
          let whitening: SprocketWhiteningContext?
          if !request.settings.applyCrop, request.sprocketWhitening.enabled,
            request.calibration.isCalibrated, let crop = frame.crop {
            whitening = try SprocketWhiteningContext(settings: request.sprocketWhitening,
              protectedCrop: crop, sourceWidth: image.width, sourceHeight: image.height,
              orientation: frame.orientation, renderWidth: size.width, renderHeight: size.height,
              rowOffset: rows.lowerBound)
          } else { whitening = nil }
          let final: PixelBuffer
          if let gpu = self.gpu {
            final = try gpu.render(
              input, calibration: request.calibration,
              adjustments: frame.adjustments, lut: lut, stage: .final, sprocketWhitening: whitening)
          } else {
            final = try Pipeline.render(
              input, calibration: request.calibration,
              adjustments: frame.adjustments, lut: lut, stage: .final, sprocketWhitening: whitening)
          }
          try Task.checkCancellation()
          progress(0.08 + 0.90 * Double(rows.upperBound) / Double(size.height))
          var converted = try converter.convert(final)
          if let whitening {
            // Preserve preview-equivalent edge colors through ICC; opaque holes
            // become the exact destination white, including fixed-point ICC rounding.
            converted = try whitening.apply(raw: input, to: converted,
              calibration: request.calibration, onlyOpaque: true)
          }
          return converted
        }
        if request.settings.format == .jpeg {
          try JPEGCodec.write(url: writeURL, width: size.width, height: size.height,
            profile: converter.outputProfile) { rows in
              try OutputColorConverter.quantize8(renderRows(rows))
            }
        } else {
          try TIFFCodec.write(url: writeURL, width: size.width, height: size.height,
            profile: converter.outputProfile, compression: request.settings.compression) { rows in
              try OutputColorConverter.quantize16(renderRows(rows))
            }
        }
        if overwrite {
          try Task.checkCancellation()
          try protect(destination, request: request)
          let result = writeURL.withUnsafeFileSystemRepresentation { source in
            destination.withUnsafeFileSystemRepresentation { target in rename(source!, target!) }
          }
          guard result == 0 else {
            throw PrintroomError.invalid("无法覆盖导出文件：\(String(cString: strerror(errno)))")
          }
        }
        return destination
      } catch is TIFFWriteError {
        // A file appeared during encoding: ask before replacing or renaming it.
        continue
      }
    }
    throw PrintroomError.invalid("无法分配未占用的导出文件名。")
  }

  private func validateSource(_ frame: ExportFrameSnapshot) throws {
    let resolved = frame.sourceURL.standardizedFileURL.resolvingSymlinksInPath()
    guard resolved.deletingLastPathComponent()
      == frame.sourceURL.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
    else { throw PrintroomError.invalid("原片链接指向卷外，无法使用该任务快照：\(frame.sourceName)") }
    let attributes = try FileManager.default.attributesOfItem(atPath: resolved.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular,
      let size = (attributes[.size] as? NSNumber)?.int64Value,
      let modified = attributes[.modificationDate] as? Date,
      size == frame.sourceSize, modified.timeIntervalSince1970 == frame.sourceModified
    else { throw PrintroomError.invalid("原片自任务快照后发生变化，请重新打开后导出：\(frame.sourceName)") }
  }

  private func canonical(_ url: URL) -> String {
    url.standardizedFileURL.resolvingSymlinksInPath().path.precomposedStringWithCanonicalMapping
      .lowercased()
  }

  private func isProtected(_ destination: URL, request: ExportRequest) -> Bool {
    let path = canonical(destination)
    return request.protectedSourceURLs.contains { canonical($0) == path }
  }

  private func protect(_ destination: URL, request: ExportRequest) throws {
    guard !isProtected(destination, request: request) else {
      throw PrintroomError.invalid("导出不能覆盖卷内任何原始图像：\(destination.lastPathComponent)")
    }
  }

  private func occupied(_ url: URL) -> Bool {
    var info = stat()
    return url.withUnsafeFileSystemRepresentation { lstat($0!, &info) == 0 }
  }
}
