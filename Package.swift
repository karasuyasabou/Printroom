// swift-tools-version: 6.0
import PackageDescription

var products: [Product] = [
  .library(name: "PrintroomCore", targets: ["PrintroomCore"]),
]
#if os(macOS)
products.append(.executable(name: "Printroom", targets: ["PrintroomApp"]))
#endif

var targets: [Target] = [
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
      .define("_ALLOW_COMPILER_AND_STL_VERSION_MISMATCH", .when(platforms: [.windows])),
    ],
    linkerSettings: [
      .linkedLibrary("ws2_32", .when(platforms: [.windows])),
    ]),
  .target(
    name: "CRawBridge",
    dependencies: ["LibRaw"],
    cxxSettings: [
      .headerSearchPath("../../ThirdParty/LibRaw"),
      .define("LIBRAW_NODLL"),
      .define("_ALLOW_COMPILER_AND_STL_VERSION_MISMATCH", .when(platforms: [.windows])),
    ]),
  .target(
    name: "CWinPlatform",
    path: "Sources/CWinPlatform",
    publicHeadersPath: "include"),
  .target(
    name: "PrintroomCore",
    dependencies: [
      "CRawBridge",
      "CLibDeflate",
      .target(name: "CWinPlatform", condition: .when(platforms: [.windows])),
    ],
    resources: [.process("Resources")]),
  .testTarget(name: "PrintroomCoreTests", dependencies: ["PrintroomCore"]),
]

#if os(macOS)
targets.append(contentsOf: [
  .executableTarget(name: "PrintroomApp", dependencies: ["PrintroomCore"]),
  .testTarget(name: "PrintroomAppTests", dependencies: ["PrintroomApp", "PrintroomCore"]),
])
#endif

let package = Package(
  name: "Printroom",
  platforms: [.macOS(.v14)],
  products: products,
  targets: targets,
  cxxLanguageStandard: .cxx17
)
