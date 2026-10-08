import Foundation

private let projectAlgorithmVersion = algorithmVersion
private let legacyAlgorithmVersion = "printroom-density-v1"
private let migratingSchemaOne = CodingUserInfoKey(rawValue: "printroom.migratingSchemaOne")!
private let migratingLegacyCrop = CodingUserInfoKey(rawValue: "printroom.migratingLegacyCrop")!

public enum CropOrigin: String, Codable, Sendable { case automatic, manual }

public struct FrameRecord: Identifiable, Codable, Equatable, Sendable {
  public var id: UUID
  public var filename: String
  public var adjustments: FrameAdjustments
  /// User edit applied after TIFF orientation normalization; independent of Timing/Contrast.
  public var orientation: FrameOrientation
  /// nil retains the original full-frame image and exact original sampling path.
  public var crop: FrameCrop?
  public var cropOrigin: CropOrigin?
  public var cropNeedsReview: Bool
  public var isMissing: Bool
  public var sourceSize: Int64
  /// Source modification time, in seconds since 1970. Used with size for cache invalidation.
  public var sourceModified: Double
  /// Identity of the Adobe-prepared source. nil means TIFF or RAW not prepared yet.
  public var rawProcessing: RAWProcessingIdentity?

  public init(
    id: UUID = UUID(), filename: String, adjustments: FrameAdjustments = .init(),
    isMissing: Bool = false, sourceSize: Int64 = 0, sourceModified: Double = 0,
    orientation: FrameOrientation = .identity, crop: FrameCrop? = nil,
    rawProcessing: RAWProcessingIdentity? = nil,
    cropOrigin: CropOrigin? = nil, cropNeedsReview: Bool = false
  ) {
    self.id = id
    self.filename = filename
    self.adjustments = adjustments
    self.orientation = orientation
    self.crop = crop
    self.cropOrigin = cropOrigin
    self.cropNeedsReview = cropNeedsReview
    self.isMissing = isMissing
    self.sourceSize = sourceSize
    self.sourceModified = sourceModified
    self.rawProcessing = rawProcessing
  }

  /// The same manual-crop edit is used by single-frame commit and selective sync.
  /// Fit first so a failed constraint never clears an existing crop/review state.
  public mutating func applyManualCrop(_ value: FrameCrop?, sourceWidth: Int, sourceHeight: Int) throws {
    let fitted = try value?.constrained(sourceWidth: sourceWidth, sourceHeight: sourceHeight)
    crop = fitted
    cropOrigin = .manual
    cropNeedsReview = false
  }

