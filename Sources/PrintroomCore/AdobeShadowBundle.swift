import Foundation

/// Runs the installed, unmodified Adobe binary inside an LSUIElement bundle.
/// Like open-make-tiff's shadow bundle, only the small Info.plist is copied;
/// executable, Resources and Frameworks remain links to the Adobe installation.
/// A failure is reported rather than launching the visible Adobe application.
enum AdobeShadowBundle {
  private static let storage = Storage()

  static func executable(for installation: AdobeRAWInstallation) throws -> URL {
    try storage.executable(for: installation)
  }

  private final class Storage: @unchecked Sendable {
    private let lock = NSLock()
    private var executables: [String: URL] = [:]
    private let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("printroom-adobe-agent-\(UUID())", isDirectory: true)

    func executable(for installation: AdobeRAWInstallation) throws -> URL {
      lock.lock(); defer { lock.unlock() }
      let original = installation.executable.standardizedFileURL
      let key = original.path + "\n" + installation.version
      if let cached = executables[key] { return cached }
      let macOS = original.deletingLastPathComponent()
      let contents = macOS.deletingLastPathComponent()
      let bundle = contents.deletingLastPathComponent()
      guard original.isFileURL, macOS.lastPathComponent == "MacOS",
        contents.lastPathComponent == "Contents", bundle.pathExtension.lowercased() == "app"
      else { throw PrintroomError.invalid("Adobe 转换器的应用包结构无效，无法静默启动。") }
      let fm = FileManager.default
      let wrapper = directory.appendingPathComponent(UUID().uuidString)
        .appendingPathComponent(bundle.lastPathComponent, isDirectory: true)
      do {
        let data = try Data(contentsOf: contents.appendingPathComponent("Info.plist"))
        guard var plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          plist["CFBundleExecutable"] as? String == original.lastPathComponent
        else { throw PrintroomError.invalid("Adobe 转换器的应用信息无效，无法静默启动。") }
        plist["LSUIElement"] = true
        let wrapperContents = wrapper.appendingPathComponent("Contents", isDirectory: true)
        let wrapperMacOS = wrapperContents.appendingPathComponent("MacOS", isDirectory: true)
        try fm.createDirectory(at: wrapperMacOS, withIntermediateDirectories: true)
        let executable = wrapperMacOS.appendingPathComponent(original.lastPathComponent)
        try fm.createSymbolicLink(at: executable, withDestinationURL: original)
        for name in ["Frameworks", "Resources"] {
          let source = contents.appendingPathComponent(name, isDirectory: true)
          if fm.fileExists(atPath: source.path) {
            try fm.createSymbolicLink(at: wrapperContents.appendingPathComponent(name), withDestinationURL: source)
          }
        }
        let info = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try info.write(to: wrapperContents.appendingPathComponent("Info.plist"), options: .atomic)
        executables[key] = executable
        return executable
      } catch {
        try? fm.removeItem(at: wrapper.deletingLastPathComponent())
        throw PrintroomError.invalid("无法准备 Adobe 静默转换：\(error.localizedDescription)")
      }
    }
  }
}
