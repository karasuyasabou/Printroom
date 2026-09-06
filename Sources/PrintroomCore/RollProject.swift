import Foundation

private let projectAlgorithmVersion = algorithmVersion

public struct FrameRecord: Identifiable, Codable, Equatable, Sendable {
  public var id: UUID
  public var filename: String
  public var adjustments: FrameAdjustments
  public var isMissing: Bool
  public var sourceSize: Int64
  /// Source modification time, in seconds since 1970. Used with size for cache invalidation.
  public var sourceModified: Double

  public init(
    id: UUID = UUID(), filename: String, adjustments: FrameAdjustments = .init(),
    isMissing: Bool = false, sourceSize: Int64 = 0, sourceModified: Double = 0
  ) {
    self.id = id
    self.filename = filename
    self.adjustments = adjustments
    self.isMissing = isMissing
    self.sourceSize = sourceSize
    self.sourceModified = sourceModified
  }
}

/// Asset identity from assets/manifest.json; paths are relative to the application asset root.
public struct ProjectAssetIdentity: Codable, Equatable, Sendable {
  public static let expectedLUTPath = "LUT/DCI-P3 Kodak 2383 D65.cube"
  public static let expectedLUTSHA256 =
    "90f625d8c09c4be0f05ffcd65a28d2f2d8f5011105f1ba6278e8b91073372be8"
  public static let expectedICCPath = "ICC/DCIP3_D65.icc"
  public static let expectedICCSHA256 =
    "eafc15fd36e56bc496b084d3aaacbdca419e65e03fac9a1930d024b1e8d9b32b"

  public var lutPath = expectedLUTPath
  public var lutSHA256 = expectedLUTSHA256
  public var workingICCPath = expectedICCPath
  public var workingICCSHA256 = expectedICCSHA256
  public init() {}
}

public struct ProjectInputInterpretation: Codable, Equatable, Sendable {
  public var primaries = "P3-D65"
  public var transfer = "linear"
  public var policy = "assignPreserveSamples"
  public init() {}
}

/// The supported export contract for this schema. Additional output profiles require migration.
public struct ProjectExportSettings: Codable, Equatable, Sendable {
  public var profileSHA256 = ProjectAssetIdentity.expectedICCSHA256
  public var bitsPerSample = 16
  public var embedsICC = true
  public var dithering = false
  public init() {}
}

public struct RollProject: Codable, Sendable {
  public static let currentSchemaVersion = 1

  public var schemaVersion = currentSchemaVersion
  public var algorithmVersion = projectAlgorithmVersion
  public var id = UUID()
  public var createdAt = Date()
  public var updatedAt = Date()
  public var assets = ProjectAssetIdentity()
  public var inputInterpretation = ProjectInputInterpretation()
  public var exportSettings = ProjectExportSettings()
  public var calibration = FilmCalibration()
  /// Preserves the original calibration while disclosing a missing/replaced sampling source.
  public var calibrationNeedsReview = false
  public var frames: [FrameRecord] = []
  public var lastActiveFrameID: UUID?

  // Session-only location permits a final target availability check immediately before applying.
  // Never encode an absolute path: moving an entire roll must preserve its identity and settings.
  fileprivate var sourceFolderURL: URL?
  /// Captured in the same coordinated read as the decoded project; never persisted.
  public var loadedModificationDate: Date?

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, algorithmVersion, id, createdAt, updatedAt, assets
    case inputInterpretation, exportSettings, calibration, calibrationNeedsReview
    case frames, lastActiveFrameID
  }

  public init() {}
}

public enum ProjectStoreError: LocalizedError, Equatable, Sendable {
  case invalidProject(String)
  case unsupportedSchema(Int)
  case incompatibleAlgorithm(String)
  case externalConflict
  case unavailableFrame(String)

  public var errorDescription: String? {
    switch self {
    case .invalidProject(let reason): "项目无效或已损坏：\(reason)"
    case .unsupportedSchema(let version): "不支持项目结构版本 \(version)，未覆盖原项目。"
    case .incompatibleAlgorithm(let version): "不兼容的算法版本：\(version)"
    case .externalConflict: "项目已被外部修改或删除。请重新载入或另存副本。"
    case .unavailableFrame(let name): "照片不存在或无法读取：\(name)"
    }
  }
}

public enum ProjectStore {
  public static let filename = ".printroom.json"
  private static let lock = NSLock()

