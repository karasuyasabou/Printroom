import Foundation
import PrintroomCore
import Testing
@testable import PrintroomApp

@Suite(.serialized) @MainActor
struct RAWGeometryTests {
  private func fixture(rawExtension: String = "ARW") throws -> (EditorModel, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("raw-geometry-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for name in ["A.\(rawExtension)", "B.\(rawExtension)"] { try Data([1]).write(to: root.appendingPathComponent(name)) }
    let tiff = root.appendingPathComponent(".metadata.tif")
    try TIFFCodec.write(url: tiff, width: 120, height: 80, profile: nil) { rows in
      [UInt16](repeating: 100, count: rows.count * 120 * 3)
    }
    let metadata = try TIFFCodec.metadata(url: tiff)
    let model = EditorModel()
    model.folder = root
    var project = try ProjectStore.open(folder: root)
    project.frames[0].crop = FrameCrop(aspect: .square, width: 0.5, geometryVersion: 2)
    project.frames[0].adjustments.timing.red = 23
    model.project = project
    model.selection.click(project.frames[0].id, ordered: project.frames.map(\.id))
    model.selectAll()
    model.syncTiming = true; model.syncContrast = true; model.syncLUT = true
    model.syncCrop = true
    model.rawGeometryMetadataLoader = { _ in metadata }
    return (model, root)
  }

  @Test(arguments: ["ARW", "CR3", "NEF", "RAF", "DNG"])
  func rawCropSyncPreparesOffMainAndCommitsOneTransaction(rawExtension: String) async throws {
    let (model, root) = try fixture(rawExtension: rawExtension)
    defer { try? FileManager.default.removeItem(at: root) }
    let previous = try #require(model.project)
    let read = model.rawGeometryMetadataLoader
    model.rawGeometryMetadataLoader = { url in
      #expect(!Thread.isMainThread)
      return try read(url)
    }
    #expect(!model.syncCurrentSettings())
    #expect(model.project?.frames == previous.frames)
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while model.project?.frames[1].crop == nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.project?.frames[1].crop == previous.frames[0].crop)
    #expect(model.project?.frames[1].adjustments == previous.frames[0].adjustments)
    model.undo()
    #expect(model.project?.frames == previous.frames)
  }

  @Test func rawCropSyncDiscardsPreparedResultAfterInterveningEdit() async throws {
    let (model, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let gate = DispatchSemaphore(value: 0)
    let read = model.rawGeometryMetadataLoader
    model.rawGeometryMetadataLoader = { url in
      gate.wait()
      return try read(url)
    }
    #expect(!model.syncCurrentSettings())
    model.project?.frames[1].adjustments.timing.blue = 17
    let expected = try #require(model.project)
    gate.signal(); gate.signal()
    try await Task.sleep(for: .milliseconds(150))
    #expect(model.project?.frames == expected.frames)
    #expect(model.project?.frames[1].crop == nil)
  }

  @Test func rawCropSyncDiscardsDimensionsAfterSourceReplacement() async throws {
    let (model, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let gate = DispatchSemaphore(value: 0)
    let read = model.rawGeometryMetadataLoader
    model.rawGeometryMetadataLoader = { url in
      gate.wait()
      return try read(url)
    }
    let previous = try #require(model.project)
    #expect(!model.syncCurrentSettings())
    try Data([1, 2, 3]).write(to: root.appendingPathComponent("B.ARW"))
    gate.signal(); gate.signal()
    try await Task.sleep(for: .milliseconds(150))
    #expect(model.project?.frames == previous.frames)
    #expect(model.project?.frames[1].crop == nil)
  }

  private final class CancellationProbe: @unchecked Sendable {
    let lock = NSLock()
    var calls = 0
    var cancelled = false
  }

  @Test(arguments: [false, true])
  func leavingFrameOrRollCancelsGeometryWorker(openOtherRoll: Bool) async throws {
    let (model, root) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let probe = CancellationProbe()
    model.rawGeometryMetadataLoader = { _ in
      probe.lock.withLock { probe.calls += 1 }
      do {
        while true {
          try Task.checkCancellation()
          Thread.sleep(forTimeInterval: 0.005)
        }
      } catch {
        probe.lock.withLock { probe.cancelled = true }
        throw error
      }
    }
    #expect(!model.syncCurrentSettings())
    #expect(model.isPreparingGeometry)
    let startedDeadline = ContinuousClock.now.advanced(by: .seconds(3))
    while probe.lock.withLock({ probe.calls == 0 }), ContinuousClock.now < startedDeadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(probe.lock.withLock { probe.calls } == 1)
    model.assets = nil // This test exercises cancellation without starting unrelated source decoding.
    if openOtherRoll {
      let other = root.appendingPathComponent("other")
      try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
      model.open(other)
    } else {
      let id = try #require(model.project?.frames[1].id)
      model.select(id)
    }
    #expect(!model.isPreparingGeometry)
    let cancelledDeadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !probe.lock.withLock({ probe.cancelled }), ContinuousClock.now < cancelledDeadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(probe.lock.withLock { probe.cancelled })
    #expect(probe.lock.withLock { probe.calls } == 1, "Cancellation must stop the remaining frame loop")
    #expect(!model.isPreparingGeometry)
    #expect(model.errorMessage == nil)
  }

}
