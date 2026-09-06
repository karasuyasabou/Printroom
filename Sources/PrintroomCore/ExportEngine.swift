import Darwin
import Foundation

public struct ExportFrameSnapshot: Sendable {
  public let id: UUID
  public let sourceName: String
  public let sourceURL: URL
  public let adjustments: FrameAdjustments
  public let orientation: FrameOrientation
  public let sourceSize: Int64
  public let sourceModified: Double

  public init(frame: FrameRecord, folder: URL) {
    id = frame.id
    sourceName = frame.filename
    sourceURL = folder.appendingPathComponent(frame.filename)
    adjustments = frame.adjustments
    orientation = frame.orientation
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
  public let destinationDirectory: URL
  public let explicitDestination: URL?
  public let protectedSourceURLs: [URL]

  public init(
    project: RollProject, targetIDs: Set<UUID>, destinationDirectory: URL,
    explicitDestination: URL? = nil
  ) throws {
    guard let folder = project.sourceFolderURL, !targetIDs.isEmpty,
      destinationDirectory.isFileURL,
      project.frames.filter({ targetIDs.contains($0.id) }).count == targetIDs.count,
      explicitDestination == nil || (targetIDs.count == 1 && explicitDestination!.isFileURL)
    else { throw PrintroomError.invalid("导出目标或照片集合无效。") }
    id = UUID()
    frames = project.frames.filter { targetIDs.contains($0.id) }.map {
      ExportFrameSnapshot(frame: $0, folder: folder)
    }
    calibration = project.calibration
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
    settings: ProjectExportSettings = .init()
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
    id = UUID()
    frames = [ExportFrameSnapshot(frame: frame, folder: source.deletingLastPathComponent())]
    self.calibration = calibration
    self.settings = settings
    destinationDirectory = destination.deletingLastPathComponent()
    explicitDestination = destination
    protectedSourceURLs = [source]
  }
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

/// Independent from the image/preview actor. Only one original UInt16 image and
/// bounded Float32 row blocks are resident; the roll never becomes full-size RAM.
/// Cancel the caller's Task. Checks occur between strips, blocks and publication.
public actor ExportEngine {
  private var gpu: MetalPipeline?
  private let useCPUReference: Bool

  public init(useCPUReference: Bool = false) { self.useCPUReference = useCPUReference }

  public func run(
    _ request: ExportRequest, lut: CubeLUT, p3Profile: Data,
    progress: @Sendable @escaping (ExportProgress) -> Void = { _ in }
  ) throws -> ExportSummary {
    let start = Date()
    guard request.settings.bitsPerSample == 16, request.settings.embedsICC,
      !request.settings.dithering,
      request.settings.profileSHA256 == request.settings.profile.profileSHA256
    else { throw PrintroomError.invalid("导出设置不符合当前 16-bit RGB TIFF 契约。") }
    let converter = try OutputColorConverter(p3Profile: p3Profile, output: request.settings.profile)
    if !useCPUReference && gpu == nil { gpu = try MetalPipeline() }
    var results: [ExportFrameResult] = []
    var cancelled = false
    var completedCount = 0
    var failedCount = 0
    for frame in request.frames {
      if Task.isCancelled {
        cancelled = true
        results.append(
          ExportFrameResult(
            id: frame.id, sourceName: frame.sourceName,
            destination: nil, status: .notStarted, error: "取消后未开始"))
        continue
      }
      let processedCount = results.count
      let finished = completedCount
      let failed = failedCount
      let update: @Sendable (Double) -> Void = { fraction in
        progress(
          ExportProgress(
            totalCount: request.frames.count, processedCount: processedCount,
            completedCount: finished, failedCount: failed, currentName: frame.sourceName,
            frameProgress: fraction))
      }
      update(0)
      do {
        let destination = try export(
          frame, request: request, converter: converter,
          lut: lut, progress: update)
        completedCount += 1
        results.append(
          ExportFrameResult(
            id: frame.id, sourceName: frame.sourceName,
            destination: destination, status: .completed, error: nil))
      } catch is CancellationError {
        cancelled = true
        results.append(
          ExportFrameResult(
            id: frame.id, sourceName: frame.sourceName,
            destination: nil, status: .cancelled, error: "已取消；未完成临时文件已清理"))
      } catch {
        failedCount += 1
        results.append(
          ExportFrameResult(
            id: frame.id, sourceName: frame.sourceName,
            destination: nil, status: .failed, error: error.localizedDescription))
      }
      progress(
        ExportProgress(
          totalCount: request.frames.count, processedCount: results.count,
          completedCount: completedCount, failedCount: failedCount, currentName: nil,
          frameProgress: 0))
    }
    return ExportSummary(
      results: results, wasCancelled: cancelled,
      elapsedSeconds: Date().timeIntervalSince(start))
  }

  private func export(
    _ frame: ExportFrameSnapshot, request: ExportRequest, converter: OutputColorConverter,
    lut: CubeLUT, progress: @Sendable (Double) -> Void
  ) throws -> URL {
    try Task.checkCancellation()
    try validateSource(frame)
    if let explicit = request.explicitDestination {
      try protect(explicit, request: request)
    }
    let image = try TIFFCodec.read(url: frame.sourceURL)
    try validateSource(frame)
    let size = frame.orientation.outputSize(sourceWidth: image.width, sourceHeight: image.height)
    progress(0.08)
    let initial =
      request.explicitDestination
      ?? request.destinationDirectory.appendingPathComponent(
        (frame.sourceName as NSString).deletingPathExtension + "-Printroom.tiff")
    let basename = initial.deletingPathExtension().lastPathComponent
    let ext = initial.pathExtension.isEmpty ? "tiff" : initial.pathExtension
    // Usually the first candidate wins. RENAME_EXCL also handles a competing
    // writer after this check; a raced name advances without replacing anything.
    for suffix in 0..<100_000 {
      try Task.checkCancellation()
      let destination =
        suffix == 0
        ? initial
        : initial.deletingLastPathComponent()
          .appendingPathComponent(basename + "-\(suffix)." + ext)
      if isProtected(destination, request: request) || occupied(destination) { continue }
      try protect(destination, request: request)
      do {
        try TIFFCodec.write(
          url: destination, width: size.width, height: size.height,
          profile: converter.outputProfile, compression: request.settings.compression
        ) { rows in
          try Task.checkCancellation()
          var pixels = [SIMD4<Float>]()
          pixels.reserveCapacity(rows.count * size.width)
          for y in rows {
            for x in 0..<size.width {
              let source = frame.orientation.inversePixel(
                x: x, y: y,
                sourceWidth: image.width, sourceHeight: image.height)
              pixels.append(SIMD4(image.pixel(x: source.x, y: source.y), 1))
            }
          }
          let input = PixelBuffer(width: size.width, height: rows.count, pixels: pixels)
          let final: PixelBuffer
          if let gpu {
            final = try gpu.render(
              input, calibration: request.calibration,
              adjustments: frame.adjustments, lut: lut)
          } else {
            final = try Pipeline.render(
              input, calibration: request.calibration,
              adjustments: frame.adjustments, lut: lut)
          }
          let samples = try converter.quantized(final)
          try Task.checkCancellation()
          progress(0.08 + 0.90 * Double(rows.upperBound) / Double(size.height))
          return samples
        }
        return destination
      } catch is TIFFWriteError {
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
      throw PrintroomError.invalid("导出不能覆盖卷内任何原始 TIFF：\(destination.lastPathComponent)")
    }
  }

  private func occupied(_ url: URL) -> Bool {
    var info = stat()
    return url.withUnsafeFileSystemRepresentation { lstat($0!, &info) == 0 }
  }
}
