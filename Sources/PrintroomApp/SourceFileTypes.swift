import PrintroomCore
import UniformTypeIdentifiers

extension SourceImageIO {
  /// Derive both source pickers from the same formats used by project discovery.
  static var supportedContentTypes: [UTType] {
    [.tiff] + rawFileExtensions.compactMap {
      UTType(filenameExtension: $0, conformingTo: .rawImage)
    }
  }
}
