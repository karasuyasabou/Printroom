import CWinPlatform
import Foundation
import PrintroomCore

// MARK: - TimingMode
public enum TimingMode: String, CaseIterable, Sendable {
  case simple, rgb
  public static let preferenceKey = "timingMode"
}

extension SimpleTimingAxis {
  public var title: String {
    switch self {
    case .exposure: return "曝光"
    case .temperature: return "色温"
    case .tint: return "色调"
    }
  }
  public var help: String {
    switch self {
    case .exposure: return "曝光 · 暗 ↔ 亮 · W / S"
    case .temperature: return "色温 · 冷 ↔ 暖 · Q / E"
    case .tint: return "色调 · 绿 ↔ 洋红 · A / D"
    }
  }
}

// MARK: - SourceStamp
public struct SourceStamp: Equatable, Sendable {
  public let url: URL
  public let size: Int64
  public let modified: Date?
  public let inode: UInt64
  public let rawProcessing: RAWProcessingIdentity?

  public init(url: URL) throws {
    let st = try PlatformFS.lstat(url)
    let dates = try PlatformFS.getFileDates(url)
    rawProcessing = try SourceImageIO.processingIdentity(url: url)
    self.url = url.standardizedFileURL
    size = st?.size ?? -1
    modified = dates.modification
    inode = rawProcessing == nil ? (st?.fileID ?? 0) : 0
  }
}

// MARK: - HistogramDisplayScale & HistogramProbe
public enum HistogramDisplayScale {
  public static func upperBound(channelBins: [[UInt64]], sampleCount: Int) -> Double {
    let occupied = channelBins.flatMap { $0 }.filter { $0 > 0 }.sorted()
    guard let peak = occupied.last else { return 1 }
    let rank = max(0, Int(ceil(Double(occupied.count) * 0.9)) - 1)
    let typicalPeak = Double(occupied[rank]) * 4
    let floor = max(1, Double(sampleCount) * 0.002)
    return min(Double(peak), max(floor, typicalPeak))
  }

  public static func heightFraction(count: UInt64, upperBound: Double) -> Double {
    min(1, Double(count) / max(1, upperBound))
  }
}

public enum HistogramProbe {
  public static func median(
    _ samples: PixelBuffer,
    calibration: FilmCalibration,
    adjustments: FrameAdjustments,
    lut: CubeLUT,
    stage: PipelineStage
  ) throws -> SIMD3<Float> {
    let output = try Pipeline.render(
      samples, calibration: calibration, adjustments: adjustments, lut: lut, stage: stage)
    var result = SIMD3<Float>(repeating: 0)
    for channel in 0..<3 {
      let values = output.pixels.map { $0[channel] }.sorted()
      let middle = values.count / 2
      result[channel] = values.count.isMultiple(of: 2)
        ? (values[middle - 1] + values[middle]) / 2 : values[middle]
    }
    return result
  }
}

// MARK: - BatchEditTransaction
public enum BatchEditTransaction {
  public struct SyncOptions: Sendable {
    public let timing: Bool
    public let contrast: Bool
    public let lut: Bool
    public let crop: Bool
  }

  public static func synchronize(
    project: RollProject,
    source: FrameRecord,
    targets: Set<UUID>,
    folder: URL,
    options: SyncOptions,
    metadata: (URL) throws -> TIFFMetadata
  ) throws -> RollProject {
    guard targets.isSubset(of: Set(project.frames.filter { !$0.isMissing }.map(\.id))),
      !source.isMissing else { throw PrintroomError.invalid("同步包含不可用照片") }
    var crop: FrameCrop?
    if options.crop, let savedCrop = source.crop {
      let dimensions = try metadata(folder.appendingPathComponent(source.filename))
      crop = try savedCrop.sourceCoordinates(
        sourceWidth: dimensions.width, sourceHeight: dimensions.height, orientation: source.orientation)
    }
    var next = project
    if options.timing || options.contrast || options.lut {
      next = try ParameterSnapshot(frame: source).applying(
        to: project, targets: targets,
        timing: options.timing, contrast: options.contrast, lut: options.lut)
    }
    for index in next.frames.indices where targets.contains(next.frames[index].id) {
      let url = folder.appendingPathComponent(next.frames[index].filename)
      try requireSource(url)
      if options.crop {
        let dimensions = try metadata(url)
        try next.frames[index].applyManualCrop(
          crop, sourceWidth: dimensions.width, sourceHeight: dimensions.height)
      }
    }
    return next
  }

  public static func applying(
    _ snapshot: ParameterSnapshot,
    to project: RollProject,
    targets: Set<UUID>,
    folder: URL
  ) throws -> RollProject {
    for frame in project.frames where targets.contains(frame.id) {
      try requireSource(folder.appendingPathComponent(frame.filename))
    }
    return try snapshot.applying(to: project, targets: targets)
  }

  private static func requireSource(_ url: URL) throws {
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw PrintroomError.invalid("目标文件已丢失：\(url.lastPathComponent)")
    }
  }
}

// MARK: - SourcePrewarmer
public enum WinSourcePrewarmer {
  public static let concurrency = 4
  public struct Failure: Sendable {
    public let url: URL
    public let message: String
  }

  @discardableResult
  public static func prepare(
    _ urls: [URL],
    progress: @escaping @Sendable (Int) async -> Void = { _ in },
    load: @escaping @Sendable (URL) throws -> Void = { _ = try SourceImageIO.metadata(url: $0) }
  ) async -> [Failure] {
    await withTaskGroup(of: Failure?.self) { group in
      var next = 0, completed = 0
      var failures: [Failure] = []
      func enqueue(_ url: URL) {
        group.addTask {
          guard !Task.isCancelled else { return nil }
          let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            try load(url)
          }
          do {
            try await withTaskCancellationHandler {
              try await worker.value
            } onCancel: { worker.cancel() }
            return nil
          } catch {
            return Failure(url: url, message: error.localizedDescription)
          }
        }
      }
      while next < min(concurrency, urls.count), !Task.isCancelled {
        enqueue(urls[next]); next += 1
      }
      while let result = await group.next() {
        guard !Task.isCancelled else { group.cancelAll(); break }
        if let result { failures.append(result) }
        completed += 1
        await progress(completed)
        if next < urls.count { enqueue(urls[next]); next += 1 }
      }
      return failures.sorted { $0.url.path < $1.url.path }
    }
  }
}

