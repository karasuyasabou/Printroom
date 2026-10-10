import CoreGraphics
import Foundation
import PrintroomCore
import Testing
@testable import PrintroomApp

@Suite(.serialized)
struct ThumbnailMaintenanceBatchTests {
  private func fixture() throws -> (URL, DiskThumbnailCache, CGImage) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("thumbnail-batch-\(UUID())")
    let cache = DiskThumbnailCache(directory: root.appendingPathComponent(".printroom-cache"), maximumBytes: 0)
    let image = try DisplayImage.make(PixelBuffer(width: 1, height: 1,
      pixels: [SIMD4(0.2, 0.5, 0.9, 1)]), profile: nil)
    return (root, cache, image)
  }
  private func waitForRemoval(_ cache: DiskThumbnailCache, timeout: Duration = .seconds(3)) async throws {
    let directory = await cache.directory
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
      let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
      if !names.contains(where: { $0.hasSuffix(".png") }) { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Published PNGs did not receive bounded maintenance")
  }

  @Test func normalEndMaintainsPublishedWrites() async throws {
    let (root, cache, image) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    await cache.beginMaintenanceBatch()
    try await cache.store(image, for: String(repeating: "a", count: 64))
    #expect(try await cache.image(for: String(repeating: "a", count: 64)) != nil)
    await cache.endMaintenanceBatch().value
    #expect(try await cache.image(for: String(repeating: "a", count: 64)) == nil)
  }

  @Test func cancelledRefreshStillMaintainsPublishedWrites() async throws {
    let (root, cache, image) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let work = Task {
      await cache.beginMaintenanceBatch()
      defer { cache.endMaintenanceBatch() }
      try await cache.store(image, for: String(repeating: "b", count: 64))
      withUnsafeCurrentTask { $0?.cancel() }
      try Task.checkCancellation()
    }
    do { try await work.value; Issue.record("Expected cancellation") } catch is CancellationError {}
    try await waitForRemoval(cache)
  }

  @Test func failedRefreshStillMaintainsEarlierWrites() async throws {
    let (root, cache, image) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let work = Task {
      await cache.beginMaintenanceBatch()
      defer { cache.endMaintenanceBatch() }
      try await cache.store(image, for: String(repeating: "c", count: 64))
      try await cache.store(image, for: "invalid-key")
    }
    do { try await work.value; Issue.record("Expected invalid key") } catch {}
    try await waitForRemoval(cache)
  }

  @Test func unfinishedBatchHasFixedDeadlineMaintenance() async throws {
    let (root, cache, image) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    await cache.beginMaintenanceBatch()
    try await cache.store(image, for: String(repeating: "d", count: 64))
    try await waitForRemoval(cache)
    await cache.endMaintenanceBatch().value
  }

  @Test func longBatchMaintainsAtWriteBound() async throws {
    let (root, cache, image) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    await cache.beginMaintenanceBatch()
    for i in 0..<64 { try await cache.store(image, for: String(format: "%064x", i)) }
    try await waitForRemoval(cache, timeout: .milliseconds(500))
    await cache.endMaintenanceBatch().value
  }
}
