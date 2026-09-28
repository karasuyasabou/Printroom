import Foundation
import PrintroomCore

/// Prepares the entire roll before the editor starts preview/thumbnail work.
enum RAWPrewarmer {
  static let concurrency = 4
  struct Failure: Sendable {
    let url: URL
    let message: String
  }

  @discardableResult
  static func prepare(
    _ urls: [URL], progress: @escaping @Sendable (Int) async -> Void = { _ in },
    load: @escaping @Sendable (URL) throws -> Void = { _ = try SourceImageIO.metadata(url: $0) }
  ) async -> [Failure] {
    await withTaskGroup(of: Failure?.self) { group in
      var next = 0, completed = 0
      var failures: [Failure] = []
      func enqueue(_ url: URL) {
        group.addTask {
          guard !Task.isCancelled else { return nil }
          let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            try load(url)
          }
          do {
            try await withTaskCancellationHandler {
              try await worker.value
            } onCancel: { worker.cancel() }
            return nil
          } catch {
            return Failure(url: url, message: error.localizedDescription)
          }
        }
      }
      while next < min(concurrency, urls.count), !Task.isCancelled {
        enqueue(urls[next]); next += 1
      }
      while let result = await group.next() {
        guard !Task.isCancelled else { group.cancelAll(); break }
        if let result { failures.append(result) }
        completed += 1
        await progress(completed)
        if next < urls.count { enqueue(urls[next]); next += 1 }
      }
      return failures.sorted { $0.url.path < $1.url.path }
    }
  }
}
