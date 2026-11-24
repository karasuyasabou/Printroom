import Foundation
import PrintroomCore

/// Owns the pending save. UI error and dirty state remain in EditorModel.
@MainActor final class ProjectPersistence {
  private var pending: Task<Void, Never>?

  func cancel() { pending?.cancel(); pending = nil }

  func schedule(_ save: @escaping @MainActor () -> Void) {
    cancel()
    pending = Task {
      do { try await Task.sleep(for: .seconds(2)) } catch { return }
      guard !Task.isCancelled else { return }
      save()
    }
  }

  func save(_ project: RollProject, folder: URL) throws {
    let trace = PerformanceTrace.begin(); defer { PerformanceTrace.end("project.save", trace) }
    cancel()
    try ProjectStore.save(project, folder: folder)
  }
}