  /// Opens and reconciles a roll without writing anything. preferredFile denotes a TIFF, not JSON.
  public static func open(folder: URL, preferredFile: URL? = nil) throws -> RollProject {
    lock.lock()
    defer { lock.unlock() }
    let folder = try validatedFolder(folder)
    var result: Result<RollProject, Error>?
    var coordinationError: NSError?
    NSFileCoordinator().coordinate(readingItemAt: folder, options: [], error: &coordinationError) {
      coordinated in
      result = Result {
        let projectURL = coordinated.appendingPathComponent(filename)
        var project: RollProject
        let loadedModificationDate = try fileDate(projectURL)
        if loadedModificationDate != nil {
          project = try decode(Data(contentsOf: projectURL))
        } else {
          project = RollProject()
        }
        project.sourceFolderURL = folder
        project.loadedModificationDate = loadedModificationDate
        let discovered = try discover(folder: coordinated)
        let oldFrames = Dictionary(uniqueKeysWithValues: project.frames.map { ($0.filename, $0) })
        var merged: [String: FrameRecord] = [:]
        for var frame in project.frames {
          frame.isMissing = true
          merged[frame.filename] = frame
        }
        for source in discovered {
          var frame = oldFrames[source.filename] ?? source
          frame.isMissing = source.isMissing
          if !source.isMissing {
            frame.sourceSize = source.sourceSize
            frame.sourceModified = source.sourceModified
          }
          merged[frame.filename] = frame
        }
        project.frames = merged.values.sorted { naturalLess($0.filename, $1.filename) }
        if let sourceID = project.calibration.sourceFrameID,
          let frame = project.frames.first(where: { $0.id == sourceID })
        {
          let previous = oldFrames[frame.filename]
          if frame.isMissing || previous?.sourceSize != frame.sourceSize
            || previous?.sourceModified != frame.sourceModified
          {
            project.calibrationNeedsReview = true
          }
        }
        if let preferredFile {
          guard preferredFile.isFileURL,
            preferredFile.standardizedFileURL.deletingLastPathComponent().resolvingSymlinksInPath()
              == folder,
            let preferred = project.frames.first(where: {
              $0.filename == preferredFile.lastPathComponent
            }),
            !preferred.isMissing
          else {
            throw ProjectStoreError.unavailableFrame(preferredFile.lastPathComponent)
          }
          project.lastActiveFrameID = preferred.id
        } else if !project.frames.contains(where: {
          $0.id == project.lastActiveFrameID && !$0.isMissing
        }) {
          project.lastActiveFrameID = project.frames.first(where: { !$0.isMissing })?.id
        }
        return project
      }
    }
    if let coordinationError { throw coordinationError }
    guard let result else { throw ProjectStoreError.invalidProject("无法协调项目读取") }
    return try result.get()
  }

  /// nil expects no existing project. Pass the last observed/returned date on every subsequent save.
  /// Validation and encoding finish before touching the destination; writes use a same-directory atomic replacement.
  @discardableResult
  public static func save(_ project: RollProject, folder: URL, expectedModification: Date?) throws
    -> Date
  {
    try validate(project)
    let folder = try validatedFolder(folder)
    var persisted = project
    persisted.updatedAt = Date()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(persisted)

    lock.lock()
    defer { lock.unlock() }
    let destination = folder.appendingPathComponent(filename)
    var result: Result<Date, Error>?
    var coordinationError: NSError?
    NSFileCoordinator().coordinate(
      writingItemAt: destination, options: .forReplacing, error: &coordinationError
    ) { coordinated in
      result = Result {
        let current = try fileDate(coordinated)
        guard current == expectedModification else { throw ProjectStoreError.externalConflict }
        if current != nil {
          // Even a caller with the newest timestamp cannot overwrite a damaged/future project.
          let existing = try decode(Data(contentsOf: coordinated))
          guard existing.id == project.id else { throw ProjectStoreError.externalConflict }
        }
        try data.write(to: coordinated, options: .atomic)
        guard let date = try fileDate(coordinated) else {
          throw ProjectStoreError.invalidProject("保存后无法读取修改时间")
        }
        return date
      }
    }
    if let coordinationError { throw coordinationError }
    guard let result else { throw ProjectStoreError.invalidProject("无法协调项目保存") }
    return try result.get()
  }

