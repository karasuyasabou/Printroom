import Foundation
import PrintroomCore

struct AutoCropInput: Sendable {
  let id: UUID
  let url: URL
}
struct AutoCropOutput: Sendable {
  let id: UUID
  let crop: FrameCrop
  let needsReview: Bool
  let source: SourceStamp
}
enum AutoCropService {
  /// Retain target density maps up to 128 MiB, releasing each after fitting.
  /// Long rolls fall back to seed-only reanalysis; RAW uses preview proxies only.
  static func run(inputs: [AutoCropInput], targets: Set<UUID>, aspectRatio: Double,
                  analysisCacheByteLimit: Int = 128 * 1024 * 1024,
                  progress: @escaping @Sendable (String) async -> Void) async throws -> [AutoCropOutput] {
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
        let image = try PerformanceTrace.measure("autocrop.read.first") {
          try SourceImageIO.readPreview(url: input.url, maxDimension: 1600)
        }
        let metadata = try SourceImageIO.metadata(url: input.url)
        let analysis = try AutoCropAnalyzer.prepare(image,
          sourceWidth: metadata.width, sourceHeight: metadata.height)
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
          analysis = try PerformanceTrace.measure("autocrop.second") {
            let image = try PerformanceTrace.measure("autocrop.read.second") {
              try SourceImageIO.readPreview(url: input.url, maxDimension: 1600)
            }
            return try AutoCropAnalyzer.prepare(image, seed: seeds[index],
              sourceWidth: metadata.width, sourceHeight: metadata.height)
          }
        }
        let fit = try AutoCropAnalyzer.fit(analysis, template: template,
          sourceWidth: metadata.width, sourceHeight: metadata.height,
          requiresAllEdges: index == inputs.startIndex || index == inputs.index(before: inputs.endIndex))
        guard try SourceStamp(url: input.url) == stamps[index] else {
          throw PrintroomError.invalid("自动裁剪期间源照片已改变：\(input.url.lastPathComponent)")
        }
        result.append(AutoCropOutput(id: input.id, crop: fit.crop,
          needsReview: fit.needsReview, source: stamps[index]))
      }
      try Task.checkCancellation()
      // Recheck all contributors: changing even a template-only frame invalidates this run.
      for stamp in stamps where try SourceStamp(url: stamp.url) != stamp {
        throw PrintroomError.invalid("自动裁剪期间源照片已改变：\(stamp.url.lastPathComponent)")
      }
      return result
    }
    return try await withTaskCancellationHandler(operation: { try await worker.value },
                                                onCancel: { worker.cancel() })
  }
}
