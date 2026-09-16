import AppKit
import SwiftUI

@main struct CacheWindowQA {
  @MainActor static func main() {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    app.finishLaunching()
    let window = NSWindow(contentRect: CGRect(x: 120, y: 120, width: 460, height: 300),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "管理缓存"
    window.contentView = NSHostingView(rootView: CacheManagerView())
    window.center()
    window.makeKeyAndOrderFront(nil)
    Task { @MainActor in
      try await Task.sleep(for: .seconds(2))
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
      process.arguments = ["-x", "-o", "-l", String(window.windowNumber), "scratch/cache-ui-qa/cache-manager.png"]
      try process.run()
      process.waitUntilExit()
      exit(process.terminationStatus)
    }
    app.run()
  }
}
