import Foundation
import Combine

/// Only stable, three-component release versions participate in update checks.
struct ReleaseVersion: Comparable {
  let components: [Int]

  init?(_ text: String) {
    let value = text.hasPrefix("v") ? String(text.dropFirst()) : text
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3 else { return nil }
    var numbers: [Int] = []
    for part in parts {
      guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
        part.count == 1 || part.first != "0", let number = Int(part)
      else { return nil }
      numbers.append(number)
    }
    components = numbers
  }

  static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.components.lexicographicallyPrecedes(rhs.components)
  }
}

@MainActor final class AppUpdateChecker: ObservableObject {
  static let latestReleaseURL = URL(string: "https://github.com/karasuyasabou/Printroom/releases/latest")!
  static let endpoint = URL(string: "https://api.github.com/repos/karasuyasabou/Printroom/releases/latest")!
  let currentVersion: String?
  @Published private(set) var availableVersion: String?
  private var checked = false
  private let fetch: (URLRequest) async throws -> (Data, URLResponse)

  init(
    currentVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
    fetch: @escaping (URLRequest) async throws -> (Data, URLResponse) = { request in
      let configuration = URLSessionConfiguration.ephemeral
      configuration.timeoutIntervalForRequest = 8
      configuration.timeoutIntervalForResource = 10
      configuration.waitsForConnectivity = false
      let session = URLSession(configuration: configuration)
      defer { session.invalidateAndCancel() }
      return try await session.data(for: request)
    }
  ) {
    self.currentVersion = currentVersion
    self.fetch = fetch
  }

  func checkOnce() async {
    guard !checked else { return }
    checked = true
    // Unbundled development/test executables have no authoritative version.
    guard let currentVersion, let current = ReleaseVersion(currentVersion) else { return }
    var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    request.setValue("Printroom", forHTTPHeaderField: "User-Agent")
    do {
      let (data, response) = try await fetch(request)
      guard !Task.isCancelled, (response as? HTTPURLResponse)?.statusCode == 200 else { return }
      let release = try JSONDecoder().decode(Release.self, from: data)
      guard !release.draft, !release.prerelease,
        let latest = ReleaseVersion(release.tag_name), latest > current
      else { return }
      availableVersion = "v" + latest.components.map(String.init).joined(separator: ".")
    } catch {
      // Offline, rate-limited and malformed responses remain silent until next launch.
    }
  }

  private struct Release: Decodable {
    let tag_name: String
    let draft: Bool
    let prerelease: Bool
  }
}
