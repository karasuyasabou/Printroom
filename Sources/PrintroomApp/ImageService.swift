import Foundation
import PrintroomCore

actor ImageService {
  private var cachedURL: URL?
  private var cachedImage: LinearImage?
  private var cachedModification: Date?
  private var cachedSize: Int?
  func load(_ url: URL) throws -> LinearImage {
    try Task.checkCancellation()
    // URL.resourceValues may return its own cached metadata after a same-path replacement.
    let metadata = try FileManager.default.attributesOfItem(atPath: url.path)
    let modification = metadata[.modificationDate] as? Date
    let size = (metadata[.size] as? NSNumber)?.intValue
    if cachedURL == url, cachedModification == modification, cachedSize == size, let cachedImage {
      return cachedImage
    }
    cachedImage = nil
    cachedURL = nil
    let image = try TIFFCodec.read(url: url)
    try Task.checkCancellation()
    cachedURL = url
    cachedImage = image
    cachedModification = modification
    cachedSize = size
    return image
  }
  func clear() {
    cachedImage = nil
    cachedURL = nil
  }
  func preview(_ url: URL) throws -> (PixelBuffer, Int, Int, String) {
    let image = try load(url)
    return (image.preview(maxDimension: 1600), image.width, image.height, image.embeddedProfileName)
  }
  func sample(_ url: URL, rect: PixelRect, matrix: PrintDensityMatrix, frameID: UUID) throws -> (
    FilmCalibration, CalibrationDiagnostics
  ) {
    let image = try load(url)
    return (
      try Pipeline.calibrate(image: image, rect: rect, matrix: matrix, sourceFrameID: frameID),
      try Pipeline.calibrationDiagnostics(image: image, rect: rect)
    )
  }
  func pixel(_ url: URL, x: Int, y: Int) throws -> SIMD3<Float> {
    let image = try load(url)
    return image.pixel(x: max(0, min(image.width - 1, x)), y: max(0, min(image.height - 1, y)))
  }
  func export(
    source: URL, destination: URL, calibration: FilmCalibration, adjustments: FrameAdjustments,
    assets: AppAssets, progress: @Sendable @escaping (Double) -> Void
  ) throws {
    guard
      source.standardizedFileURL.resolvingSymlinksInPath()
        != destination.standardizedFileURL.resolvingSymlinksInPath()
    else { throw PrintroomError.invalid("导出不能覆盖原始 TIFF") }
    let image = try load(source)
    try TIFFCodec.write(
      url: destination, width: image.width, height: image.height, profile: assets.profile
    ) { range in
      try Task.checkCancellation()
      var pixels = [SIMD4<Float>]()
      pixels.reserveCapacity(image.width * range.count)
      for y in range {
        for x in 0..<image.width { pixels.append(SIMD4(image.pixel(x: x, y: y), 1)) }
      }
      let out = try assets.gpu.render(
        PixelBuffer(width: image.width, height: range.count, pixels: pixels),
        calibration: calibration, adjustments: adjustments, lut: assets.lut)
      var samples = [UInt16]()
      samples.reserveCapacity(out.pixels.count * 3)
      for p in out.pixels {
        for c in 0..<3 { samples.append(UInt16(floor(min(1, max(0, p[c])) * 65535 + 0.5))) }
      }
      progress(Double(range.upperBound) / Double(image.height))
      return samples
    }
    progress(1)
  }
}