// MARK: - ImageService
public actor WinImageService {
  private struct Entry {
    let identity: SourceStamp
    let dimension: Int
    let pixels: PixelBuffer
    let width: Int
    let height: Int
    var access: UInt64
    var bytes: Int { pixels.pixels.count * MemoryLayout<SIMD4<Float>>.stride }
  }

  private var entries: [Entry] = []
  private var access: UInt64 = 0
  private let cacheLimitBytes: Int
  private let cacheLimitEntries: Int

  public init(cacheLimitBytes: Int = 1664 * 1024 * 1024, cacheLimitEntries: Int = 40) {
    self.cacheLimitBytes = max(0, cacheLimitBytes)
    self.cacheLimitEntries = max(0, cacheLimitEntries)
  }

  public func clear() {
    entries.removeAll(keepingCapacity: false)
  }

  public func preview(_ url: URL) throws -> (PixelBuffer, Int, Int) {
    let entry = try previewEntry(url, maxDimension: 1600)
    return (entry.pixels, entry.width, entry.height)
  }

  public func neutralSample(_ url: URL, sourceX: Int, sourceY: Int) throws -> PixelBuffer {
    let entry = try previewEntry(url, maxDimension: 1600)
    return Self.neutralSample(
      entry.pixels, sourceWidth: entry.width, sourceHeight: entry.height,
      sourceX: sourceX, sourceY: sourceY)
  }

  public nonisolated static func neutralSample(
    _ preview: PixelBuffer, sourceWidth: Int, sourceHeight: Int, sourceX: Int, sourceY: Int
  ) -> PixelBuffer {
    let side = max(1, Int((Double(max(preview.width, preview.height)) * 0.008).rounded()))
    let x = max(0, min(preview.width - 1, Int(floor(Double(sourceX) * Double(preview.width) / Double(sourceWidth)))))
    let y = max(0, min(preview.height - 1, Int(floor(Double(sourceY) * Double(preview.height) / Double(sourceHeight)))))
    let left = max(0, x - side / 2), top = max(0, y - side / 2)
    let right = min(preview.width, x - side / 2 + side)
    let bottom = min(preview.height, y - side / 2 + side)
    var pixels: [SIMD4<Float>] = []
    for row in top..<bottom {
      pixels.append(contentsOf: preview.pixels[(row * preview.width + left)..<(row * preview.width + right)])
    }
    return PixelBuffer(width: right - left, height: bottom - top, pixels: pixels)
  }

  public func thumbnailSource(_ url: URL) throws -> (PixelBuffer, Int, Int) {
    let entry = try previewEntry(url, maxDimension: 240)
    return (entry.pixels, entry.width, entry.height)
  }

  public func sample(
    _ url: URL, rect: PixelRect, matrix: PrintDensityMatrix, frameID: UUID, cmosMatrix: MatrixPreset = .identity
  ) throws -> FilmCalibration {
    try Task.checkCancellation()
    let identity = try SourceStamp(url: url)
    let metadata = try SourceImageIO.metadata(url: url)
    let image = try SourceImageIO.readRegion(url: url, rect: rect)
    let local = PixelRect(x: 0, y: 0, width: image.width, height: image.height)
    try Task.checkCancellation()
    var calibration = try Pipeline.calibrate(
      image: image, rect: local, matrix: matrix, sourceFrameID: frameID, cmosMatrix: cmosMatrix)
    calibration.selection = rect
    calibration.sourceWidth = metadata.width
    calibration.sourceHeight = metadata.height
    try Task.checkCancellation()
    guard identity == (try SourceStamp(url: url)) else {
      throw PrintroomError.invalid("采样期间源图像已改变，请重新采样")
    }
    return calibration
  }

  private func previewEntry(_ url: URL, maxDimension: Int) throws -> Entry {
    try Task.checkCancellation()
    guard (1...4096).contains(maxDimension) else {
      throw PrintroomError.invalid("预览长边必须在 1–4096 像素之间")
    }
    let identity = try SourceStamp(url: url)
    access &+= 1
    entries.removeAll { $0.identity.url == identity.url && $0.identity != identity }
    if let index = entries.firstIndex(where: { $0.identity == identity && $0.dimension == maxDimension }) {
      entries[index].access = access
      return entries[index]
    }
    let metadata = try SourceImageIO.metadata(url: url)
    let image = try SourceImageIO.readPreview(url: url, maxDimension: maxDimension)
    let pixels = try pixelBuffer(image)
    try Task.checkCancellation()
    guard identity == (try SourceStamp(url: url)) else {
      throw PrintroomError.invalid("读取期间源图像已改变，请重新打开照片")
    }
    let entry = Entry(
      identity: identity, dimension: maxDimension, pixels: pixels,
      width: metadata.width, height: metadata.height, access: access)
    if cacheLimitEntries > 0, entry.bytes <= cacheLimitBytes {
      while !entries.isEmpty,
        entries.count >= cacheLimitEntries
          || entries.reduce(0, { $0 + $1.bytes }) + entry.bytes > cacheLimitBytes
      {
        let oldest = entries.indices.min { entries[$0].access < entries[$1].access }!
        entries.remove(at: oldest)
      }
      entries.append(entry)
    }
    return entry
  }

  private func pixelBuffer(_ image: LinearImage) throws -> PixelBuffer {
    var pixels = [SIMD4<Float>]()
    pixels.reserveCapacity(image.width * image.height)
    for y in 0..<image.height {
      try Task.checkCancellation()
      for x in 0..<image.width { pixels.append(SIMD4(image.pixel(x: x, y: y), 1)) }
    }
    return PixelBuffer(width: image.width, height: image.height, pixels: pixels)
  }
}

