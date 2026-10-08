import Foundation
import Testing
@testable import PrintroomApp

@Suite(.serialized)
struct RAWPrewarmerTests {
  private final class State: @unchecked Sendable {
    let lock = NSLock()
    var started = 0
    var active = 0
    var peak = 0
    var cancelled = 0
    func enter() { lock.withLock { started += 1; active += 1; peak = max(peak, active) } }
    func leave(cancelled didCancel: Bool = false) {
      lock.withLock { active -= 1; if didCancel { cancelled += 1 } }
    }
    var counts: (Int, Int, Int, Int) { lock.withLock { (started, active, peak, cancelled) } }
  }
  private func waitForFour(_ state: State) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while state.counts.0 < 4 && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(state.counts.0 == 4)
  }
  @Test func exactlyFourWorkersAndFailureDoesNotStopTheRoll() async throws {
    let state = State(), gate = DispatchSemaphore(value: 0)
    let urls = (0..<12).map { URL(fileURLWithPath: "/test/\($0).ARW") }
    let task = Task {
      await SourcePrewarmer.prepare(urls, load: { url in
        state.enter(); defer { state.leave() }
        gate.wait()
        if url.lastPathComponent == "0.ARW" { throw CocoaError(.fileReadCorruptFile) }
      })
    }
    try await waitForFour(state)
    for _ in urls { gate.signal() }
    let failures = await task.value
    #expect(failures.map { $0.url.lastPathComponent } == ["0.ARW"])
    #expect(state.counts.0 == 12)
    #expect(state.counts.1 == 0)
    #expect(state.counts.2 == 4)
  }
  @Test func cancellationStopsFourWorkersWithoutStartingNextBatch() async throws {
    let state = State()
    let urls = (0..<12).map { URL(fileURLWithPath: "/test/\($0).ARW") }
    let task = Task {
      await SourcePrewarmer.prepare(urls, load: { _ in
        state.enter()
        while !Task.isCancelled { Thread.sleep(forTimeInterval: 0.005) }
        state.leave(cancelled: true)
        throw CancellationError()
      })
    }
    try await waitForFour(state)
    task.cancel()
    _ = await task.value
    #expect(state.counts.0 == 4)
    #expect(state.counts.1 == 0)
    #expect(state.counts.3 == 4)
  }
}
