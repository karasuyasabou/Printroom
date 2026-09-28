import Foundation
import PrintroomCore
import Testing
@testable import PrintroomApp

@Suite(.serialized) @MainActor
struct RollTimingEditingTests {
  private func wait(_ ready: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(12))
    while !ready(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    try #require(ready())
  }
  private func fixture() async throws -> (EditorModel, URL) {
    let model = EditorModel()
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RollTiming-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for i in 0..<3 {
      try TIFFCodec.write(url: folder.appendingPathComponent("\(i).tif"), width: 32, height: 32,
        profile: #require(model.assets).profile) { [UInt16](repeating: 22000, count: $0.count * 32 * 3) }
    }
    var p = try ProjectStore.open(folder: folder)
    p.calibration = FilmCalibration()
    try ProjectStore.save(p, folder: folder, expectedModification: nil)
    model.open(folder)
    try await wait { model.hasImage && !model.isRendering }
    #expect(!model.canStartRollTiming)
    model.sampleBase(.init(x: 0,y: 0,width: 4,height: 4))
    try await wait { model.project?.calibration.isCalibrated == true && !model.isRendering }
    model.rollTimingRunner = { p, folder, _, progress in
      await progress("分析完成")
      return RollTimingResult(timing: .init(red: 35,green: 25,blue: 15),
        sources: try p.frames.filter { !$0.isMissing }.map { try AutoCropSourceStamp(folder.appendingPathComponent($0.filename)) })
    }
    return (model, folder)
  }
  @Test func applyAllIsOneUndoAndPersists() async throws {
    let (model, folder) = try await fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    model.project?.frames[0].adjustments.cineonLogLUT = .fujifilm3513DI
    model.project?.frames[0].adjustments.timing.master = 20
    model.project?.frames[1].adjustments.contrast.red = 1.2
    let old = try #require(model.project)
    model.startRollTiming()
    try await wait { !model.isAnalyzingRollTiming }
    #expect(model.showRollTimingDialog)
    #expect(model.project?.frames == old.frames)
    model.applyRollTiming(preserveEdited: false)
    let updated = try #require(model.project)
    #expect(updated.frames.allSatisfy { $0.adjustments.timing == .init(red: 35,green: 25,blue: 15) && $0.adjustments.contrast == .init() && $0.adjustments.cineonLogLUT == .fujifilm3513DI })
    #expect(model.flushSave())
    #expect(try ProjectStore.open(folder: folder).frames == updated.frames)
    model.undo()
    #expect(model.project?.frames == old.frames)
    model.redo()
    #expect(model.project?.frames == updated.frames)
  }
  @Test func preserveOnlyTimingAndContrastEdits() async throws {
    let (model, folder) = try await fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    model.project?.frames[0].adjustments.timing.red = 1
    model.project?.frames[1].adjustments.contrast.master = 1.1
    model.project?.frames[2].adjustments.cineonLogLUT = .fujifilm3513DI
    let old = try #require(model.project)
    model.startRollTiming(); try await wait { !model.isAnalyzingRollTiming }
    model.applyRollTiming(preserveEdited: true)
    #expect(model.project?.frames[0] == old.frames[0])
    #expect(model.project?.frames[1] == old.frames[1])
    #expect(model.project?.frames[2].adjustments.timing.red == 35)
    #expect(model.project?.frames[2].adjustments.cineonLogLUT == old.frames[0].adjustments.cineonLogLUT)
  }
  @Test func cancellationAndStaleResultDoNotWrite() async throws {
    let (model, folder) = try await fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let old = try #require(model.project)
    model.startRollTiming(); model.cancelRollTiming()
    try await Task.sleep(for: .milliseconds(100))
    #expect(!model.showRollTimingDialog)
    #expect(model.project?.frames == old.frames)
    model.startRollTiming(); try await wait { !model.isAnalyzingRollTiming }
    model.project?.frames[0].adjustments.timing.red = 8
    let changed = model.project?.frames
    model.applyRollTiming(preserveEdited: false)
    #expect(model.rollTimingError != nil)
    #expect(model.project?.frames == changed)
  }
  @Test func calibrationReviewAndMatrixMismatchDisableEntry() async throws {
    let (model, folder) = try await fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    #expect(model.canStartRollTiming)
    model.project?.calibrationNeedsReview = true
    #expect(!model.canStartRollTiming)
    model.project?.calibrationNeedsReview = false
    model.project?.calibration.matrix = .ledLightSource
    #expect(!model.canStartRollTiming)
  }
  @Test func changedSourceCannotBeApplied() async throws {
    let (model, folder) = try await fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    model.startRollTiming(); try await wait { !model.isAnalyzingRollTiming }
    let old = model.project?.frames
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)],
      ofItemAtPath: folder.appendingPathComponent("1.tif").path)
    model.applyRollTiming(preserveEdited: false)
    #expect(model.rollTimingError != nil)
    #expect(model.project?.frames == old)
  }
  @Test func serviceUsesCropAndIgnoresExistingAdjustments() async throws {
    let model = EditorModel()
    let assets = try #require(model.assets)
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RollTimingService-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("crop.tif")
    var raw: [UInt16] = []
    for y in 0..<100 { for x in 0..<100 {
      raw += [UInt16](repeating: (25..<75).contains(x) && (25..<75).contains(y) ? 6554 : 49151, count: 3)
    } }
    try TIFFCodec.write(url: url, width: 100,height: 100,profile: assets.profile) { rows in
      Array(raw[(rows.lowerBound * 300)..<(rows.upperBound * 300)])
    }
    var p = try ProjectStore.open(folder: folder)
    p.calibration = try Pipeline.calibrate(image: LinearImage(width: 100,height: 100,samples: raw),
      rect: .init(x: 0,y: 0,width: 4,height: 4), matrix: .identity, sourceFrameID: p.frames[0].id)
    p.frames[0].crop = FrameCrop(aspect: .free, width: 0.5, freeRatio: 1)
    let result = try await RollTimingService.run(project: p, folder: folder, assets: assets) { _ in }
    // Independent density from the crop interior, including calibrated 95 CV base.
    let cv = 95 - 500 * log10(Double(6554) / Double(49151))
    let t = result.timing
    #expect(abs(cv + Double(t.red+t.green+t.blue)/3 - 685) <= 1.0/6 + 0.001)
    p.frames[0].adjustments.timing.master = 99
    p.frames[0].adjustments.contrast.red = 1.5
    let again = try await RollTimingService.run(project: p, folder: folder, assets: assets) { _ in }
    #expect(again.timing == t)
    #expect(result.sources.count == 1)
  }

  @Test func mixedLUTAnalysisUsesFirstFrameEvenWhenMissing() async throws {
    let (model, folder) = try await fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let assets = try #require(model.assets)
    var p = try #require(model.project)
    // An asymmetric, non-white sample makes the two film LUTs produce distinct timing.
    for frame in p.frames {
      try FileManager.default.removeItem(at: folder.appendingPathComponent(frame.filename))
      try TIFFCodec.write(url: folder.appendingPathComponent(frame.filename), width: 32, height: 32,
        profile: assets.profile) { rows in
          (0..<(rows.count * 32)).flatMap { index -> [UInt16] in
            let scale = (index % 4) + 1
            return [UInt16(5000 * scale), UInt16(7000 * scale), UInt16(9000 * scale)]
          }
        }
    }
    p.frames[0].adjustments.cineonLogLUT = .fujifilm3513DI
    let mixed = try await RollTimingService.run(project: p, folder: folder, assets: assets) { _ in }
    for i in p.frames.indices { p.frames[i].adjustments.cineonLogLUT = .fujifilm3513DI }
    let uniform = try await RollTimingService.run(project: p, folder: folder, assets: assets) { _ in }
    #expect(mixed.timing == uniform.timing)
    for i in p.frames.indices { p.frames[i].adjustments.cineonLogLUT = .kodak2383 }
    let kodak = try await RollTimingService.run(project: p, folder: folder, assets: assets) { _ in }
    #expect(kodak.timing != uniform.timing)
    p.frames[0].adjustments.cineonLogLUT = .fujifilm3513DI
    p.frames[0].isMissing = true
    let missing = try await RollTimingService.run(project: p, folder: folder, assets: assets) { _ in }
    #expect(missing.timing == uniform.timing)
    #expect(missing.sources.count == 2)
  }

}