// MARK: - PreviewPresentationCache
public struct WinPreviewPresentationKey: Equatable, Sendable {
  public let source: SourceStamp
  public let frameID: UUID
  public let calibration: FilmCalibration
  public let adjustments: FrameAdjustments
  public let orientation: FrameOrientation
  public let crop: FrameCrop?
  public let stage: PipelineStage
  public var sprocketWhitening: SprocketWhiteningSettings = .init()
  public var protectedCrop: FrameCrop? = nil
}

public struct WinPreviewPresentationCache {
  public struct Entry {
    public let key: WinPreviewPresentationKey
    public let bitmap: WinDisplayBitmap
    public let sourceWidth: Int
    public let sourceHeight: Int
    public var histogram: HistogramStatistics? = nil
    public var bytes: Int {
      bitmap.byteCount + (histogram.map { stats in
        stats.channels.count * MemoryLayout<HistogramChannel>.stride
          + stats.channels.reduce(0) { $0 + $1.bins.count * MemoryLayout<UInt64>.stride }
      } ?? 0)
    }
  }

  private(set) public var entries: [Entry] = []
  public let byteLimit: Int
  public let countLimit: Int
  public var bytes: Int { entries.reduce(0) { $0 + $1.bytes } }

  public init(byteLimit: Int = 512 * 1024 * 1024, countLimit: Int = 40) {
    self.byteLimit = max(0, byteLimit)
    self.countLimit = max(0, countLimit)
  }

  public mutating func image(for key: WinPreviewPresentationKey) -> Entry? {
    guard let index = entries.firstIndex(where: { $0.key == key }) else { return nil }
    let hit = entries.remove(at: index)
    entries.append(hit)
    return hit
  }

  public func contains(_ key: WinPreviewPresentationKey, histogramStage: PipelineStage?) -> Bool {
    entries.contains { $0.key == key && (histogramStage == nil || $0.histogram?.stage == histogramStage) }
  }

  public mutating func store(_ entry: Entry) {
    var entry = entry
    if entry.histogram == nil, let previous = entries.first(where: { $0.key == entry.key }) {
      entry.histogram = previous.histogram
    }
    entries.removeAll { $0.key.frameID == entry.key.frameID && $0.key.stage == entry.key.stage }
    guard countLimit > 0, entry.bytes <= byteLimit else { return }
    while !entries.isEmpty, entries.count >= countLimit || bytes + entry.bytes > byteLimit {
      entries.removeFirst()
    }
    entries.append(entry)
  }

  public mutating func clear() { entries.removeAll() }
}

// MARK: - PreviewRenderService
public struct WinRenderedPreview: Sendable {
  public let pixels: PixelBuffer
  public let bitmap: WinDisplayBitmap
  public var histogram: HistogramStatistics? = nil
}

public actor WinPreviewRenderService {
  private var pipeline: MetalPipeline?
  private var session: MetalPipeline.Session?
  private struct GeometryKey: Equatable {
    let source: UUID
    let crop: FrameCrop
    let orientation: FrameOrientation
    let width: Int
    let height: Int
  }
  private var geometryKey: GeometryKey?
  private var geometryInput: PixelBuffer?
  private var geometryIdentity = UUID()

  public init() {}

  public func render(
    _ input: PixelBuffer,
    calibration: FilmCalibration,
    adjustments: FrameAdjustments,
    assets: WinAppAssets,
    stage: PipelineStage = .final,
    original: Bool = false,
    orientation: FrameOrientation = .identity,
    inputIdentity: UUID? = nil,
    crop: FrameCrop? = nil,
    sourceWidth: Int? = nil,
    sourceHeight: Int? = nil,
    includeHistogram: Bool = false,
    histogramStage: PipelineStage? = nil,
    histogramCrop: FrameCrop? = nil,
    sprocketWhitening: SprocketWhiteningSettings = .init(),
    protectedCrop: FrameCrop? = nil
  ) throws -> WinRenderedPreview {
    try Task.checkCancellation()
    if pipeline !== assets.gpu || session == nil {
      pipeline = assets.gpu
      session = assets.gpu.makeSession()
    }
    var prepared = input
    var preparedIdentity = inputIdentity
    if let crop {
      let width = sourceWidth ?? input.width, height = sourceHeight ?? input.height
      let key = inputIdentity.map {
        GeometryKey(source: $0, crop: crop, orientation: orientation, width: width, height: height)
      }
      if let key, key == geometryKey, let cached = geometryInput {
        prepared = cached
      } else {
        let geometry = try CropGeometry(
          crop: crop, sourceWidth: width, sourceHeight: height, orientation: orientation)
        prepared = try geometry.render(
          input, maxDimension: max(input.width, input.height), cancelled: { Task.isCancelled })
        geometryKey = key
        geometryInput = key == nil ? nil : prepared
        geometryIdentity = UUID()
      }
      preparedIdentity = key == nil ? nil : geometryIdentity
    } else {
      geometryKey = nil
      geometryInput = nil
    }

    let whitening: SprocketWhiteningContext?
    if crop == nil, sprocketWhitening.enabled, calibration.isCalibrated, let protectedCrop {
      whitening = try SprocketWhiteningContext(
        settings: sprocketWhitening, protectedCrop: protectedCrop,
        sourceWidth: sourceWidth ?? input.width, sourceHeight: sourceHeight ?? input.height,
        renderWidth: input.width, renderHeight: input.height)
    } else {
      whitening = nil
    }

    let output = original
      ? prepared
      : try session!.render(
          prepared, calibration: calibration, adjustments: adjustments,
          lut: assets.lut(for: adjustments.cineonLogLUT), stage: stage,
          inputIdentity: preparedIdentity, sprocketWhitening: whitening)
    try Task.checkCancellation()
    let oriented = crop == nil
      ? try orientation.transform(output, cancelled: { Task.isCancelled }) : output
    try Task.checkCancellation()

    let bitmap = try assets.displayColor.makeDisplayBitmap(
      oriented, diagnostic: stage != .final, original: original)
    try Task.checkCancellation()

    var histogram: HistogramStatistics?
    if includeHistogram && !original {
      let statisticsStage = histogramStage ?? stage
      let statisticsPixels: PixelBuffer
      if let histogramCrop, histogramCrop != crop {
        let geometry = try CropGeometry(
          crop: histogramCrop,
          sourceWidth: sourceWidth ?? input.width, sourceHeight: sourceHeight ?? input.height,
          orientation: orientation)
        let statisticsInput = try geometry.render(
          input, maxDimension: max(input.width, input.height), cancelled: { Task.isCancelled })
        statisticsPixels = try session!.render(
          statisticsInput, calibration: calibration, adjustments: adjustments,
          lut: assets.lut(for: adjustments.cineonLogLUT), stage: statisticsStage)
      } else if statisticsStage == stage {
        statisticsPixels = oriented
      } else {
        let statisticsOutput = try session!.render(
          prepared, calibration: calibration, adjustments: adjustments,
          lut: assets.lut(for: adjustments.cineonLogLUT), stage: statisticsStage,
          inputIdentity: preparedIdentity, sprocketWhitening: whitening)
        statisticsPixels = crop == nil
          ? try orientation.transform(statisticsOutput, cancelled: { Task.isCancelled })
          : statisticsOutput
      }
      histogram = try HistogramStatistics.computePreview(
        statisticsPixels, stage: statisticsStage, cancelled: { Task.isCancelled })
    }
    return WinRenderedPreview(pixels: oriented, bitmap: bitmap, histogram: histogram)
  }
}

