import Foundation
import PrintroomCore

/// Prepares only unadjusted disk proxies. No full-resolution image is retained here.
enum RAWPrewarmer {
  static let concurrency = 4

  static func prepare(
    _ urls: [URL], load: @escaping @Sendable (URL) throws -> Void = {
      _ = try SourceImageIO.metadata(url: $0)
    }
  ) async {
    await withTaskGroup(of: Void.self) { group in
      var next = 0
      func enqueue(_ url: URL) {
        group.addTask {
          guard !Task.isCancelled else { return }
          let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            try load(url)
          }
          // A failed background frame is reported by the normal preview/thumbnail
          // request. It must not stop the remaining roll or publish stale UI state.
          _ = try? await withTaskCancellationHandler {
            try await worker.value
          } onCancel: { worker.cancel() }
        }
      }
      while next < min(concurrency, urls.count), !Task.isCancelled {
        enqueue(urls[next]); next += 1
      }
      while await group.next() != nil {
        guard !Task.isCancelled else { group.cancelAll(); break }
        if next < urls.count { enqueue(urls[next]); next += 1 }
      }
    }
  }
}
