// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Printroom",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "PrintroomCore", targets: ["PrintroomCore"]),
    .executable(name: "Printroom", targets: ["PrintroomApp"]),
  ],
  targets: [
    .target(name: "PrintroomCore", resources: [.process("Resources")]),
    .executableTarget(name: "PrintroomApp", dependencies: ["PrintroomCore"]),
    .testTarget(name: "PrintroomCoreTests", dependencies: ["PrintroomCore"]),
    .testTarget(name: "PrintroomAppTests", dependencies: ["PrintroomApp", "PrintroomCore"]),
  ]
)
