import AppKit
import Foundation
import ImageIO
import PrintroomCore
import Testing

@testable import PrintroomApp

@Suite(.serialized) @MainActor
struct EditorIntegrationTests {
  private func unwrap<T>(_ value: T?, _ message: String = "") throws -> T { try #require(value) }
  @Test(.enabled(if: ProcessInfo.processInfo.environment["PRINTROOM_VALIDATE_ASSETS"] == "1"))
  func testFullResolutionReferencePipelineExport() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let source = root.appendingPathComponent("TEST/DSC07079.tiff")
    let destination = FileManager.default.temporaryDirectory.appendingPathComponent(
      "PrintroomFullPipeline-\(UUID().uuidString).tiff")
    defer { try? FileManager.default.removeItem(at: destination) }
    let assets = try AppAssets()
    let service = ImageService()
    let raw = try await service.load(source)
    let calibration = try Pipeline.calibrate(
      image: raw, rect: PixelRect(x: 359, y: 604, width: 79, height: 494), matrix: .ledLightSource,
      sourceFrameID: nil)
    let adjustments = FrameAdjustments(
      timing: .init(master: 30, red: 5, green: -3, blue: 7),
      contrast: .init(master: 1.05, red: 0.95, green: 1.02, blue: 1.1))
    let started = ContinuousClock.now
    try await service.export(
      source: source, destination: destination, calibration: calibration, adjustments: adjustments,
      assets: assets
    ) { _ in }
    let elapsed = started.duration(to: .now)
    let result = try TIFFCodec.read(url: destination)
    #expect(result.width == 7008 && result.height == 4672)
    #expect(result.embeddedProfileName == "P3 D65 Gamma 2.6")
    var maxError: Float = 0
    for i in stride(from: 0, to: raw.width * raw.height, by: 32003) {
      let reference = try Pipeline.process(
        raw.pixel(x: i % raw.width, y: i / raw.width), calibration: calibration,
        adjustments: adjustments, lut: assets.lut)
      for c in 0..<3 {
        let difference = abs(Float(result.samples[i * 3 + c]) / 65535 - reference[c])
        maxError = max(maxError, difference)
        #expect(difference <= 2e-4 + 0.5 / 65535)
      }
    }
    let imageSource = try unwrap(CGImageSourceCreateWithURL(destination as CFURL, nil))
    let image = try unwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
    #expect(image.bitsPerComponent == 16)
    #expect(image.colorSpace?.copyICCData() as Data? == assets.profile)
    print(
      "Full reference pipeline export: 7008×4672, \(elapsed), sampled CPU comparison max \(maxError), ICC bytes exact"
    )
  }
  @Test func testExternalConflictCanRestoreBackupAndReloadWithoutLosingSilentChanges() async throws
  {
    let model = EditorModel()
    let assets = try AppAssets()
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "PrintroomRecovery-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try TIFFCodec.write(
      url: folder.appendingPathComponent("Frame.tiff"), width: 4, height: 4, profile: assets.profile
    ) { r in Array(repeating: UInt16(32768), count: r.count * 12) }
    model.open(folder)
    model.edit { $0.timing.master = 41 }
    let backup = try JSONEncoder().encode(try unwrap(model.project))
    var external = try ProjectStore.open(folder: folder, preferredFile: nil)
    let loadedToken = external.loadedModificationDate
    external.frames[0].adjustments.timing.master = 89
    _ = try ProjectStore.save(external, folder: folder, expectedModification: loadedToken)
    #expect(model.flushSave() == false)
    #expect(model.dirty && model.saveFailure)
    #expect(
      try ProjectStore.open(folder: folder, preferredFile: nil).frames[0].adjustments.timing.master
        == 89)
    try model.restoreBackup(data: backup)
    #expect(model.adjustments.timing.master == 41)
    #expect(!model.dirty && !model.saveFailure)
    model.edit { $0.timing.master = 52 }
    model.reloadDiscardingUnsaved()
    #expect(model.adjustments.timing.master == 41)
    #expect(!model.dirty)
    try await Task.sleep(for: .milliseconds(300))
  }
  @Test func testRawCacheInvalidatesWhenSourceIsReplaced() async throws {
    let service = ImageService()
    let assets = try AppAssets()
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "PrintroomCache-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("source.tiff")
    try TIFFCodec.write(url: url, width: 4, height: 4, profile: assets.profile) { r in
      Array(repeating: UInt16(12345), count: r.count * 12)
    }
    #expect(try await service.load(url).samples[0] == 12345)
    try FileManager.default.removeItem(at: url)
    try TIFFCodec.write(url: url, width: 5, height: 4, profile: assets.profile) { r in
      Array(repeating: UInt16(54321), count: r.count * 15)
    }
    let updated = try await service.load(url)
    #expect(updated.width == 5 && updated.samples[0] == 54321)
  }
  @Test func testCopyApplyUndoRedoAndReopenKeepDistinctFrameValues() async throws {
    let model = EditorModel()
    let assets = try unwrap(model.assets, model.errorMessage ?? "Missing assets")
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "PrintroomEditor-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    for i in 1...3 {
      try TIFFCodec.write(
        url: folder.appendingPathComponent("Frame\(i).tiff"), width: 4, height: 4,
        profile: assets.profile
      ) { r in Array(repeating: UInt16(32768), count: r.count * 4 * 3) }
    }
    model.open(folder)
    #expect((model.errorMessage) == nil)
    let frames = try unwrap(model.project?.frames)
    model.edit {
      $0.timing.master = 12
      $0.contrast.red = 1.2
    }
    model.copyParameters()
    model.edit { $0.timing.master = 77 }
    model.select(frames[1].id)
    model.edit { $0.timing.blue = -19 }
    model.select(frames[2].id)
    model.edit { $0.contrast.master = 0.75 }
    model.select(frames[1].id)
    model.select(frames[2].id, command: true)
    let before = try unwrap(model.project)
    model.applyParameters()
    let applied = try unwrap(model.project)
    #expect((applied.frames[0].adjustments.timing.master) == (77))
    for index in [1, 2] {
      #expect((applied.frames[index].adjustments.timing.master) == (12))
      #expect((applied.frames[index].adjustments.contrast.red) == (1.2))
    }
    #expect((applied.calibration) == (before.calibration))
    model.undo()
    #expect((model.project?.frames) == (before.frames))
    model.redo()
    #expect((model.project?.frames) == (applied.frames))
    // Idempotent apply must not consume another undo slot.
    model.applyParameters()
    model.undo()
    #expect((model.project?.frames) == (before.frames))
    model.redo()
    #expect(model.flushSave())
    let reopened = try ProjectStore.open(folder: folder, preferredFile: nil)
    #expect((reopened.frames) == (applied.frames))
    #expect(!(model.dirty))
    // Await pending preview tasks before tearing down local fixture files.
    try await Task.sleep(for: .milliseconds(400))
  }
  @Test func testSliderGestureIsSingleUndoAndBothMasterKeysIncrease() async throws {
    let model = EditorModel()
    var roll = RollProject()
    let frame = FrameRecord(filename: "Sample.tiff")
    roll.frames = [frame]
    model.project = roll
    model.selection.click(frame.id, ordered: [frame.id])
    model.beginAdjustment()
    model.edit { $0.timing.red = 10 }
    model.edit { $0.timing.red = 20 }
    model.edit { $0.timing.red = 30 }
    model.endAdjustment()
    model.undo()
    #expect((model.adjustments.timing.red) == (0))
    model.redo()
    #expect((model.adjustments.timing.red) == (30))
    model.handleTimingKey("w")
    model.handleTimingKey("s")
    #expect((model.adjustments.timing.master) == (2))
    model.undo()
    #expect((model.adjustments.timing.master) == (1))
  }
  @Test func testFloatPreviewCarriesSourceICCWithoutExtraGamma() async throws {
    let assets = try AppAssets()
    let input = PixelBuffer(
      width: 2, height: 1, pixels: [SIMD4(0.18, 0.5, 0.8, 1), SIMD4(1, 0, 0.25, 1)])
    let image = try DisplayImage.make(input, profile: assets.profile)
    #expect((image.bitsPerComponent) == (32))
    #expect((image.colorSpace?.copyICCData() as Data?) == (assets.profile))
    let data = try unwrap(image.dataProvider?.data) as Data
    let values = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    #expect(abs((values[0]) - (0.18)) <= 1e-7)
    #expect(abs((values[1]) - (0.5)) <= 1e-7)
    let diagnostic = try DisplayImage.make(input, profile: assets.profile, diagnostic: true)
    #expect((diagnostic.colorSpace?.name) == (CGColorSpace.sRGB))
  }
  @Test func testServiceExportsActualPipelineAndICC() async throws {
    let assets = try AppAssets()
    let service = ImageService()
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "PrintroomExport-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("source.tiff")
    let dest = folder.appendingPathComponent("final.tiff")
    let samples: [UInt16] = (0..<(32 * 32 * 3)).map { UInt16(($0 * 73) % 65536) }
    try TIFFCodec.write(url: source, width: 32, height: 32, profile: assets.profile) { range in
      Array(samples[(range.lowerBound * 32 * 3)..<(range.upperBound * 32 * 3)])
    }
    let original = try TIFFCodec.read(url: source)
    let calibration = try Pipeline.calibrate(
      image: original, rect: PixelRect(x: 4, y: 4, width: 8, height: 8), matrix: .ledLightSource,
      sourceFrameID: nil)
    let adjustments = FrameAdjustments(
      timing: .init(master: 15, red: -7, green: 3, blue: 9),
      contrast: .init(master: 0.9, red: 1.1, green: 0.95, blue: 1.2))
    try await service.export(
      source: source, destination: dest, calibration: calibration, adjustments: adjustments,
      assets: assets
    ) { _ in }
    let decoded = try TIFFCodec.read(url: dest)
    #expect((decoded.embeddedProfileName) == ("P3 D65 Gamma 2.6"))
    let gpu = try assets.gpu.render(
      original.preview(maxDimension: 32), calibration: calibration, adjustments: adjustments,
      lut: assets.lut)
    for i in gpu.pixels.indices {
      for c in 0..<3 {
        let expected = UInt16(floor(min(1, max(0, gpu.pixels[i][c])) * 65535 + 0.5))
        #expect((decoded.samples[i * 3 + c]) == (expected))
      }
    }
    #expect((try TIFFCodec.read(url: source).samples) == (samples))
  }
}
