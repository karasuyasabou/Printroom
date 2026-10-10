import Foundation
import PrintroomCore

/// Builds a complete value transaction without publishing edits, undo or save state.
/// Geometry is supplied by the editor's already validated preparation snapshot.
enum BatchEditTransaction {
  struct SyncOptions {
    let timing: Bool
    let contrast: Bool
    let lut: Bool
    let crop: Bool
  }

  static func synchronize(project: RollProject, source: FrameRecord, targets: Set<UUID>,
    folder: URL, options: SyncOptions, metadata: (URL) throws -> TIFFMetadata
  ) throws -> RollProject {
    guard targets.isSubset(of: Set(project.frames.filter { !$0.isMissing }.map(\.id))),
      !source.isMissing else { throw PrintroomError.invalid("同步包含不可用照片") }
    var crop: FrameCrop?
    if options.crop, let savedCrop = source.crop {
      let dimensions = try metadata(folder.appendingPathComponent(source.filename))
      crop = try savedCrop.sourceCoordinates(sourceWidth: dimensions.width,
        sourceHeight: dimensions.height, orientation: source.orientation)
    }
    var next = project
    if options.timing || options.contrast || options.lut {
      next = try ParameterSnapshot(frame: source).applying(to: project, targets: targets,
        timing: options.timing, contrast: options.contrast, lut: options.lut)
    }
    for index in next.frames.indices where targets.contains(next.frames[index].id) {
      let url = folder.appendingPathComponent(next.frames[index].filename)
      try requireSource(url)
      if options.crop {
        let dimensions = try metadata(url)
        try next.frames[index].applyManualCrop(crop,
          sourceWidth: dimensions.width, sourceHeight: dimensions.height)
      }
    }
    return next
  }

  static func applying(_ snapshot: ParameterSnapshot, to project: RollProject,
    targets: Set<UUID>, folder: URL
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
