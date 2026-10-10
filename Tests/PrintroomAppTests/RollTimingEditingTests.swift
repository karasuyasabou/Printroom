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
    try await waitForProxyImport(model)
    try await wait { model.hasImage && !model.isRendering }
    #expect(!model.canStartRollTiming)
    model.sampleBase(.init(x: 0,y: 0,width: 4,height: 4))
    try await wait { model.project?.calibration.isCalibrated == true && !model.isRendering }
    model.rollTimingRunner = { p, folder, _, _, progress in
      await progress("分析完成")
      return RollTimingResult(timing: .init(red: 35,green: 25,blue: 15),
        sources: try p.frames.filter { !$0.isMissing }.map { try SourceStamp(url: folder.appendingPathComponent($0.filename)) })
    }
    return (model, folder)
  }
  @Test func perFrameExposurePersistsAndUndoesTogether() async throws {
    let (model, folder) = try await fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    model.rollTimingRunner = { p, folder, _, autoExposure, _ in
      #expect(autoExposure)
      return RollTimingResult(timing: .init(red: 35, green: 25, blue: 15),
        sources: try p.frames.map { try SourceStamp(url: folder.appendingPathComponent($0.filename)) },
        masters: Dictionary(uniqueKeysWithValues: p.frames.enumerated().map { ($0.element.id, $0.offset * 100) }))
    }
    let old = try #require(model.project)
    model.startRollTiming(autoExposure: true)
    try await wait { !model.isAnalyzingRollTiming }
    #expect(model.project?.frames == old.frames)
    model.applyRollTiming(preserveEdited: false)
    let next = try #require(model.project)
    #expect(next.frames.map { $0.adjustments.timing.master } == [0, 100, 200])
    #expect(next.frames.allSatisfy { $0.adjustments.timing.red == 35 })
    #expect(model.flushSave())
    #expect(try ProjectStore.open(folder: folder).frames == next.frames)
    model.undo(); #expect(model.project?.frames == old.frames)
    model.redo(); #expect(model.project?.frames == next.frames)
    // A second run with preservation must protect every edited frame including Master.
    model.startRollTiming(autoExposure: true)
    try await wait { !model.isAnalyzingRollTiming }
    model.applyRollTiming(preserveEdited: true)
    #expect(model.project?.frames == next.frames)

  }

  @Test func serviceMatchesExposureToFrameIDsAndSkipsMissingFrames() async throws {
    let (model, folder) = try await fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let assets = try #require(model.assets)
    var p = try #require(model.project)
    p.frames.append(FrameRecord(filename: "3.tif"))
    let levels: [UInt16] = [22000, 11000, 5500, 44000]
    for (i, frame) in p.frames.enumerated() {
      let url = folder.appendingPathComponent(frame.filename)
      if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
      try TIFFCodec.write(url: url, width: 32, height: 32, profile: assets.profile) {
        [UInt16](repeating: levels[i], count: $0.count * 32 * 3)
      }
    }
    // A missing middle frame must not shift the last frame's result to its ID.
    p.frames[1].isMissing = true
    let result = try await RollTimingService.run(project: p, folder: folder, assets: assets, autoExposure: true) { _ in }
    let plain = try await RollTimingService.run(project: p, folder: folder, assets: assets) { _ in }
    #expect(result.timing == plain.timing)
    #expect(result.masters.count == 3)
    #expect(result.masters[p.frames[1].id] == nil)
    let t = result.timing
    let shift = Double(t.red + t.green + t.blue) / 3
    for i in [0, 2, 3] {
      let cv = 95 - 500 * log10(Double(levels[i]) / 22000)
      let expected = Int(min(512, max(0, (685 - cv - shift).rounded())))
      #expect(result.masters[p.frames[i].id] == expected)
    }
  }

  @Test func incompleteExposureCannotPartiallyApply() async throws {
    let (model, folder) = try await fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let old = model.project?.frames
    model.startRollTiming(autoExposure: true)
    try await wait { !model.isAnalyzingRollTiming }
    model.applyRollTiming(preserveEdited: false)
    #expect(model.rollTimingError != nil)
    #expect(model.project?.frames == old)
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
  @Test func savedCalibrationIgnoresLegacyReviewButMatrixMismatchDisablesEntry() async throws {
    let (model, folder) = try await fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    #expect(model.canStartRollTiming)
    model.project?.calibrationNeedsReview = true
    #expect(model.canStartRollTiming)
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
    try FileManager.default.copyItem(at: url, to: folder.appendingPathComponent("first.tif"))
    try FileManager.default.copyItem(at: url, to: folder.appendingPathComponent("last.tif"))
    var p = try ProjectStore.open(folder: folder)
    // Keep crop.tif as the middle frame independently of filename sorting.
    p.frames.sort { ["first.tif", "crop.tif", "last.tif"].firstIndex(of: $0.filename)! < ["first.tif", "crop.tif", "last.tif"].firstIndex(of: $1.filename)! }
    p.calibration = try Pipeline.calibrate(image: LinearImage(width: 100,height: 100,samples: raw),
      rect: .init(x: 0,y: 0,width: 4,height: 4), matrix: .identity, sourceFrameID: p.frames[0].id)
    p.frames[1].crop = FrameCrop(aspect: .free, width: 0.5, freeRatio: 1)
    let result = try await RollTimingService.run(project: p, folder: folder, assets: assets) { _ in }
    // Independent density from the crop interior, including calibrated 95 CV base.
    let cv = 95 - 500 * log10(Double(6554) / Double(49151))
    let t = result.timing
    #expect(abs(cv + Double(t.red+t.green+t.blue)/3 - 685) <= 1.0/6 + 0.001)
    p.frames[1].adjustments.timing.master = 99
    p.frames[1].adjustments.contrast.red = 1.5
    let again = try await RollTimingService.run(project: p, folder: folder, assets: assets) { _ in }
    #expect(again.timing == t)
    let exposed = try await RollTimingService.run(project: p, folder: folder, assets: assets, autoExposure: true) { _ in }
    #expect(exposed.timing == t)
    #expect(exposed.masters[p.frames[1].id] == 0)
    #expect(result.masters.isEmpty)
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
    #expect(missing.sources.count == 1)
  }

  @Test func unstableRollEndsDoNotChangeSharedTiming() async throws {
    let (model, folder) = try await fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let assets = try #require(model.assets)
    let p = try #require(model.project)
    let middleURL = folder.appendingPathComponent(p.frames[1].filename)
    try FileManager.default.removeItem(at: middleURL)
    try TIFFCodec.write(url: middleURL, width: 32, height: 32, profile: assets.profile) {
      [UInt16](repeating: 11000, count: $0.count * 32 * 3)
    }
    let baseline = try await RollTimingService.run(project: p, folder: folder, assets: assets) { _ in }
    for (index, rgb) in [(0, [UInt16(2000), 10000, 30000]), (2, [UInt16(45000), 25000, 8000])] {
      let url = folder.appendingPathComponent(p.frames[index].filename)
      try FileManager.default.removeItem(at: url)
      try TIFFCodec.write(url: url, width: 32, height: 32, profile: assets.profile) { rows in
        (0..<(rows.count * 32)).flatMap { _ in rgb }
      }
    }
    let plain = try await RollTimingService.run(project: p, folder: folder, assets: assets) { _ in }
    let exposed = try await RollTimingService.run(project: p, folder: folder, assets: assets, autoExposure: true) { _ in }
    #expect(plain.timing == baseline.timing)
    #expect(exposed.timing == baseline.timing)
    #expect(plain.sources.map { $0.url.lastPathComponent } == [p.frames[1].filename])
    #expect(Set(exposed.masters.keys) == Set(p.frames.map(\.id)))
    #expect(exposed.sources.count == 3)
  }

  @Test func noInteriorFramesFailsWithoutFallbackToRollEnds() async throws {
    let (model, folder) = try await fixture()
    defer { try? FileManager.default.removeItem(at: folder) }
    let assets = try #require(model.assets)
    let p = try #require(model.project)
    for count in 0...2 {
      var short = p
      short.frames = Array(p.frames.prefix(count))
      do {
        _ = try await RollTimingService.run(project: short, folder: folder, assets: assets) { _ in }
        Issue.record("A roll with fewer than three frames must fail analysis")
      } catch { #expect(error is PrintroomError) }
    }
    var missing = p
    missing.frames[1].isMissing = true
    for autoExposure in [false, true] {
      do {
        _ = try await RollTimingService.run(project: missing, folder: folder, assets: assets, autoExposure: autoExposure) { _ in }
        Issue.record("Missing interior frames must not make roll ends contribute")
      } catch { #expect(error.localizedDescription.contains("跳过首尾张")) }
    }
  }

}
