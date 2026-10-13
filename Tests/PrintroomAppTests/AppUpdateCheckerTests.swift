import Foundation
import Testing
@testable import PrintroomApp

@Suite @MainActor struct AppUpdateCheckerTests {
  @Test func numericVersions() throws {
    #expect(try #require(ReleaseVersion("v1.0.10")) > #require(ReleaseVersion("1.0.9")))
    #expect(try #require(ReleaseVersion("2.0.0")) > #require(ReleaseVersion("1.99.99")))
    #expect(ReleaseVersion("v1.0.2") == ReleaseVersion("1.0.2"))
    for invalid in ["", "1.2", "1.2.3.4", "1.0.3-beta.1", "01.0.3", "1.-1.3", "1.0.x"] {
      #expect(ReleaseVersion(invalid) == nil)
    }
  }

  @Test func newerReleaseAndOnlyOneRequest() async {
    var requests = 0
    let checker = AppUpdateChecker(currentVersion: "1.0.2") { request in
      requests += 1
      #expect(request.url == AppUpdateChecker.endpoint)
      #expect(request.timeoutInterval == 8)
      #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
      // A second trigger while the first request is pending must not fetch again.
      await Task.yield()
      return response(tag: "v1.0.10")
    }
    let first = Task { await checker.checkOnce() }
    await Task.yield()
    await checker.checkOnce()
    await first.value
    await checker.checkOnce()
    #expect(requests == 1)
    #expect(checker.availableVersion == "v1.0.10")
  }

  @Test func sameOlderAndNonStableReleasesStayHidden() async {
    for (tag, draft, prerelease) in [
      ("v1.0.2", false, false), ("v1.0.1", false, false),
      ("v1.0.3", true, false), ("v1.0.3", false, true),
      ("v1.0.3-beta.1", false, false), ("invalid", false, false),
    ] {
      let checker = AppUpdateChecker(currentVersion: "1.0.2") { _ in
        response(tag: tag, draft: draft, prerelease: prerelease)
      }
      await checker.checkOnce()
      #expect(checker.availableVersion == nil)
    }
  }

  @Test func failuresStaySilentWithoutRetry() async {
    for status in [403, 404, 429, 500] {
      let checker = AppUpdateChecker(currentVersion: "1.0.2") { _ in response(status: status) }
      await checker.checkOnce()
      #expect(checker.availableVersion == nil)
    }
    var calls = 0
    let offline = AppUpdateChecker(currentVersion: "1.0.2") { _ in
      calls += 1
      throw URLError(.notConnectedToInternet)
    }
    await offline.checkOnce()
    await offline.checkOnce()
    #expect(calls == 1)
    #expect(offline.availableVersion == nil)
    let malformed = AppUpdateChecker(currentVersion: "1.0.2") { _ in
      (Data("not JSON".utf8), response().1)
    }
    await malformed.checkOnce()
    #expect(malformed.availableVersion == nil)
  }

  @Test func missingBundleVersionDoesNotQuery() async {
    let checker = AppUpdateChecker(currentVersion: nil) { _ in
      Issue.record("An unbundled executable must not query GitHub")
      return response()
    }
    await checker.checkOnce()
    #expect(checker.availableVersion == nil)
  }

  private func response(tag: String = "v1.0.3", draft: Bool = false,
                        prerelease: Bool = false, status: Int = 200) -> (Data, URLResponse) {
    let json = "{\"tag_name\":\"\(tag)\",\"draft\":\(draft),\"prerelease\":\(prerelease)}"
    return (Data(json.utf8), HTTPURLResponse(url: AppUpdateChecker.endpoint,
      statusCode: status, httpVersion: nil, headerFields: nil)!)
  }
}
