import Foundation
import PrintroomCore
import Testing
@testable import PrintroomApp

/// TIFF and RAW now publish the editor only after the shared proxy barrier.
@MainActor func waitForProxyImport(_ model: EditorModel) async throws {
  let deadline = ContinuousClock.now.advanced(by: .seconds(10))
  while model.isImporting, model.importFailure == nil, ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(2))
  }
  try #require(!model.isImporting, "Proxy preparation did not finish: \(model.importFailure ?? "timeout")")
}

/// Processing regressions explicitly opt into calibration; new-roll behavior is
/// covered separately by FilmBasePreviewTests.
@MainActor func prepareCalibratedPreview(_ model: EditorModel) async throws {
  let deadline = ContinuousClock.now.advanced(by: .seconds(15))
  while (!model.hasImage || model.isRendering), ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(5))
  }
  try #require(model.hasImage && !model.isRendering)
  if !model.hasFilmBase {
    model.sampleBase(.init(x: 0, y: 0, width: 4, height: 4))
    while (!model.hasFilmBase || model.isRendering), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    try #require(model.hasFilmBase && !model.isRendering)
  }
}