// MARK: - AutoCropService & RollTimingService
public struct AutoCropInput: Sendable {
  public let id: UUID
  public let url: URL
}
public struct AutoCropOutput: Sendable {
  public let id: UUID
  public let crop: FrameCrop
  public let needsReview: Bool
  public let source: SourceStamp
}

public enum WinAutoCropService {
  public static func run(
    inputs: [AutoCropInput],
    targets: Set<UUID>,
    aspectRatio: Double,
    analysisCacheByteLimit: Int = 128 * 1024 * 1024,
    progress: @escaping @Sendable (String) async -> Void
  ) async throws -> [AutoCropOutput] {
    let worker = Task.detached(priority: .userInitiated) {
      var seeds: [AutoCropSeed] = [], stamps: [SourceStamp] = []
      var analyses: [Int: AutoCropAnalysis] = [:]
      var dimensions: [(width: Int, height: Int)] = []
      let analysisBudget = max(0, analysisCacheByteLimit)
      var analysisBytes = 0
      for (index, input) in inputs.enumerated() {
        try Task.checkCancellation()
        await progress("分析画幅 \(index + 1)/\(inputs.count)")
        let stamp = try SourceStamp(url: input.url)
        let image = try SourceImageIO.readPreview(url: input.url, maxDimension: 1600)
        let metadata = try SourceImageIO.metadata(url: input.url)
        let analysis = try AutoCropAnalyzer.prepare(
          image, sourceWidth: metadata.width, sourceHeight: metadata.height)
        let bytes = analysis.width * analysis.height * MemoryLayout<Float>.stride
        if targets.contains(input.id), bytes <= analysisBudget - analysisBytes {
          analyses[index] = analysis
          analysisBytes += bytes
        }
        dimensions.append((metadata.width, metadata.height))
        guard try SourceStamp(url: input.url) == stamp else {
          throw PrintroomError.invalid("自动裁剪期间源照片已改变：\(input.url.lastPathComponent)")
        }
        seeds.append(analysis.seed); stamps.append(stamp)
      }
      let template = try AutoCropAnalyzer.template(fromSeeds: seeds, aspectRatio: aspectRatio)
      var result: [AutoCropOutput] = []
      for (index, input) in inputs.enumerated() where targets.contains(input.id) {
        try Task.checkCancellation()
        await progress("定位裁框 \(result.count + 1)/\(targets.count)")
        guard try SourceStamp(url: input.url) == stamps[index] else {
          throw PrintroomError.invalid("自动裁剪期间源照片已改变：\(input.url.lastPathComponent)")
        }
        let metadata = dimensions[index]
        let analysis: AutoCropAnalysis
        if let cached = analyses.removeValue(forKey: index) {
          analysis = cached
        } else {
          let image = try SourceImageIO.readPreview(url: input.url, maxDimension: 1600)
          analysis = try AutoCropAnalyzer.prepare(
            image, seed: seeds[index], sourceWidth: metadata.width, sourceHeight: metadata.height)
        }
        let fit = try AutoCropAnalyzer.fit(
          analysis, template: template,
          sourceWidth: metadata.width, sourceHeight: metadata.height,
          requiresAllEdges: index == inputs.startIndex || index == inputs.index(before: inputs.endIndex))
        guard try SourceStamp(url: input.url) == stamps[index] else {
          throw PrintroomError.invalid("自动裁剪期间源照片已改变：\(input.url.lastPathComponent)")
        }
        result.append(AutoCropOutput(
          id: input.id, crop: fit.crop, needsReview: fit.needsReview, source: stamps[index]))
      }
      try Task.checkCancellation()
      for stamp in stamps where try SourceStamp(url: stamp.url) != stamp {
        throw PrintroomError.invalid("自动裁剪期间源照片已改变：\(stamp.url.lastPathComponent)")
      }
      return result
    }
    return try await withTaskCancellationHandler(
      operation: { try await worker.value },
      onCancel: { worker.cancel() })
  }
}

public struct WinRollTimingResult: Sendable {
  public let timing: TimingParameters
  public let sources: [SourceStamp]
  public var masters: [UUID: Int] = [:]
}

