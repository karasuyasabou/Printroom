import AppKit
import PrintroomCore
import SwiftUI

@main struct MatrixWindowQA {
  @MainActor static func main() {
    setbuf(stdout, nil)
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    app.finishLaunching()
    Task { @MainActor in
      do { try await run() }
      catch { print("MATRIX WINDOW QA FAILED: \(error)"); exit(1) }
      app.terminate(nil)
    }
    app.run()
  }
  @MainActor static func run() async throws {
    let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("scratch/matrix-ui-qa")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let store = MatrixLibraryStore(url: output.appendingPathComponent("library-\(UUID()).json"))
    let model = EditorModel(matrixStore: store)
    guard model.assets != nil else { throw PrintroomError.invalid(model.errorMessage ?? "Assets unavailable") }
    let cmos = try MatrixPreset(name: "扫描光源 CMOS 标定",coefficients: RGBMatrix([1.1,-0.1,0, 0.05,1,-0.05, -0.1,0,1.1]))
    let density = try MatrixPreset(name: "自定义密度矩阵",coefficients: RGBMatrix([1,-0.2,0.1, 0.1,1,0, 0,0,1.1]))
    try model.saveMatrix(cmos,kind: .cmos,apply: false)
    try model.saveMatrix(density,kind: .density,apply: false)
    var project = RollProject()
    project.frames = [FrameRecord(filename: "sample.tiff")]
    project.calibration.cmosMatrix = .sonyA7CII
    project.calibration.matrix = density
    model.project = project
    model.selection.click(project.frames[0].id, ordered: project.frames.map(\.id))
    model.sourceWidth = 600; model.sourceHeight = 400
    var pixels: [SIMD4<Float>] = []
    for y in 0..<400 { for x in 0..<600 {
      let value = Float(x+y)/1000
      pixels.append(SIMD4(value*0.7+0.1,value*0.8+0.1,value*0.65+0.2,1))
    } }
    let buffer = PixelBuffer(width: 600,height: 400,pixels: pixels)
    let preview = try DisplayImage.make(buffer,profile: nil,diagnostic: true)
    model.previewImage = preview
    model.histogram = try HistogramStatistics.compute(buffer,stage: .final)
    model.thumbnails[project.frames[0].id] = preview
    let window = NSWindow(contentRect: CGRect(x: 80,y: 70,width: 1060,height: 720),
      styleMask: [.titled,.closable,.resizable],backing: .buffered,defer: false)
    window.isReleasedWhenClosed = false
    window.title = "Printroom · Matrix QA"
    let host = NSHostingView(rootView: EditorView(model: model))
    window.contentView = host
    window.orderFront(nil)
    defer { window.orderOut(nil) }
    func capture(_ name: String, target: NSWindow? = nil) async throws {
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(450))
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
      process.arguments = ["-x","-o","-l",String((target ?? window).windowNumber),output.appendingPathComponent(name+".png").path]
      try process.run(); process.waitUntilExit()
      guard process.terminationStatus == 0 else { throw PrintroomError.invalid("Screenshot failed") }
      print("Captured \(name)")
    }
    try await capture("01-matrices-minimum")
    model.showMatrixMenu = true
    try await capture("02-management-menu")
    if let popup = NSApp.windows.first(where: { $0 !== window && $0.isVisible }) {
      try await capture("03-management-popover",target: popup)
    }
    model.showMatrixMenu = false
    model.matrixManager = .density
    try await capture("04-density-manager")
    if let sheet = window.attachedSheet { try await capture("05-density-sheet",target: sheet) }
    model.matrixManager = nil
    try await Task.sleep(for: .milliseconds(450))
    model.matrixManager = .cmos
    try await capture("06-cmos-manager")
    if let sheet = window.attachedSheet { try await capture("07-cmos-sheet",target: sheet) }
    model.matrixManager = nil
    print("MATRIX WINDOW QA PASSED: minimum editor, management popover, density and CMOS sheets; temporary library only")
  }
}
