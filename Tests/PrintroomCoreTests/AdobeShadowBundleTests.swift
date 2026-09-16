import Foundation
import XCTest
@testable import PrintroomCore

final class AdobeShadowBundleTests: XCTestCase, @unchecked Sendable {
  func testShadowLinksOriginalAssetsAndChangesOnlyCopiedLaunchPolicy() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("printroom-shadow-fixture-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let contents = root.appendingPathComponent("Adobe.app/Contents")
    for name in ["MacOS", "Resources", "Frameworks"] {
      try FileManager.default.createDirectory(at: contents.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    let executable = contents.appendingPathComponent("MacOS/Converter")
    let originalProgram = Data("original executable".utf8)
    try originalProgram.write(to: executable)
    let infoURL = contents.appendingPathComponent("Info.plist")
    let info: [String: Any] = ["CFBundleExecutable": "Converter", "CFBundleIdentifier": "studio.printroom.adobe-fixture", "LSUIElement": false]
    let originalInfo = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try originalInfo.write(to: infoURL)
    let installation = AdobeRAWInstallation(executable: executable, version: "test")
    let shadow = try AdobeShadowBundle.executable(for: installation)
    XCTAssertEqual(try AdobeShadowBundle.executable(for: installation), shadow)
    XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: shadow.path), executable.path)
    let shadowContents = shadow.deletingLastPathComponent().deletingLastPathComponent()
    for name in ["Resources", "Frameworks"] {
      XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: shadowContents.appendingPathComponent(name).path), contents.appendingPathComponent(name).path)
    }
    let copied = try PropertyListSerialization.propertyList(from: Data(contentsOf: shadowContents.appendingPathComponent("Info.plist")), format: nil) as! [String: Any]
    XCTAssertEqual(copied["LSUIElement"] as? Bool, true)
    XCTAssertEqual(copied["CFBundleIdentifier"] as? String, info["CFBundleIdentifier"] as? String)
    XCTAssertEqual(try Data(contentsOf: executable), originalProgram)
    XCTAssertEqual(try Data(contentsOf: infoURL), originalInfo)
  }
  func testInvalidApplicationDoesNotFallBackToVisibleExecutable() {
    XCTAssertThrowsError(try AdobeShadowBundle.executable(for: .init(executable: URL(fileURLWithPath: "/bin/sh"), version: "invalid")))
  }
}