public enum WinRollTimingService {
  public static func run(
    project: RollProject,
    folder: URL,
    assets: WinAppAssets,
    autoExposure: Bool = false,
    progress: @escaping @Sendable (String) async -> Void
  ) async throws -> WinRollTimingResult {
    let worker = Task.detached(priority: .userInitiated) {
      guard let firstFrame = project.frames.first else {
        throw PrintroomError.invalid("胶卷没有照片，无法分析色罩。")
      }
      let lut = assets.lut(for: firstFrame.adjustments.cineonLogLUT)
      let analysisIDs = Set(project.frames.dropFirst().dropLast().filter { !$0.isMissing }.map(\.id))
      guard !analysisIDs.isEmpty else {
        throw PrintroomError.invalid("跳过首尾张后没有可分析的照片，请确保胶卷至少有三张且中间照片可用。")
      }
      let frames = project.frames.filter { !$0.isMissing && (autoExposure || analysisIDs.contains($0.id)) }
      var samples: [RollTiming.Frame] = [], sources: [SourceStamp] = []
      for (i, frame) in frames.enumerated() {
        try Task.checkCancellation()
        await progress("分析 \(i + 1)/\(frames.count)")
        let url = folder.appendingPathComponent(frame.filename)
        let stamp = try SourceStamp(url: url)
        let metadata = try SourceImageIO.metadata(url: url)
        let image = try SourceImageIO.readPreview(url: url, maxDimension: 1600)
        let geometry = try CropGeometry(
          crop: frame.crop, sourceWidth: metadata.width, sourceHeight: metadata.height, orientation: frame.orientation)
        let cropped = try geometry.render(image.preview(maxDimension: 1600), maxDimension: 1600, cancelled: { Task.isCancelled })
        samples.append(RollTiming.Frame(
          densityCV: try RollTiming.samples(cropped, calibration: project.calibration), lut: lut))
        guard try SourceStamp(url: url) == stamp else {
          throw PrintroomError.invalid("分析期间照片已改变，请重新分析。")
        }
        sources.append(stamp)
      }
      await progress("正在计算…")
      let analysisSamples = zip(frames, samples).compactMap { frame, sample in
        analysisIDs.contains(frame.id) ? sample : nil
      }
      let timing = try RollTiming.solve(analysisSamples, profile: assets.profile)
      var masters: [UUID: Int] = [:]
      if autoExposure {
        await progress("正在计算自动曝光…")
        for (frame, sample) in zip(frames, samples) {
          masters[frame.id] = try RollTiming.automaticMaster(densityCV: sample.densityCV, timing: timing)
        }
      }
      for stamp in sources where try SourceStamp(url: stamp.url) != stamp {
        throw PrintroomError.invalid("分析期间照片已改变，请重新分析。")
      }
      return WinRollTimingResult(timing: timing, sources: sources, masters: masters)
    }
    return try await withTaskCancellationHandler(
      operation: { try await worker.value },
      onCancel: { worker.cancel() })
  }
}

// MARK: - RecentRolls (File-backed under %LOCALAPPDATA%\Printroom)
public struct RecentRoll: Codable, Identifiable, Equatable, Sendable {
  public var id: String { path }
  public let path: String
  public let projectID: UUID
  public let openedAt: Date
  public var name: String? = nil
  public var displayName: String { name ?? url.lastPathComponent }
  public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
}

public final class WinRecentRolls: @unchecked Sendable {
  public private(set) var entries: [RecentRoll] = []
  public private(set) var removed: RecentRoll?
  private let storeURL: URL
  private var removalExpiry: Task<Void, Never>?

  public init(storeURL: URL? = nil) {
    let base = DiskCachePolicy.root.deletingLastPathComponent().appendingPathComponent("Printroom", isDirectory: true)
    self.storeURL = storeURL ?? base.appendingPathComponent("recent-rolls-v1.json")
    if let data = try? Data(contentsOf: self.storeURL),
       let decoded = try? JSONDecoder().decode([RecentRoll].self, from: data) {
      self.entries = decoded
    }
  }

  public func record(folder: URL, projectID: UUID, replacing: String? = nil, date: Date = Date(), name: String? = nil) {
    let path = folder.standardizedFileURL.resolvingSymlinksInPath().path
    entries.removeAll { $0.path.caseInsensitiveCompare(path) == .orderedSame || (replacing != nil && $0.path.caseInsensitiveCompare(replacing!) == .orderedSame) }
    entries.insert(RecentRoll(path: path, projectID: projectID, openedAt: date, name: name), at: 0)
    entries = Array(entries.prefix(20))
    persist()
  }

  public func updateName(folder: URL, name: String?) {
    let path = folder.standardizedFileURL.resolvingSymlinksInPath().path
    guard let index = entries.firstIndex(where: { $0.path.caseInsensitiveCompare(path) == .orderedSame }) else { return }
    entries[index].name = name
    persist()
  }

  public func remove(path: String, onExpire: @escaping @Sendable () -> Void) {
    entries.removeAll { $0.id == path }
    persist()
    _ = onExpire
  }

  public func removeEntry(_ entry: RecentRoll, onExpire: @escaping @Sendable () -> Void) {
    entries.removeAll { $0.id == entry.id }
    removed = entry
    persist()
    removalExpiry?.cancel()
    removalExpiry = Task {
      do { try await Task.sleep(for: .seconds(6)) } catch { return }
      if !Task.isCancelled { onExpire() }
    }
  }

  public func clearExpiredRemoval() {
    removed = nil
  }

  public func undoRemoval() {
    guard let removed else { return }
    removalExpiry?.cancel()
    if !entries.contains(where: { $0.id == removed.id }) { entries.append(removed) }
    entries.sort { $0.openedAt > $1.openedAt }
    entries = Array(entries.prefix(20))
    self.removed = nil
    persist()
  }

  private func persist() {
    do {
      try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      let data = try JSONEncoder().encode(entries)
      try PlatformFS.atomicWrite(data, to: storeURL)
    } catch {
      // Ignore recent-list persistence errors
    }
  }
}

