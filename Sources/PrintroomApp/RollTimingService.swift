import Foundation
import PrintroomCore

struct RollTimingResult: Sendable {
  let timing: TimingParameters
  let sources: [SourceStamp]
  var masters: [UUID: Int] = [:]
}

enum RollTimingService {
  static func run(project: RollProject, folder: URL, assets: AppAssets, autoExposure: Bool = false,
                  progress: @escaping @Sendable (String) async -> Void) async throws -> RollTimingResult {
    let worker = Task.detached(priority: .userInitiated) {
      guard let firstFrame = project.frames.first else {
        throw PrintroomError.invalid("胶卷没有照片，无法分析色罩。")
      }
      // Use roll order, including a missing first frame's stored LUT selection.
      let lut = assets.lut(for: firstFrame.adjustments.cineonLogLUT)
      let frames = project.frames.filter { !$0.isMissing }
      var samples: [RollTiming.Frame] = [], sources: [SourceStamp] = []
      for (i, frame) in frames.enumerated() {
        try Task.checkCancellation()
        await progress("分析 \(i + 1)/\(frames.count)")
        let url = folder.appendingPathComponent(frame.filename)
        let stamp = try SourceStamp(url: url)
        let metadata = try SourceImageIO.metadata(url: url)
        let image = try SourceImageIO.readPreview(url: url, maxDimension: 1600)
        let geometry = try CropGeometry(crop: frame.crop, sourceWidth: metadata.width,
          sourceHeight: metadata.height, orientation: frame.orientation)
        let cropped = try geometry.render(image.preview(maxDimension: 1600), maxDimension: 1600, cancelled: { Task.isCancelled })
        samples.append(RollTiming.Frame(densityCV: try RollTiming.samples(cropped,
          calibration: project.calibration), lut: lut))
        guard try SourceStamp(url: url) == stamp else {
          throw PrintroomError.invalid("分析期间照片已改变，请重新分析。")
        }
        sources.append(stamp)
      }
      await progress("正在计算…")
      let timing = try RollTiming.solve(samples, profile: assets.profile)
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
      return RollTimingResult(timing: timing, sources: sources, masters: masters)
    }
    return try await withTaskCancellationHandler(operation: { try await worker.value },
      onCancel: { worker.cancel() })
  }
}
