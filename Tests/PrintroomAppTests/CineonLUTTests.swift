import AppKit
import Foundation
import ImageIO
import PrintroomCore
import Testing
@testable import PrintroomApp

@Suite(.serialized) @MainActor
struct CineonLUTTests {
  @Test(arguments: [CineonLogLUT.fujifilm3513DI])
  func independentSyncPersistenceAndUndo(selection: CineonLogLUT) async throws {
    let model = EditorModel()
    let assets = try #require(model.assets)
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lut-sync-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    for name in ["A.tif", "B.tif", "C.tif"] {
      try TIFFCodec.write(url: folder.appendingPathComponent(name), width: 12, height: 8, profile: assets.profile) {
        [UInt16](repeating: 12000, count: $0.count * 12 * 3)
      }
    }
    model.open(folder)
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while model.histogram == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    #expect(model.histogram != nil)
    model.edit { $0.timing.red = 27; $0.contrast.blue = 1.3; $0.cineonLogLUT = selection }
    model.selectAll()
    let before = try #require(model.project)
    for mask in 1...7 {
      model.beginSync()
      #expect(!model.hasSyncSelection)
      model.syncTiming = mask & 1 != 0
      model.syncContrast = mask & 2 != 0
      model.syncLUT = mask & 4 != 0
      #expect(model.syncCurrentSettings())
      let applied = try #require(model.project)
      #expect(applied.frames[0] == before.frames[0])
      for index in 1...2 {
        let value = applied.frames[index].adjustments
        #expect(value.timing.red == (mask & 1 != 0 ? 27 : 0))
        #expect(value.contrast.blue == (mask & 2 != 0 ? 1.3 : 1))
        #expect(value.cineonLogLUT == (mask & 4 != 0 ? selection : .kodak2383))
        #expect(applied.frames[index].crop == before.frames[index].crop)
      }
      model.undo()
      #expect(model.project?.frames == before.frames)
      model.redo()
      #expect(model.project?.frames == applied.frames)
      model.undo()
    }
    #expect(model.flushSave())
    #expect(try ProjectStore.open(folder: folder).frames == before.frames)
    model.copyParameters()
    model.applyParameters()
    #expect(model.project?.frames.allSatisfy { $0.adjustments.cineonLogLUT == selection } == true)
    model.resetAdjustments()
    #expect(model.adjustments.cineonLogLUT == .kodak2383)
  }

  @Test func legacyMigrationAndUnknownSelection() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lut-migration-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let profile = try AppAssets().profile
    try TIFFCodec.write(url: folder.appendingPathComponent("A.tif"), width: 2, height: 2, profile: profile) {
      [UInt16](repeating: 12000, count: $0.count * 6)
    }
    let project = try ProjectStore.open(folder: folder)
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any])
    object["schemaVersion"] = 5
    var frames = try #require(object["frames"] as? [[String: Any]])
    var adjustments = try #require(frames[0]["adjustments"] as? [String: Any])
    adjustments.removeValue(forKey: "cineonLogLUT")
    frames[0]["adjustments"] = adjustments
    object["frames"] = frames
    let original = try JSONSerialization.data(withJSONObject: object)
    try original.write(to: folder.appendingPathComponent(".printroom.json"))
    let migrated = try ProjectStore.open(folder: folder)
    #expect(migrated.schemaVersion == RollProject.currentSchemaVersion)
    #expect(migrated.frames[0].adjustments.cineonLogLUT == .kodak2383)
    try ProjectStore.save(migrated, folder: folder, expectedModification: ProjectStore.modificationDate(folder: folder))
    let backups = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
      .filter { $0.lastPathComponent.hasPrefix(".printroom-schema5-") }
    #expect(backups.count == 1)
    #expect(try Data(contentsOf: #require(backups.first)) == original)
    adjustments["cineonLogLUT"] = "unknown"
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(FrameAdjustments.self, from: JSONSerialization.data(withJSONObject: adjustments))
    }
  }

  @Test func selectedLUTPreviewMetalAndMixedExportReadback() async throws {
    let assets = try AppAssets()
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lut-export-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    var samples = [UInt16](repeating: 12000, count: 12 * 8 * 3)
    if ProcessInfo.processInfo.environment["PRINTROOM_VALIDATE_ASSETS"] == "1" {
      let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
      samples = try TIFFCodec.readRegion(url: root.appendingPathComponent("TEST/TIFF/DSC07079.tiff"),
        rect: PixelRect(x: 3500, y: 2300, width: 12, height: 8)).samples
    }
    for (index, _) in CineonLogLUT.allCases.enumerated() {
      let name = "Frame-\(index).tif"
      try TIFFCodec.write(url: folder.appendingPathComponent(name), width: 12, height: 8, profile: assets.profile) {
        Array(samples[($0.lowerBound * 36)..<($0.upperBound * 36)])
      }
    }
    var project = try ProjectStore.open(folder: folder)
    for (index, selection) in CineonLogLUT.allCases.enumerated() {
      project.frames[index].adjustments.cineonLogLUT = selection
    }
    let output = folder.appendingPathComponent("export")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let request = try ExportRequest(project: project, targetIDs: Set(project.frames.map(\.id)), destinationDirectory: output)
    project.frames[1].adjustments.cineonLogLUT = .kodak2383 // Running exports retain their snapshot.
    let summary = try await ExportEngine().run(request, lut: assets.lut, p3Profile: assets.profile, fujifilmLUT: assets.fujifilmLUT)
    #expect(summary.completedCount == CineonLogLUT.allCases.count)
    let input = LinearImage(width: 12, height: 8, samples: samples).preview()
    let preview = PreviewRenderService()
    var colors: [SIMD3<Float>] = []
    for (index, frame) in request.frames.enumerated() {
      let expected = try Pipeline.render(input, calibration: request.calibration, adjustments: frame.adjustments, lut: assets.lut(for: frame.adjustments.cineonLogLUT))
      let rendered = try await preview.render(input, calibration: request.calibration, adjustments: frame.adjustments, assets: assets, inputIdentity: request.id)
      let pixel = expected.pixels[0]
      colors.append(SIMD3(pixel.x, pixel.y, pixel.z))
      for channel in 0..<3 { #expect(abs(rendered.pixels.pixels[0][channel] - pixel[channel]) < 0.00003) }
      let destination = try #require(summary.results[index].destination)
      let readback = try TIFFCodec.read(url: destination)
      let imageSource = try #require(CGImageSourceCreateWithURL(destination as CFURL, nil))
      let image = try #require(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
      #expect(image.bitsPerComponent == 16)
      #expect(image.colorSpace?.copyICCData() as Data? == assets.profile)
      for i in expected.pixels.indices {
        for channel in 0..<3 {
          let quantized = Int((Double(min(1, max(0, expected.pixels[i][channel]))) * 65535).rounded())
          #expect(abs(Int(readback.samples[i * 3 + channel]) - quantized) <= 2)
        }
      }
    }
    #expect(colors[0] != colors[1])
  }
}