// MARK: - WinDiskThumbnailCache (WIC 16-bit RGBA ICC-tagged PNGs)
public actor WinDiskThumbnailCache {
  public struct MaintenanceResult: Sendable {
    public let removedFiles: Int
    public let remainingFiles: Int
    public let remainingBytes: Int64
  }
  private struct Entry {
    let url: URL
    let size: Int64
    let modified: Date
  }
  public let directory: URL
  public let maximumBytes: Int64
  public let maximumAge: TimeInterval
  private let managedRoot: URL?
  private var maintenanceBatchDepth = 0
  private var deferredWrites = 0
  private var urgentMaintenanceScheduled = false
  private var maintenanceFallback: Task<Void, Never>?
  private var usesManagedPolicy: Bool {
    managedRoot == DiskCachePolicy.root.appendingPathComponent("thumbnails-v1", isDirectory: true).standardizedFileURL
  }

  public init(
    directory: URL,
    maximumBytes: Int64 = 512 * 1024 * 1024,
    maximumAge: TimeInterval = 30 * 24 * 60 * 60,
    managedRoot: URL? = nil
  ) {
    self.managedRoot = managedRoot?.standardizedFileURL
    self.directory = directory.standardizedFileURL
    self.maximumBytes = max(0, maximumBytes)
    self.maximumAge = max(0, maximumAge)
  }

  public static func forRoll(folder: URL, projectID: UUID, cacheRoot: URL? = nil) -> WinDiskThumbnailCache {
    let root = (cacheRoot ?? DiskCachePolicy.root.appendingPathComponent("thumbnails-v1", isDirectory: true)).standardizedFileURL
    let identity = projectID.uuidString + "\n" + folder.standardizedFileURL.path
    let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    return WinDiskThumbnailCache(
      directory: root.appendingPathComponent(key, isDirectory: true)
        .appendingPathComponent(".printroom-cache", isDirectory: true),
      managedRoot: root)
  }

  public func migrateLegacy(from folder: URL) async throws {
    let legacy = WinDiskThumbnailCache(directory: folder.appendingPathComponent(".printroom-cache", isDirectory: true))
    try await legacy.transferOwnedImages(to: self)
  }

  private func transferOwnedImages(to destination: WinDiskThumbnailCache) async throws {
    try validateDirectory(create: false)
    guard FileManager.default.fileExists(atPath: directory.path) else { return }
    for entry in try ownedFiles() {
      try Task.checkCancellation()
      if entry.url.pathExtension == "png" {
        let key = entry.url.deletingPathExtension().lastPathComponent
        guard let decoded = try rawRGBA16(for: key) else { continue }
        try await destination.store(rgba16: decoded.rgba16, width: decoded.width, height: decoded.height, iccProfile: nil, for: key)
        try Task.checkCancellation()
        try? FileManager.default.removeItem(at: entry.url)
      } else if Date().timeIntervalSince(entry.modified) > 24 * 60 * 60 {
        try? FileManager.default.removeItem(at: entry.url)
      }
    }
    if ((try? FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty) == true) {
      try? FileManager.default.removeItem(at: directory)
    }
  }

  public func rawRGBA16(for key: String) throws -> (width: Int, height: Int, rgba16: [UInt16])? {
    try Task.checkCancellation()
    try validateDirectory(create: false)
    let file = try fileURL(key)
    guard let st = try? PlatformFS.lstat(file), st.isRegular else { return nil }
    let cPath = file.withUnsafeFileSystemRepresentation { String(cString: $0!) }
    var ptr: UnsafeMutablePointer<UInt16>?
    var w: UInt32 = 0, h: UInt32 = 0, winErr: UInt32 = 0
    let rc = cPath.withCString { pr_win_wic_decode_png_rgba16($0, &ptr, &w, &h, &winErr) }
    guard rc == 0, let ptr, w > 0, h > 0 else {
      if let ptr { pr_win_free_buffer(ptr) }
      return nil
    }
    let count = Int(w) * Int(h) * 4
    let samples = Array(UnsafeBufferPointer(start: ptr, count: count))
    pr_win_free_buffer(ptr)
    try Task.checkCancellation()
    try? PlatformFS.setFileDates(file, creation: nil, modification: Date())
    return (Int(w), Int(h), samples)
  }

  public func beginMaintenanceBatch() { maintenanceBatchDepth += 1 }

  @discardableResult
  public nonisolated func endMaintenanceBatch() -> Task<Void, Never> {
    Task.detached(priority: .utility) { await self.completeMaintenanceBatch() }
  }

  private func completeMaintenanceBatch() {
    maintenanceBatchDepth = max(0, maintenanceBatchDepth - 1)
    if maintenanceBatchDepth == 0 { flushDeferredMaintenance() }
  }

  private func deferMaintenanceAfterWrite() {
    deferredWrites += 1
    if maintenanceFallback == nil {
      maintenanceFallback = Task.detached(priority: .utility) {
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
        await self.flushDeferredMaintenance()
      }
    }
    if deferredWrites >= 64 && !urgentMaintenanceScheduled {
      urgentMaintenanceScheduled = true
      Task.detached(priority: .utility) { await self.flushDeferredMaintenance() }
    }
  }

  private func flushDeferredMaintenance() {
    guard deferredWrites > 0 else { return }
    deferredWrites = 0
    urgentMaintenanceScheduled = false
    let fallback = maintenanceFallback
    maintenanceFallback = nil
    defer { fallback?.cancel() }
    do { _ = try maintain() } catch {
      if usesManagedPolicy { SourceProxyService.shared.scheduleMaintenance() }
    }
  }

  public func store(rgba16: [UInt16], width: Int, height: Int, iccProfile: Data?, for key: String) throws {
    try Task.checkCancellation()
    try validateDirectory(create: true)
    let file = try fileURL(key)
    let temporary = directory.appendingPathComponent(".printroom-thumbnail-\(UUID().uuidString).png.tmp")
    defer { try? FileManager.default.removeItem(at: temporary) }

    var outPtr: UnsafeMutablePointer<UInt8>?
    var outLen: Int = 0
    var winErr: UInt32 = 0
    let rc: Int32 = rgba16.withUnsafeBufferPointer { pxBuf in
      if let iccProfile {
        return iccProfile.withUnsafeBytes { iccBuf in
          let iccPtr = iccBuf.baseAddress?.assumingMemoryBound(to: UInt8.self)
          return pr_win_wic_encode_png_rgba16(
            pxBuf.baseAddress, UInt32(width), UInt32(height), iccPtr, iccProfile.count,
            &outPtr, &outLen, &winErr)
        }
      } else {
        return pr_win_wic_encode_png_rgba16(
          pxBuf.baseAddress, UInt32(width), UInt32(height), nil, 0, &outPtr, &outLen, &winErr)
      }
    }
    guard rc == 0, let outPtr, outLen > 0 else {
      if let outPtr { pr_win_free_buffer(outPtr) }
      throw PrintroomError.invalid("无法创建缩略图缓存（0x\(String(winErr, radix: 16))）")
    }
    let pngData = Data(bytes: outPtr, count: outLen)
    pr_win_free_buffer(outPtr)

    let fd = try PlatformFS.openTempExclusive(temporary)
    do {
      try PlatformFS.writeAll(handle: fd, data: pngData)
      try PlatformFS.flushAndClose(handle: fd)
    } catch {
      PlatformFS.closeLock(handle: fd)
      throw error
    }

    try Task.checkCancellation()
    if (try? PlatformFS.pathExistsNoFollow(file)) == true {
      guard let st = try? PlatformFS.lstat(file), st.isRegular else {
        throw PrintroomError.invalid("缩略图缓存目标不是普通文件")
      }
      try PlatformFS.moveReplace(from: temporary, to: file)
    } else {
      try PlatformFS.moveExclusive(from: temporary, to: file)
    }
    if maintenanceBatchDepth > 0 { deferMaintenanceAfterWrite() }
    else { _ = try maintain() }
  }

  @discardableResult
  public func maintain(now: Date = Date()) throws -> MaintenanceResult {
    try Task.checkCancellation()
    try validateDirectory(create: false)
    guard FileManager.default.fileExists(atPath: directory.path) else {
      return MaintenanceResult(removedFiles: 0, remainingFiles: 0, remainingBytes: 0)
    }
    let entries = try ownedFiles()
    var retained: [Entry] = []
    var removed = 0
    for entry in entries {
      try Task.checkCancellation()
      let temporary = entry.url.lastPathComponent.hasSuffix(".png.tmp")
      let ageLimit = temporary ? 24 * 60 * 60 : (usesManagedPolicy ? .infinity : maximumAge)
      if now.timeIntervalSince(entry.modified) > ageLimit {
        try FileManager.default.removeItem(at: entry.url)
        removed += 1
      } else if !temporary {
        retained.append(entry)
      }
    }
    retained.sort { $0.modified < $1.modified }
    var bytes = retained.reduce(Int64(0)) { $0 + $1.size }
    var evicted = 0
    for entry in retained where !usesManagedPolicy && bytes > maximumBytes {
      try Task.checkCancellation()
      try FileManager.default.removeItem(at: entry.url)
      bytes -= entry.size
      removed += 1
      evicted += 1
    }
    if usesManagedPolicy { SourceProxyService.shared.scheduleMaintenance() }
    return MaintenanceResult(
      removedFiles: removed, remainingFiles: retained.count - evicted, remainingBytes: bytes)
  }

  private func fileURL(_ key: String) throws -> URL {
    guard Self.isDigest(key) else { throw PrintroomError.invalid("缩略图缓存键必须是 SHA-256") }
    return directory.appendingPathComponent(key + ".png")
  }

  private func validateDirectory(create: Bool) throws {
    guard directory.isFileURL, directory.lastPathComponent == ".printroom-cache" else {
      throw PrintroomError.invalid("缩略图缓存目录名称无效")
    }
    if let managedRoot {
      for ancestor in [managedRoot.deletingLastPathComponent(), managedRoot, directory.deletingLastPathComponent()] {
        if let st = try? PlatformFS.lstat(ancestor) {
          guard st.isDirectory && !st.isReparse else {
            throw PrintroomError.invalid("系统缩略图缓存路径不能是符号链接或普通文件")
          }
        }
      }
    }
    if let st = try? PlatformFS.lstat(directory) {
      guard st.isDirectory && !st.isReparse else {
        throw PrintroomError.invalid("缩略图缓存目录不能是符号链接或普通文件")
      }
    } else if create {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
  }

  private func ownedFiles() throws -> [Entry] {
    try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
    ).compactMap { (url: URL) -> Entry? in
      let name = url.lastPathComponent
      let png = url.pathExtension == "png" && Self.isDigest(url.deletingPathExtension().lastPathComponent)
      let temporary = name.hasPrefix(".printroom-thumbnail-") && name.hasSuffix(".png.tmp")
        && UUID(uuidString: String(name.dropFirst(21).dropLast(8))) != nil
      guard png || temporary else { return nil }
      guard let st = try? PlatformFS.lstat(url), st.isRegular else { return nil }
      let dates = try? PlatformFS.getFileDates(url)
      return Entry(url: url, size: st.size, modified: dates?.modification ?? .distantPast)
    }
  }

  private static func isDigest(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }
}

