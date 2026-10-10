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
    .target(
      name: "CLibDeflate", path: "ThirdParty/libdeflate",
      exclude: ["COPYING", "README.md", "ORIGIN.md"],
      sources: ["lib"], publicHeadersPath: "include",
      cSettings: [.headerSearchPath(".")]),
    .target(
      name: "LibRaw", path: "ThirdParty/LibRaw",
      exclude: [
        "COPYRIGHT", "LICENSE.CDDL", "LICENSE.LGPL", "ORIGIN.md", "src/Makefile",
        // Alternative placeholder implementations are not in upstream Makefile.am.
        "src/postprocessing/postprocessing_ph.cpp", "src/preprocessing/preprocessing_ph.cpp",
        "src/write/write_ph.cpp",
      ],
      sources: ["src"], publicHeadersPath: "libraw",
      cxxSettings: [
        .headerSearchPath("."), .define("LIBRAW_NODLL"), .define("LIBRAW_NO_JASPER"),
        .define("LIBRAW_NO_LCMS"), .define("LIBRAW_NO_JPEG"),
      ]),
    .target(name: "CRawBridge", dependencies: ["LibRaw"], cxxSettings: [.headerSearchPath("../../ThirdParty/LibRaw")]),
    .target(name: "PrintroomCore", dependencies: ["CRawBridge", "CLibDeflate"], resources: [.process("Resources")]),
    .executableTarget(name: "PrintroomApp", dependencies: ["PrintroomCore"]),
    .testTarget(name: "PrintroomCoreTests", dependencies: ["PrintroomCore"]),
    .testTarget(name: "PrintroomAppTests", dependencies: ["PrintroomApp", "PrintroomCore"]),
  ],
  cxxLanguageStandard: .cxx17
)
