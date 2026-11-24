import Foundation
import ImageIO

/// Only timestamps are inherited: source color, orientation and geometry metadata
/// must never describe the rendered output. Missing capture times stay missing.
public struct ExportDates: Sendable {
  var creation: Date?
  var modification: Date?
  var tiffDateTime: String?
  var exif: [String: String] = [:]

  public init() {}

  static let exifTags: [(key: String, tag: UInt16)] = [
    ("DateTimeOriginal", 36867), ("DateTimeDigitized", 36868),
    ("OffsetTime", 36880), ("OffsetTimeOriginal", 36881), ("OffsetTimeDigitized", 36882),
    ("SubsecTime", 37520), ("SubsecTimeOriginal", 37521), ("SubsecTimeDigitized", 37522),
  ]

  static func read(from url: URL) throws -> Self {
    var dates = Self()
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    dates.creation = attributes[.creationDate] as? Date
    dates.modification = attributes[.modificationDate] as? Date
    // ImageIO inspects the original file, never an Adobe conversion or proxy.
    // Unsupported RAW metadata does not prevent preserving filesystem dates.
    guard let source = CGImageSourceCreateWithURL(url as CFURL,
      [kCGImageSourceShouldCache: false] as CFDictionary),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
    else { return dates }
    let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
    dates.tiffDateTime = asciiTimestamp(tiff?[kCGImagePropertyTIFFDateTime as String])
    let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
    for (key, _) in exifTags {
      dates.exif[key] = asciiTimestamp(exif?[key])
    }
    return dates
  }

  private static func asciiTimestamp(_ value: Any?) -> String? {
    guard let text = value as? String, !text.isEmpty, text.utf8.count <= 128,
      text.utf8.allSatisfy({ (32...126).contains($0) }) else { return nil }
    return text
  }

  var imageProperties: [String: Any] {
    var properties: [String: Any] = [:]
    if !exif.isEmpty { properties[kCGImagePropertyExifDictionary as String] = exif }
    if let tiffDateTime {
      properties[kCGImagePropertyTIFFDictionary as String] = [kCGImagePropertyTIFFDateTime as String: tiffDateTime]
    }
    return properties
  }

  /// Apply after all writes, but before atomic publication. Failure keeps the
  /// old destination intact instead of reporting an incompletely dated export.
  func apply(to url: URL) throws {
    var attributes: [FileAttributeKey: Any] = [:]
    if let creation { attributes[.creationDate] = creation }
    if let modification { attributes[.modificationDate] = modification }
    if !attributes.isEmpty {
      try FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
    }
  }
}