  public static func modificationDate(folder: URL) -> Date? {
    try? fileDate(folder.appendingPathComponent(filename))
  }

  public static func decodeSnapshot(_ data: Data) throws -> RollProject { try decode(data) }

  private static func decode(_ data: Data) throws -> RollProject {
    struct Header: Decodable {
      var schemaVersion: Int
      var algorithmVersion: String
    }
    do {
      let decoder = JSONDecoder()
      let header = try decoder.decode(Header.self, from: data)
      guard header.schemaVersion == RollProject.currentSchemaVersion else {
        throw ProjectStoreError.unsupportedSchema(header.schemaVersion)
      }
      guard header.algorithmVersion == projectAlgorithmVersion else {
        throw ProjectStoreError.incompatibleAlgorithm(header.algorithmVersion)
      }
      let project = try decoder.decode(RollProject.self, from: data)
      try validate(project)
      return project
    } catch let error as ProjectStoreError {
      throw error
    } catch {
      throw ProjectStoreError.invalidProject(error.localizedDescription)
    }
  }

  fileprivate static func validate(_ project: RollProject) throws {
    guard project.schemaVersion == RollProject.currentSchemaVersion else {
      throw ProjectStoreError.unsupportedSchema(project.schemaVersion)
    }
    guard project.algorithmVersion == projectAlgorithmVersion else {
      throw ProjectStoreError.incompatibleAlgorithm(project.algorithmVersion)
    }
    guard project.assets == ProjectAssetIdentity() else {
      throw ProjectStoreError.invalidProject("LUT 或 ICC 资产路径/指纹不兼容")
    }
    guard project.inputInterpretation == ProjectInputInterpretation(),
      project.exportSettings == ProjectExportSettings()
    else {
      throw ProjectStoreError.invalidProject("不兼容的输入解释或导出设置")
    }
    guard project.createdAt.timeIntervalSince1970.isFinite,
      project.updatedAt.timeIntervalSince1970.isFinite
    else {
      throw ProjectStoreError.invalidProject("非有限日期")
    }
    var ids = Set<UUID>()
    var names = Set<String>()
    for frame in project.frames {
      guard ids.insert(frame.id).inserted, names.insert(frame.filename).inserted else {
        throw ProjectStoreError.invalidProject("重复的照片 ID 或文件名")
      }
      try validateFilename(frame.filename)
      guard frame.sourceSize >= 0, frame.sourceModified.isFinite else {
        throw ProjectStoreError.invalidProject("照片源文件指纹无效")
      }
      try validateAdjustments(frame.adjustments)
    }
    if let active = project.lastActiveFrameID, !ids.contains(active) {
      throw ProjectStoreError.invalidProject("当前照片 ID 不属于项目")
    }
    try validateCalibration(project.calibration, frameIDs: ids)
  }

  private static func validateFilename(_ name: String) throws {
    guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
      !name.contains("\0"), isTIFF(name)
    else {
      throw ProjectStoreError.invalidProject("必须使用卷内 TIFF 相对文件名")
    }
  }

  fileprivate static func validateAdjustments(_ adjustments: FrameAdjustments) throws {
    do { try Pipeline.validate(adjustments) } catch {
      throw ProjectStoreError.invalidProject(error.localizedDescription)
    }
  }