  private enum CodingKeys: String, CodingKey {
    case id, filename, adjustments, orientation, crop, cropOrigin, cropNeedsReview, isMissing, sourceSize, sourceModified, rawProcessing
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UUID.self, forKey: .id)
    filename = try values.decode(String.self, forKey: .filename)
    adjustments = try values.decode(FrameAdjustments.self, forKey: .adjustments)
    isMissing = try values.decode(Bool.self, forKey: .isMissing)
    sourceSize = try values.decode(Int64.self, forKey: .sourceSize)
    sourceModified = try values.decode(Double.self, forKey: .sourceModified)
    cropOrigin = try values.decodeIfPresent(CropOrigin.self, forKey: .cropOrigin)
    cropNeedsReview = try values.decodeIfPresent(Bool.self, forKey: .cropNeedsReview) ?? false
    rawProcessing = try values.decodeIfPresent(RAWProcessingIdentity.self, forKey: .rawProcessing)
    if decoder.userInfo[migratingSchemaOne] as? Bool == true {
      // Schema 1 never had a user transform. Reject a conflicting extension rather than
      // accidentally applying it twice or silently changing the old default image.
      if values.contains(.orientation) {
        throw ProjectStoreError.invalidProject("schema 1 含有未定义的方向设置")
      }
      orientation = .identity
    } else {
      orientation = try values.decode(FrameOrientation.self, forKey: .orientation)
    }
    if decoder.userInfo[migratingLegacyCrop] as? Bool == true {
      guard !values.contains(.crop) else {
        throw ProjectStoreError.invalidProject("旧 schema 含有未定义的裁剪设置")
      }
      crop = nil
    } else {
      // A missing required key is damaged schema 3; explicit null means full image.
      guard values.contains(.crop) else {
        throw ProjectStoreError.invalidProject("schema 3 缺少裁剪设置")
      }
      crop = try values.decodeIfPresent(FrameCrop.self, forKey: .crop)
      try crop?.validate()
    }
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(id, forKey: .id)
    try values.encode(filename, forKey: .filename)
    try values.encode(adjustments, forKey: .adjustments)
    try values.encode(orientation, forKey: .orientation)
    try values.encode(crop, forKey: .crop)
    try values.encodeIfPresent(cropOrigin, forKey: .cropOrigin)
    try values.encode(cropNeedsReview, forKey: .cropNeedsReview)
    try values.encode(isMissing, forKey: .isMissing)
    try values.encode(sourceSize, forKey: .sourceSize)
    try values.encode(sourceModified, forKey: .sourceModified)
    try values.encodeIfPresent(rawProcessing, forKey: .rawProcessing)
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

/// Output colorspace/compression are frozen with each export request.
public enum ExportFormat: String, CaseIterable, Sendable {
  case tiff, jpeg
  public var label: String { self == .tiff ? "16-bit TIFF" : "8-bit JPG" }
  public var fileExtension: String { self == .tiff ? "tiff" : "jpg" }
  public var bitsPerSample: Int { self == .tiff ? 16 : 8 }
}

public struct ProjectExportSettings: Codable, Equatable, Sendable {
  public var profile: OutputColorProfile = .displayP3 {
    didSet { profileSHA256 = profile.profileSHA256 }
  }
  public var applyCrop = true
  public var compression: TIFFCompression = .deflate
  public var profileSHA256 = OutputColorProfile.displayP3.profileSHA256
  public var bitsPerSample = 16
  public var format: ExportFormat {
    get { bitsPerSample == 8 ? .jpeg : .tiff }
    set { bitsPerSample = newValue.bitsPerSample }
  }
  public var embedsICC = true
  public var dithering = false
  public var destinationPath: String?
  /// nil follows the current roll name.
  public var filenamePrefix: String?
  public init(profile: OutputColorProfile = .displayP3, compression: TIFFCompression = .deflate) {
    self.profile = profile
    self.compression = compression
    profileSHA256 = profile.profileSHA256
  }

  private enum CodingKeys: String, CodingKey {
    case applyCrop, profile, compression, profileSHA256, bitsPerSample, embedsICC, dithering, destinationPath, filenamePrefix
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let storedProfile: OutputColorProfile?
    if decoder.userInfo[migratingSchemaOne] as? Bool == true {
      guard !values.contains(.profile), !values.contains(.compression) else {
        throw ProjectStoreError.invalidProject("schema 1 含有未定义的输出设置")
      }
      storedProfile = nil
      compression = .none
    } else {
      let rawProfile = try values.decode(String.self, forKey: .profile)
      storedProfile = OutputColorProfile(rawValue: rawProfile)
      compression = try values.decode(TIFFCompression.self, forKey: .compression)
    }
    profile = storedProfile ?? .displayP3
    let storedHash = try values.decode(String.self, forKey: .profileSHA256)
    profileSHA256 = storedProfile == nil ? profile.profileSHA256 : storedHash
    bitsPerSample = try values.decode(Int.self, forKey: .bitsPerSample)
    embedsICC = try values.decode(Bool.self, forKey: .embedsICC)
    dithering = try values.decode(Bool.self, forKey: .dithering)
    applyCrop = try values.decodeIfPresent(Bool.self, forKey: .applyCrop) ?? true
    destinationPath = try values.decodeIfPresent(String.self, forKey: .destinationPath)
    filenamePrefix = try values.decodeIfPresent(String.self, forKey: .filenamePrefix)
  }
}

public struct RollProject: Codable, Sendable {
  public static let currentSchemaVersion = 9

  public var schemaVersion = currentSchemaVersion
  public var algorithmVersion = projectAlgorithmVersion
  public var id = UUID()
  public var name: String?
  public var createdAt = Date()
  public var updatedAt = Date()
  public var assets = ProjectAssetIdentity()
  public var inputInterpretation = ProjectInputInterpretation()
  public var exportSettings = ProjectExportSettings()
  private var storedSprocketWhitening: SprocketWhiteningSettings? = .init()
  public var sprocketWhitening: SprocketWhiteningSettings {
    get { storedSprocketWhitening ?? .init() }
    set { storedSprocketWhitening = newValue }
  }
  public var calibration = FilmCalibration()
  /// Preserves the original calibration while disclosing a missing/replaced sampling source.
  public var calibrationNeedsReview = false
  public var frames: [FrameRecord] = []
  public var lastActiveFrameID: UUID?