// MARK: - WinThumbnailCoordinator
public final class WinThumbnailCoordinator: @unchecked Sendable {
  private let thumbnailRenderer = WinPreviewRenderService()
  private let thumbnailService = WinImageService(cacheLimitBytes: 16 * 1024 * 1024, cacheLimitEntries: 12)
  private let lock = NSLock()
  private var pendingThumbnailIDs: Set<UUID> = []
  private var thumbnailTask: Task<Void, Never>?
  private var thumbnailGeneration = UUID()
  public var isRunning: Bool { lock.withLock { thumbnailTask != nil } }

  public init() {}

  public func reset() {
    lock.withLock {
      thumbnailTask?.cancel()
      thumbnailTask = nil
      thumbnailGeneration = UUID()
      pendingThumbnailIDs = []
    }
  }

  private func sourceIsCurrent(_ source: SourceStamp) -> Bool {
    (try? SourceStamp(url: source.url)) == source
  }

  public func refresh(
    project: RollProject,
    folder: URL,
    assets: WinAppAssets,
    activeFrameID: UUID?,
    affectedIDs: Set<UUID>? = nil,
    publish: @escaping @Sendable (WinDisplayBitmap, WinPreviewPresentationKey) -> Bool,
    finished: @escaping @Sendable () -> Void
  ) {
    let available = Set(project.frames.filter { !$0.isMissing }.map(\.id))
    let (generation, frames) = lock.withLock { () -> (UUID, [FrameRecord]) in
      pendingThumbnailIDs.formUnion(affectedIDs ?? available)
      pendingThumbnailIDs.formIntersection(available)
      thumbnailTask?.cancel()
      let gen = UUID()
      thumbnailGeneration = gen
      let list = project.frames.filter { pendingThumbnailIDs.contains($0.id) }
        .sorted { $0.id == activeFrameID && $1.id != activeFrameID }
      return (gen, list)
    }
    let cache = WinDiskThumbnailCache.forRoll(folder: folder, projectID: project.id)
    let task = Task.detached(priority: .utility) { [weak self] in
      guard let self else { return }
      defer {
        let shouldFinish = self.lock.withLock { () -> Bool in
          if generation == self.thumbnailGeneration {
            self.thumbnailTask = nil
            return true
          }
          return false
        }
        if shouldFinish { finished() }
      }
      func isCurrentGen() -> Bool {
        !Task.isCancelled && self.lock.withLock { generation == self.thumbnailGeneration }
      }
      if affectedIDs == nil {
        try? await cache.migrateLegacy(from: folder)
        _ = try? await cache.maintain()
      }
      await cache.beginMaintenanceBatch()
      defer { cache.endMaintenanceBatch() }
      for frame in frames {
        guard isCurrentGen() else { return }
        do {
          let sourceURL = folder.appendingPathComponent(frame.filename)
          let stamp = try SourceStamp(url: sourceURL)
          let presentationKey = WinPreviewPresentationKey(
            source: stamp, frameID: frame.id, calibration: project.calibration,
            adjustments: frame.adjustments, orientation: frame.orientation,
            crop: frame.crop, stage: .final,
            sprocketWhitening: project.sprocketWhitening, protectedCrop: frame.crop)
          let encoder = JSONEncoder()
          encoder.outputFormatting = .sortedKeys
          let keyData = try encoder.encode(ThumbnailKey(
            filename: frame.filename,
            modified: stamp.modified?.timeIntervalSince1970 ?? 0,
            size: stamp.size,
            inode: stamp.inode,
            calibration: project.calibration,
            adjustments: frame.adjustments,
            orientation: frame.orientation,
            crop: frame.crop,
            sprocketWhitening: project.sprocketWhitening,
            algorithm: algorithmVersion,
            icc: ProjectAssetIdentity.expectedICCSHA256,
            lut: frame.adjustments.cineonLogLUT.sha256,
            dimension: 240,
            presentationVersion: "sdr-uint16-v2-original-linear-p3",
            rawProcessing: stamp.rawProcessing))
          let key = SHA256.hash(data: keyData).map { String(format: "%02x", $0) }.joined()
          if let cached = try? await cache.rawRGBA16(for: key) {
            guard isCurrentGen() else { return }
            let bmp = try assets.displayColor.makeDisplayBitmapFromRGB16(
              width: cached.width, height: cached.height, rgba16: cached.rgba16, sourceIsSRGB: false)
            let accepted = self.sourceIsCurrent(stamp) && publish(bmp, presentationKey)
            guard isCurrentGen() else { return }
            if accepted { self.lock.withLock { _ = self.pendingThumbnailIDs.remove(frame.id) } }
            continue
          }
          let source = try await self.thumbnailService.thumbnailSource(sourceURL)
          let original = !project.calibration.isCalibrated
          let output = try await self.thumbnailRenderer.render(
            source.0, calibration: project.calibration, adjustments: frame.adjustments,
            assets: assets, original: original,
            orientation: frame.orientation, crop: frame.crop,
            sourceWidth: source.1, sourceHeight: source.2,
            sprocketWhitening: project.sprocketWhitening, protectedCrop: frame.crop)
          guard isCurrentGen() else { return }
          let accepted = self.sourceIsCurrent(stamp) && publish(output.bitmap, presentationKey)
          let cachePayload = try assets.displayColor.makeCachePNGPayload(output.pixels, diagnostic: false, original: original)
          try? await cache.store(
            rgba16: cachePayload.rgba16, width: output.pixels.width, height: output.pixels.height,
            iccProfile: cachePayload.iccProfile, for: key)
          guard isCurrentGen() else { return }
          if accepted { self.lock.withLock { _ = self.pendingThumbnailIDs.remove(frame.id) } }
        } catch {
          // Keep pending
        }
      }
    }
    lock.withLock {
      if generation == self.thumbnailGeneration {
        self.thumbnailTask = task
      } else {
        task.cancel()
      }
    }
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
}

// MARK: - WinProjectPersistence
public final class WinProjectPersistence: @unchecked Sendable {
  private let lock = NSLock()
  private var pending: Task<Void, Never>?
  public init() {}
  public func cancel() {
    lock.withLock { pending?.cancel(); pending = nil }
  }
  public func schedule(_ save: @escaping @Sendable () -> Void) {
    let task = Task.detached(priority: .utility) {
      do { try await Task.sleep(for: .seconds(2)) } catch { return }
      guard !Task.isCancelled else { return }
      save()
    }
    lock.withLock {
      pending?.cancel()
      pending = task
    }
  }
  public func save(_ project: RollProject, folder: URL) throws {
    cancel()
    try ProjectStore.save(project, folder: folder)
  }
}