  private static func validateCalibration(_ calibration: FilmCalibration, frameIDs: Set<UUID>)
    throws
  {
    func finite(_ value: SIMD3<Float>) -> Bool {
      value.x.isFinite && value.y.isFinite && value.z.isFinite
    }
    guard finite(calibration.gainRGB), finite(calibration.filmBaseOffsetCV) else {
      throw ProjectStoreError.invalidProject("片基派生参数必须有限")
    }
    guard let base = calibration.baseRGB else {
      guard calibration.gainRGB == SIMD3(repeating: 1),
        calibration.filmBaseOffsetCV == SIMD3(repeating: 0),
        calibration.sourceFrameID == nil, calibration.selection == nil,
        calibration.sourceWidth == nil, calibration.sourceHeight == nil
      else {
        throw ProjectStoreError.invalidProject("未校准状态含有残留校准数据")
      }
      return
    }
    guard finite(base), (0..<3).allSatisfy({ base[$0] > 0 && base[$0] <= 1 }),
      let sourceID = calibration.sourceFrameID, frameIDs.contains(sourceID),
      let rect = calibration.selection, let width = calibration.sourceWidth,
      let height = calibration.sourceHeight,
      width > 0, height > 0, width <= Int.max / height, width * height <= Int.max / 3,
      rect.x >= 0, rect.y >= 0, rect.width > 0, rect.height > 0,
      rect.width <= width, rect.height <= height, rect.x <= width - rect.width,
      rect.y <= height - rect.height,
      Double(rect.width) * Double(rect.height) >= 16
    else {
      throw ProjectStoreError.invalidProject("片基采样来源、尺寸、选区或中位数无效")
    }
    let expectedGain = SIMD3<Float>(repeating: 0.75) / base
    guard finite(expectedGain) else { throw ProjectStoreError.invalidProject("片基 gain 超出有限范围") }
    for channel in 0..<3 {
      guard calibration.gainRGB[channel] > 0,
        abs(calibration.gainRGB[channel] - expectedGain[channel]) <= 1e-6
          * max(1, abs(expectedGain[channel]))
      else {
        throw ProjectStoreError.invalidProject("片基 gain 与采样数据不一致")
      }
    }
    var expected = calibration
    expected.gainRGB = expectedGain
    let expectedOffset = try Pipeline.recalibrate(expected, matrix: calibration.matrix)
      .filmBaseOffsetCV
    guard (0..<3).allSatisfy({ abs(calibration.filmBaseOffsetCV[$0] - expectedOffset[$0]) <= 0.01 })
    else {
      throw ProjectStoreError.invalidProject("片基 offset 与采样数据或矩阵不一致")
    }
  }

