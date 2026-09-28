import Foundation
import PrintroomCore
import Testing
@testable import PrintroomApp

@Suite(.serialized) @MainActor
struct MatrixEditingTests {
  private func folder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("printroom-matrix-ui-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
  private func wait(_ predicate: () -> Bool) async throws {
    for _ in 0..<1000 {
      if predicate() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(predicate(), "Matrix operation did not settle")
  }
  @Test func matrixChangesRealignFilmBaseAtomicallyAndSurviveUndoSaveReopen() async throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = EditorModel(matrixStore: .init(url: root.appendingPathComponent("library.json")))
    let assets = try #require(model.assets)
    try TIFFCodec.write(url: root.appendingPathComponent("scan.tiff"), width: 16,height: 16,profile: assets.profile) {
      Array(repeating: [UInt16(12000),22000,32000],count: $0.count*16).flatMap { $0 }
    }
    // Explicit Identity fixture exercises both matrix transitions with new-roll defaults changed.
    var fixture = try ProjectStore.open(folder: root)
    fixture.calibration = FilmCalibration()
    try ProjectStore.save(fixture, folder: root, expectedModification: nil)
    model.open(root)
    try await wait { model.hasImage && !model.isRendering }
    model.sampleBase(.init(x: 0,y: 0,width: 4,height: 4))
    try await wait { model.project?.calibration.isCalibrated == true && !model.isRendering }
    let original = try #require(model.project?.calibration)
    let cmos = MatrixPreset.sonyA7CII
    model.setMatrixPreset(cmos,kind: .density)
    #expect(model.project?.calibration == original)
    #expect(throws: (any Error).self) { try model.deleteMatrix(cmos) }
    #expect(throws: (any Error).self) { try model.saveMatrix(cmos,kind: .cmos,apply: false) }
    model.setMatrixPreset(cmos,kind: .cmos)
    try await wait { model.cmosMatrix == cmos }
    let cmosCalibration = try #require(model.project?.calibration)
    #expect(cmosCalibration.gainRGB != original.gainRGB)
    model.setMatrixPreset(.ledLightSource, kind: .density)
    #expect(model.project?.calibration.gainRGB == cmosCalibration.gainRGB)
    #expect(model.project?.calibration.filmBaseOffsetCV != original.filmBaseOffsetCV)
    #expect(model.project?.calibration.sampledDensityMatrix == .ledLightSource)
    model.undo()
    #expect(model.matrix == .identity)
    #expect(model.cmosMatrix == cmos)
    model.undo()
    #expect(model.project?.calibration == original)
    model.redo(); model.redo()
    #expect(model.flushSave())
    let reopened = try ProjectStore.open(folder: root)
    #expect(reopened.calibration == model.project?.calibration)
    #expect(reopened.calibration.gainRGB == cmosCalibration.gainRGB)
    #expect(reopened.calibration.sampledDensityMatrix == .ledLightSource)
    try await wait { !model.isRendering }
    let updated = try #require(model.project?.calibration)
    #expect(updated.gainRGB != original.gainRGB)
    #expect(updated.sampledDensityMatrix == .ledLightSource)
    let value = try Pipeline.process(SIMD3<Float>(12000,22000,32000)/65535,
      calibration: updated,adjustments: .init(),stage: .d2)
    for c in 0..<3 { #expect(abs(value[c]*1024-95) < 0.01) }
    #expect(model.flushSave())
  }
  @Test func rapidMatrixChangesFailureAndCancellationPreserveFrameEdits() async throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = EditorModel(matrixStore: .init(url: root.appendingPathComponent("library.json")))
    let assets = try #require(model.assets)
    let url = root.appendingPathComponent("scan.tiff")
    try TIFFCodec.write(url: url, width: 16, height: 16, profile: assets.profile) {
      Array(repeating: [UInt16(12000),22000,32000], count: $0.count * 16).flatMap { $0 }
    }
    // Explicit Identity fixture exercises both matrix transitions with new-roll defaults changed.
    var fixture = try ProjectStore.open(folder: root)
    fixture.calibration = FilmCalibration()
    try ProjectStore.save(fixture, folder: root, expectedModification: nil)
    model.open(root)
    try await wait { model.hasImage && !model.isRendering }
    model.sampleBase(.init(x: 0, y: 0, width: 4, height: 4))
    try await wait { model.project?.calibration.isCalibrated == true && !model.isRendering }
    model.project?.frames[0].adjustments = .init(timing: .init(master: 12, red: 3), contrast: .init(master: 1.2))
    let original = try #require(model.project?.calibration)
    let edits = model.project?.frames[0].adjustments
    model.setMatrixPreset(.sonyA7CII, kind: .cmos)
    model.setMatrixPreset(.ledLightSource, kind: .density)
    try await wait { model.cmosMatrix == .sonyA7CII && model.matrix == .ledLightSource }
    #expect(model.project?.frames[0].adjustments == edits)
    let aligned = try #require(model.project?.calibration)
    let value = try Pipeline.process(SIMD3<Float>(12000,22000,32000)/65535,
      calibration: aligned, adjustments: .init(), stage: .d2)
    for c in 0..<3 { #expect(abs(value[c]*1024-95) < 0.01) }
    model.undo()
    #expect(model.project?.calibration == original)
    #expect(model.project?.frames[0].adjustments == edits)

    let invalid = try MatrixPreset(name: "Negative", coefficients: RGBMatrix([-1,0,0, 0,1,0, 0,0,1]))
    let undoCount = model.undoRevision
    model.setMatrixPreset(invalid, kind: .cmos)
    try await wait { model.errorMessage != nil }
    #expect(model.project?.calibration == original)
    #expect(model.undoRevision == undoCount)
    model.errorMessage = nil

    // A second request back to the committed matrix cancels the pending change.
    model.setMatrixPreset(.sonyA7CII, kind: .cmos)
    model.setMatrixPreset(.identity, kind: .cmos)
    try await Task.sleep(for: .milliseconds(100))
    #expect(model.project?.calibration == original)
    #expect(model.undoRevision == undoCount)

    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: url.path)
    model.setMatrixPreset(.ledLightSource, kind: .density)
    #expect(model.errorMessage != nil)
    #expect(model.project?.calibration == original)
    #expect(model.undoRevision == undoCount)
    model.errorMessage = nil
    try FileManager.default.removeItem(at: url)
    model.setMatrixPreset(.sonyA7CII, kind: .cmos)
    #expect(model.errorMessage != nil)
    #expect(model.project?.calibration == original)
    #expect(model.undoRevision == undoCount)
  }
  @Test func computerLibraryEditingAndDeletionLeaveRollsAndUndoSnapshotsIndependent() throws {
    let root = try folder()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MatrixLibraryStore(url: root.appendingPathComponent("matrices.json"))
    let first = EditorModel(matrixStore: store)
    let original = try MatrixPreset(name: "Custom",coefficients: .identity)
    first.project = RollProject()
    try first.saveMatrix(original,kind: .density,apply: true)
    let second = EditorModel(matrixStore: store)
    second.project = RollProject()
    second.setMatrixPreset(original, kind: .density)
    let edited = try MatrixPreset(id: original.id,name: "Edited",coefficients: RGBMatrix([1.1,0,0, 0,1,0, 0,0,1]))
    try second.saveMatrix(edited,kind: .density,apply: false)
    #expect(first.matrix == original)
    #expect(second.matrix == original)
    #expect(second.isMatrixSnapshot(original,kind: .density))
    #expect(second.matrixOptions(.density).contains(original))
    #expect(second.matrixOptions(.density).contains(edited))
    second.setMatrixPreset(edited, kind: .density)
    try second.deleteMatrix(edited)
    #expect(second.matrix == edited)
    #expect(try store.load().isEmpty)
    second.undo()
    #expect(second.matrix == original)
    #expect(throws: (any Error).self) { try second.saveMatrix(.identity,kind: .density,apply: false) }
    #expect(throws: (any Error).self) { try second.deleteMatrix(.ledLightSource) }
  }
  @Test func pastedDensityValuesKeepSignsAndRowsAndRejectIncompleteOrNonFiniteValues() throws {
    let matrix = try DensityMatrixInput.parse("[1, -0.25, 0]\n[0; 1.2; 0]\n[0 0 1e-2]")
    #expect(matrix.values == [1,-0.25,0,0,1.2,0,0,0,0.01])
    #expect(throws: (any Error).self) { try DensityMatrixInput.parse("1 0 0") }
    #expect(throws: (any Error).self) { try DensityMatrixInput.parse("nan 0 0 0 1 0 0 0 1") }
    #expect(throws: (any Error).self) { try DensityMatrixInput.parse("1e99 0 0 0 1 0 0 0 1") }
  }
}
