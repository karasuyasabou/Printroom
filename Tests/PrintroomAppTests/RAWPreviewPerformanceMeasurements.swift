import Foundation
import PrintroomCore
import Testing
@testable import PrintroomApp

@Suite(.serialized)
struct RAWPreviewPerformanceMeasurements {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["PRINTROOM_RAW_MEASURE_ROLL"] != nil))
  func measureCachedFrames() async throws {
    let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PRINTROOM_RAW_MEASURE_ROLL"]!)
    let project = try JSONDecoder().decode(RollProject.self, from: Data(contentsOf: folder.appendingPathComponent(".printroom.json")))
    let assets = try AppAssets()
    let renderer = PreviewRenderService()
    let service = ImageService()
    func ms(_ start: Date) -> Double { Date().timeIntervalSince(start) * 1000 }
    let background = ProcessInfo.processInfo.environment["PRINTROOM_RAW_MEASURE_BACKGROUND"] == "1"
    let prewarm = Task {
      if background { await SourcePrewarmer.prepare(project.frames.map { folder.appendingPathComponent($0.filename) }) }
    }
    defer { prewarm.cancel() }
    for frame in project.frames.prefix(6) {
      let url = folder.appendingPathComponent(frame.filename)
      var start = Date()
      let preview = try await service.preview(url)
      let read = ms(start)
      start = Date()
      _ = try await renderer.render(preview.0, calibration: project.calibration,
        adjustments: frame.adjustments, assets: assets, orientation: frame.orientation,
        inputIdentity: UUID(), crop: frame.crop, sourceWidth: preview.1,
        sourceHeight: preview.2, includeHistogram: true)
      let render = ms(start)
      print("RAW_FRAME \(frame.filename) read_ms=\(read) render_ms=\(render)")
    }
  }
}