  private static func validatedFolder(_ folder: URL) throws -> URL {
    guard folder.isFileURL else { throw ProjectStoreError.invalidProject("项目必须位于本地目录") }
    let resolved = folder.standardizedFileURL.resolvingSymlinksInPath()
    guard try resolved.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
      throw ProjectStoreError.invalidProject("卷路径不是目录")
    }
    return resolved
  }

  private static func fileDate(_ url: URL) throws -> Date? {
    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      guard attributes[.type] as? FileAttributeType == .typeRegular,
        let date = attributes[.modificationDate] as? Date
      else {
        throw ProjectStoreError.invalidProject("项目文件必须是普通文件，不能是符号链接或目录")
      }
      return date
    } catch let error as CocoaError
      where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile
    {
      return nil
    }
  }

  private static func isTIFF(_ name: String) -> Bool {
    ["tif", "tiff"].contains((name as NSString).pathExtension.lowercased())
  }

  private static func naturalLess(_ lhs: String, _ rhs: String) -> Bool {
    let comparison = lhs.compare(
      rhs, options: [.numeric, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    return comparison == .orderedSame
      ? lhs.utf8.lexicographicallyPrecedes(rhs.utf8) : comparison == .orderedAscending
  }

  private static func discover(folder: URL) throws -> [FrameRecord] {
    let urls = try FileManager.default.contentsOfDirectory(
      at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [])
    return urls.filter { isTIFF($0.lastPathComponent) }.compactMap { url in
      if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { return nil }
      if let source = sourceRecord(url: url, folder: folder) { return source }
      return FrameRecord(filename: url.lastPathComponent, isMissing: true)
    }
  }

  fileprivate static func sourceRecord(url: URL, folder: URL) -> FrameRecord? {
    let resolved = url.resolvingSymlinksInPath().standardizedFileURL
    // A link resolving outside the roll, or to a nested path, is never followed.
    guard
      resolved.deletingLastPathComponent() == folder.resolvingSymlinksInPath().standardizedFileURL,
      FileManager.default.isReadableFile(atPath: resolved.path),
      let values = try? resolved.resourceValues(forKeys: [
        .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
      ]),
      values.isRegularFile == true, let size = values.fileSize,
      let modified = values.contentModificationDate
    else { return nil }
    return FrameRecord(
      filename: url.lastPathComponent, sourceSize: Int64(size),
      sourceModified: modified.timeIntervalSince1970)
  }
}

public struct SelectionState: Sendable {
  public var activeFrameID: UUID?
  public var selectedFrameIDs: Set<UUID> = []
  public var anchorID: UUID?
  public init() {}

  /// ordered must contain only currently available frames in Filmstrip order.
  public mutating func click(
    _ id: UUID, ordered: [UUID], command: Bool = false, shift: Bool = false
  ) {
    reconcile(ordered)
    guard let clickedIndex = ordered.firstIndex(of: id) else { return }
    if shift, let anchorID, let anchorIndex = ordered.firstIndex(of: anchorID) {
      let range = Set(ordered[min(anchorIndex, clickedIndex)...max(anchorIndex, clickedIndex)])
      selectedFrameIDs = command ? selectedFrameIDs.union(range) : range
      activeFrameID = id
    } else if shift {
      selectedFrameIDs = [id]
      activeFrameID = id
      self.anchorID = id
    } else if command, selectedFrameIDs.contains(id) {
      selectedFrameIDs.remove(id)
      if activeFrameID == id {
        activeFrameID =
          ordered.enumerated().filter { selectedFrameIDs.contains($0.element) }.min {
            let left = abs($0.offset - clickedIndex)
            let right = abs($1.offset - clickedIndex)
            return left == right ? $0.offset < $1.offset : left < right
          }?.element
      }
      if self.anchorID == id { self.anchorID = activeFrameID }
      if selectedFrameIDs.isEmpty {
        activeFrameID = nil
        self.anchorID = nil
      }
    } else {
      if command { selectedFrameIDs.insert(id) } else { selectedFrameIDs = [id] }
      activeFrameID = id
      self.anchorID = id
    }
  }

  public mutating func selectAll(_ ordered: [UUID]) {
    reconcile(ordered)
    selectedFrameIDs = Set(ordered)
    if activeFrameID == nil { activeFrameID = ordered.first }
    if anchorID == nil { anchorID = activeFrameID }
  }

  private mutating func reconcile(_ ordered: [UUID]) {
    selectedFrameIDs.formIntersection(ordered)
    if let activeFrameID, !selectedFrameIDs.contains(activeFrameID) { self.activeFrameID = nil }
    if activeFrameID == nil {
      activeFrameID = ordered.first(where: { selectedFrameIDs.contains($0) })
    }
    if let anchorID, !selectedFrameIDs.contains(anchorID) { self.anchorID = activeFrameID }
    if selectedFrameIDs.isEmpty {
      activeFrameID = nil
      anchorID = nil
    }
  }
}

public struct ParameterSnapshot: Sendable {
  public static let currentFormatVersion = 1
  public let formatVersion: Int
  public let algorithmVersion: String
  public let pivotCV: Int
  public let sourceID: UUID
  public let sourceName: String
  public let adjustments: FrameAdjustments

  public init(frame: FrameRecord) {
    self.init(sourceID: frame.id, sourceName: frame.filename, adjustments: frame.adjustments)
  }

  public init(
    sourceID: UUID, sourceName: String, adjustments: FrameAdjustments,
    formatVersion: Int = currentFormatVersion, algorithmVersion: String = "printroom-density-v1",
    pivotCV: Int = 470
  ) {
    self.sourceID = sourceID
    self.sourceName = sourceName
    self.adjustments = adjustments
    self.formatVersion = formatVersion
    self.algorithmVersion = algorithmVersion
    self.pivotCV = pivotCV
  }

  /// Value semantics form one reversible transaction. The UI registers before/after with UndoManager.
  public func applying(to project: RollProject, targets: Set<UUID>) throws -> RollProject {
    guard formatVersion == Self.currentFormatVersion, algorithmVersion == projectAlgorithmVersion,
      pivotCV == 470
    else {
      throw ProjectStoreError.invalidProject("参数快照版本、算法或 pivot 不兼容")
    }
    guard !targets.isEmpty else { throw ProjectStoreError.invalidProject("未选择应用目标") }
    try ProjectStore.validate(project)
    try ProjectStore.validateAdjustments(adjustments)
    let targetFrames = project.frames.filter { targets.contains($0.id) }
    guard targetFrames.count == targets.count else {
      throw ProjectStoreError.invalidProject("应用目标不属于当前卷")
    }
    for frame in targetFrames {
      guard !frame.isMissing else { throw ProjectStoreError.unavailableFrame(frame.filename) }
      if let folder = project.sourceFolderURL,
        ProjectStore.sourceRecord(
          url: folder.appendingPathComponent(frame.filename), folder: folder) == nil
      {
        throw ProjectStoreError.unavailableFrame(frame.filename)
      }
    }
    var updated = project
    for index in updated.frames.indices where targets.contains(updated.frames[index].id) {
      updated.frames[index].adjustments = adjustments
    }
    return updated
  }
}
