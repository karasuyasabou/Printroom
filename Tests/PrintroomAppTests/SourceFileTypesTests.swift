import Foundation
import PrintroomCore
import Testing
import UniformTypeIdentifiers
@testable import PrintroomApp

struct SourceFileTypesTests {
  @Test func sourcePickersIncludeAllRecognizedRAWExtensionsAndTIFF() throws {
    let types = SourceImageIO.supportedContentTypes
    #expect(types.contains(.tiff))
    for ext in SourceImageIO.rawFileExtensions {
      let type = try #require(UTType(filenameExtension: ext, conformingTo: .rawImage))
      #expect(types.contains(type), "Source picker omits \(ext)")
      #expect(type.conforms(to: .rawImage))
    }
    for ext in ["jpg", "png", "heic", "mov", "json"] {
      let type = try #require(UTType(filenameExtension: ext))
      #expect(!types.contains(type))
      #expect(!SourceImageIO.isSupportedSource(URL(fileURLWithPath: "source.\(ext)")))
    }
  }
}