  // Session-only source location permits a final target availability check immediately before applying.
  // The optional export destination is a user-selected preference and may need reselection after a move.
  var sourceFolderURL: URL?
  /// Captured in the same coordinated read as the decoded project; never persisted.
  public var loadedModificationDate: Date?

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, algorithmVersion, id, createdAt, updatedAt, assets
    case inputInterpretation, exportSettings, calibration, calibrationNeedsReview
    case frames, lastActiveFrameID, name
    case storedSprocketWhitening = "sprocketWhitening"
  }

  public init() {
    calibration.cmosMatrix = .sonyA7CII
    calibration.matrix = .ledLightSource
    calibration.sampledCMOSMatrix = .sonyA7CII
    calibration.sampledDensityMatrix = .ledLightSource
  }
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

  /// Opens and reconciles a roll without writing anything. preferredFile denotes an original TIFF or RAW, not JSON.
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
            if frame.sourceSize != source.sourceSize || frame.sourceModified != source.sourceModified {
              frame.rawProcessing = nil
            }
            frame.sourceSize = source.sourceSize
            frame.sourceModified = source.sourceModified
          }
          merged[frame.filename] = frame
        }
        project.frames = merged.values.sorted { naturalLess($0.filename, $1.filename) }
        // V1 crop coordinates depended on this frame's user orientation. Resolve
        // available sources before saving/synchronizing; missing or unreadable
        // originals keep their legacy value until they can be located again.
        for index in project.frames.indices where !project.frames[index].isMissing {
          let frame = project.frames[index]
          if !SourceImageIO.isRAW(folder.appendingPathComponent(frame.filename)),
            let crop = frame.crop, crop.geometryVersion == 1,
            let metadata = try? TIFFCodec.metadata(url: folder.appendingPathComponent(frame.filename)) {
            project.frames[index].crop = try crop.sourceCoordinates(sourceWidth: metadata.width,
              sourceHeight: metadata.height, orientation: frame.orientation)
          }
        }
        // Saved film-base values remain valid independently of their source file.
        // Keep decoding the legacy field for existing projects, but retire review state.
        project.calibrationNeedsReview = false
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
          let original = try Data(contentsOf: coordinated)
          let existing = try decode(original)
          guard existing.id == project.id else { throw ProjectStoreError.externalConflict }
          let object = try JSONSerialization.jsonObject(with: original) as? [String: Any]
          let frames = object?["frames"] as? [[String: Any]] ?? []
          if frames.contains(where: { ($0["adjustments"] as? [String: Any])?["cineonLogLUT"] as? String == "neutral" }) {
            let backup = coordinated.deletingLastPathComponent().appendingPathComponent(
              ".printroom-neutral-\(UUID().uuidString).json")
            try original.write(to: backup, options: .withoutOverwriting)
          }
          let header = try JSONDecoder().decode(Header.self, from: original)
          if header.algorithmVersion == legacyAlgorithmVersion {
            // Preserve exact original settings before the first save under the new image behavior.
            // Exclusive creation never overwrites another backup; any failure aborts replacement.
            let backup = coordinated.deletingLastPathComponent().appendingPathComponent(
              ".printroom-density-v1-\(UUID().uuidString).json")
            try original.write(to: backup, options: .withoutOverwriting)
          } else if header.schemaVersion < RollProject.currentSchemaVersion {
            // Older app packages cannot read the current schema. Preserve their exact settings
            // before the first migrated save, with the same conflict/atomicity rules.
            let backup = coordinated.deletingLastPathComponent().appendingPathComponent(
              ".printroom-schema\(header.schemaVersion)-\(UUID().uuidString).json")
            try original.write(to: backup, options: .withoutOverwriting)
          } else if header.algorithmVersion != projectAlgorithmVersion {
            let backup = coordinated.deletingLastPathComponent().appendingPathComponent(
              ".\(header.algorithmVersion)-\(UUID().uuidString).json")
            try original.write(to: backup, options: .withoutOverwriting)
          } else if existing.frames.contains(where: { previous in
            guard previous.crop?.geometryVersion == 1 else { return false }
            return project.frames.first(where: { $0.id == previous.id })?.crop?.geometryVersion != 1
          }) {
            // Geometry v2 changes the coordinate contract while retaining schema
            // 3. Keep the original v1 JSON before its first conversion or removal.
            let backup = coordinated.deletingLastPathComponent().appendingPathComponent(
              ".printroom-geometry-v1-\(UUID().uuidString).json")
            try original.write(to: backup, options: .withoutOverwriting)
          }
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

  /// Explicitly reconnect a missing/renamed photograph to a readable original TIFF or RAW in the same roll.
  /// Stable identity, adjustments and direction remain attached to the old record. Discovery may
  /// already have added the new filename; it is absorbed only if it has no edits/calibration role.
  /// This is a value transaction: the UI may register the whole before/after pair for Undo/Redo.
  public static func relocate(
    _ project: RollProject, frameID: UUID, to sourceURL: URL, folder: URL
  ) throws -> RollProject {
    try validate(project)
    let folder = try validatedFolder(folder)
    guard project.sourceFolderURL == nil || project.sourceFolderURL == folder else {
      throw ProjectStoreError.invalidProject("重新定位必须在当前卷内进行")
    }
    guard sourceURL.isFileURL,
      sourceURL.standardizedFileURL.deletingLastPathComponent().resolvingSymlinksInPath() == folder,
      let index = project.frames.firstIndex(where: { $0.id == frameID })
    else { throw ProjectStoreError.invalidProject("重新定位目标必须是当前卷内的 TIFF 或受支持的 RAW") }
    try validateFilename(sourceURL.lastPathComponent)
    guard let source = sourceRecord(url: sourceURL, folder: folder) else {
      throw ProjectStoreError.unavailableFrame(sourceURL.lastPathComponent)
    }
    // Reconnection verifies decoded source metadata (Adobe for RAW). Callers perform this
    // transaction off the main thread. Discovery itself never launches RAW preparation.
    let metadata = try SourceImageIO.metadata(url: sourceURL)
    var updated = project
    let previous = project.frames[index]
    if previous.filename != source.filename,
      sourceRecord(url: folder.appendingPathComponent(previous.filename), folder: folder) != nil
    {
      throw ProjectStoreError.invalidProject("原照片仍然可读取，不能将其设置重新关联到另一照片")
    }
    if let collision = project.frames.first(where: { $0.filename == source.filename && $0.id != frameID }) {
      guard collision.adjustments == FrameAdjustments(), collision.orientation == .identity,
        collision.crop == nil, collision.cropOrigin == nil, !collision.cropNeedsReview,
        project.calibration.sourceFrameID != collision.id
      else {
        throw ProjectStoreError.invalidProject("目标照片已有调色、方向、裁剪或片基来源设置，不能合并")
      }
      updated.frames.removeAll { $0.id == collision.id }
      if updated.lastActiveFrameID == collision.id { updated.lastActiveFrameID = frameID }
    }
    var reconnected = previous
    reconnected.filename = source.filename
    reconnected.sourceSize = source.sourceSize
    reconnected.sourceModified = source.sourceModified
    reconnected.isMissing = false
    reconnected.rawProcessing = try SourceImageIO.processingIdentity(url: sourceURL)
    guard let verifiedSource = sourceRecord(url: sourceURL, folder: folder),
      verifiedSource.sourceSize == source.sourceSize, verifiedSource.sourceModified == source.sourceModified
    else { throw ProjectStoreError.unavailableFrame(sourceURL.lastPathComponent) }
    if let crop = reconnected.crop, crop.geometryVersion == 1 {
      reconnected.crop = try crop.sourceCoordinates(sourceWidth: metadata.width,
        sourceHeight: metadata.height, orientation: reconnected.orientation)
    }
    updated.frames[updated.frames.firstIndex(where: { $0.id == frameID })!] = reconnected
    updated.frames.sort { naturalLess($0.filename, $1.filename) }
    updated.sourceFolderURL = folder
    updated.calibrationNeedsReview = false
    try validate(updated)
    return updated
  }

  private struct Header: Decodable {
    var schemaVersion: Int
    var algorithmVersion: String
  }

  private static func decode(_ data: Data) throws -> RollProject {
    do {
      let decoder = JSONDecoder()
      let header = try decoder.decode(Header.self, from: data)
      guard [1, 2, 3, 4, 5, 6, 7, 8, RollProject.currentSchemaVersion].contains(header.schemaVersion) else {
        throw ProjectStoreError.unsupportedSchema(header.schemaVersion)
      }
      guard [legacyAlgorithmVersion, "printroom-density-v2", "printroom-density-v3", "printroom-density-v4", "printroom-density-v5", projectAlgorithmVersion].contains(header.algorithmVersion) else {
        throw ProjectStoreError.incompatibleAlgorithm(header.algorithmVersion)
      }
      decoder.userInfo[migratingLegacyMatrices] = header.schemaVersion < 4
      decoder.userInfo[migratingSchemaOne] = header.schemaVersion == 1
      decoder.userInfo[migratingLegacyCrop] = header.schemaVersion < 3
      var project = try decoder.decode(RollProject.self, from: data)
      project.schemaVersion = RollProject.currentSchemaVersion
      project.algorithmVersion = projectAlgorithmVersion
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
      project.exportSettings.profileSHA256 == project.exportSettings.profile.profileSHA256,
      [8, 16].contains(project.exportSettings.bitsPerSample), project.exportSettings.embedsICC,
      !project.exportSettings.dithering
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
      if let identity = frame.rawProcessing {
        guard SourceImageIO.isRAW(URL(fileURLWithPath: frame.filename)),
          !identity.sourceRevision.isEmpty, !identity.adobeVersion.isEmpty,
          !identity.libRawVersion.isEmpty, !identity.strategyVersion.isEmpty,
          !identity.proxySamplingVersion.isEmpty
        else { throw ProjectStoreError.invalidProject("RAW 处理身份无效") }
      }
      try validateAdjustments(frame.adjustments)
      try frame.crop?.validate()
    }
    if let active = project.lastActiveFrameID, !ids.contains(active) {
      throw ProjectStoreError.invalidProject("当前照片 ID 不属于项目")
    }
    do { try project.sprocketWhitening.validate() } catch {
      throw ProjectStoreError.invalidProject(error.localizedDescription)
    }
    try validateCalibration(project.calibration, frameIDs: ids)
  }

  private static func validateFilename(_ name: String) throws {
    guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
      !name.contains("\0"), isSupportedSource(name)
    else {
      throw ProjectStoreError.invalidProject("必须使用卷内 TIFF 或受支持的 RAW 相对文件名")
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
    guard finite(base), (0..<3).allSatisfy({ base[$0] > 0 }),
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
    let expectedOffset = try Pipeline.recalibrate(expected, matrix: calibration.sampledDensityMatrix)
      .filmBaseOffsetCV
    guard (0..<3).allSatisfy({ abs(calibration.filmBaseOffsetCV[$0] - expectedOffset[$0]) <= 0.01 })
    else {
      throw ProjectStoreError.invalidProject("片基 offset 与上次采样数据或当时的矩阵不一致")
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

  private static func isSupportedSource(_ name: String) -> Bool {
    SourceImageIO.isSupportedSource(URL(fileURLWithPath: name))
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
    return urls.filter { !$0.lastPathComponent.hasPrefix(".") && isSupportedSource($0.lastPathComponent) }.compactMap { url in
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
    // Modified clicks only edit the batch target set. Keep the preview/editing
    // source and the ordinary-click range anchor fixed, including crop drafts.
    if (command || shift), let activeFrameID {
      if shift {
        let anchorIndex = ordered.firstIndex(of: anchorID ?? activeFrameID)
          ?? ordered.firstIndex(of: activeFrameID)!
        let range = Set(ordered[min(anchorIndex, clickedIndex)...max(anchorIndex, clickedIndex)])
        selectedFrameIDs = command ? selectedFrameIDs.union(range) : range
        selectedFrameIDs.insert(activeFrameID)
      } else if id != activeFrameID {
        if selectedFrameIDs.contains(id) { selectedFrameIDs.remove(id) }
        else { selectedFrameIDs.insert(id) }
      }
      return
    }
    selectedFrameIDs = [id]
    activeFrameID = id
    anchorID = id
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
    formatVersion: Int = currentFormatVersion, algorithmVersion: String = "printroom-density-v6",
    pivotCV: Int = contrastPivotCV
  ) {
    self.sourceID = sourceID
    self.sourceName = sourceName
    self.adjustments = adjustments
    self.formatVersion = formatVersion
    self.algorithmVersion = algorithmVersion
    self.pivotCV = pivotCV
  }

  /// Value semantics form one reversible transaction. The UI registers before/after with UndoManager.
  public func applying(to project: RollProject, targets: Set<UUID>,
    timing: Bool = true, contrast: Bool = true, lut: Bool = true
  ) throws -> RollProject {
    guard formatVersion == Self.currentFormatVersion, algorithmVersion == projectAlgorithmVersion,
      pivotCV == contrastPivotCV
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
      if timing { updated.frames[index].adjustments.timing = adjustments.timing }
      if contrast { updated.frames[index].adjustments.contrast = adjustments.contrast }
      if lut { updated.frames[index].adjustments.cineonLogLUT = adjustments.cineonLogLUT }
    }
    return updated
  }
}
