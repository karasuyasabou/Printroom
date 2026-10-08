import Foundation
import XCTest
@testable import PrintroomCore

final class MatrixTests: XCTestCase {
  private func folder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("printroom-matrix-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }
  private func lut() throws -> CubeLUT {
    var pixels: [SIMD4<Float>] = []
    for i in 0..<8 { pixels.append(SIMD4<Float>(Float(i & 1), Float((i >> 1) & 1), Float((i >> 2) & 1), 1)) }
    return try CubeLUT(size: 2, values: pixels)
  }
  private func preset(_ values: [Float], name: String = "Test") throws -> MatrixPreset {
    try MatrixPreset(name: name, coefficients: RGBMatrix(values))
  }
  private func rgb(_ actual: SIMD3<Float>, _ expected: SIMD3<Float>, tolerance: Float = 1e-6,
                   file: StaticString = #filePath, line: UInt = #line) {
    for c in 0..<3 { XCTAssertEqual(actual[c], expected[c], accuracy: tolerance, file: file, line: line) }
  }
  func testSonyBuiltinPreservesNPYCoefficientsAndCompatibleSnapshot() throws {
    let sony = MatrixPreset.sonyA7CII
    let expected: [Float] = [1.1466704233413691,-0.11124903420598868,-0.035421389135380503,
      -0.22858890193068157,1.7070179367809262,-0.47842903485024479,
      -0.016680585423849963,-0.23594647294799959,1.2526270583718495]
    XCTAssertEqual(sony.coefficients.values, expected)
    XCTAssertTrue(sony.isBuiltIn)
    XCTAssertTrue(MatrixKind.cmos.builtIns.contains(sony))
    XCTAssertFalse(MatrixKind.density.builtIns.contains(sony))
    let data = try JSONEncoder().encode(sony)
    struct LegacySnapshot: Decodable { let id: String; let name: String; let coefficients: RGBMatrix }
    XCTAssertEqual(try JSONDecoder().decode(LegacySnapshot.self, from: data).coefficients, sony.coefficients)
    XCTAssertEqual(try JSONDecoder().decode(MatrixPreset.self, from: data), sony)
    XCTAssertThrowsError(try MatrixPreset(id: sony.id, name: sony.name, coefficients: .identity))
    XCTAssertThrowsError(try MatrixPreset(id: sony.id.lowercased(), name: "Override", coefficients: sony.coefficients))
    let store = MatrixLibraryStore(url: try folder().appendingPathComponent("library.json"))
    XCTAssertThrowsError(try store.save([.init(kind: .cmos, preset: sony)], replacing: []))
    let copy = try MatrixPreset(name: "Copy", coefficients: sony.coefficients)
    XCTAssertFalse(copy.isBuiltIn)
  }
  func testRealRAWCalibrationUsesProxy() throws {
    guard ProcessInfo.processInfo.environment["PRINTROOM_CMOS_RAW_TEST"] == "1" else {
      throw XCTSkip("Requires local Adobe DNG Converter and TEST/RAW.")
    }
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("TEST/RAW/DSC07119.ARW")
    let rawMeans = try CMOSCalibration.sampleMeans(sources: [url])
    let full = try SourceImageIO.read(url: url)
    let w = full.width / 5, h = full.height / 5
    let proxy = try SourceImageIO.readPreview(url: url, maxDimension: 1600)
    var sum = SIMD3<Double>(repeating: 0)
    for y in (full.height-h)/2..<(full.height+h)/2 {
      for x in (full.width-w)/2..<(full.width+w)/2 {
        let i = ((y * proxy.height / full.height) * proxy.width + x * proxy.width / full.width) * 3
        for c in 0..<3 { sum[c] += Double(proxy.samples[i+c])/65535 }
      }
    }
    for c in 0..<3 { XCTAssertEqual(rawMeans[0][c], sum[c]/Double(w*h), accuracy: 1e-12) }
    let root = try folder()
    let tiff = root.appendingPathComponent("full.tiff")
    try TIFFCodec.write(url: tiff, width: full.width, height: full.height, profile: nil) { rows in
      Array(full.samples[(rows.lowerBound*full.width*3)..<(rows.upperBound*full.width*3)])
    }
    XCTAssertEqual(try CMOSCalibration.sampleMeans(sources: [tiff]).count, 1)
  }
  func testRAWExportRequestsPreserveSourceIdentityAndMatrix() throws {
    for ext in SourceImageIO.rawFileExtensions {
      let root = try folder(), source = root.appendingPathComponent("source.\(ext.uppercased())")
      // Request creation freezes identity only; it must not decode or invoke Adobe.
      try Data([1,2,3]).write(to: source)
      var project = try ProjectStore.open(folder: root)
      project.calibration.cmosMatrix = .sonyA7CII
      let destination = root.appendingPathComponent("out.tiff")
      let single = try ExportRequest(source: source, destination: destination,
        calibration: project.calibration, adjustments: .init())
      let roll = try ExportRequest(project: project, targetIDs: Set(project.frames.map(\.id)),
        destinationDirectory: root)
      for request in [single, roll] {
        XCTAssertEqual(request.calibration.cmosMatrix, .sonyA7CII)
        XCTAssertEqual(request.protectedSourceURLs, [source])
        XCTAssertEqual(request.frames.count, 1)
        XCTAssertNotNil(request.frames[0].rawProcessing, ext)
      }
      XCTAssertEqual(try Data(contentsOf: source), Data([1,2,3]))
    }
  }
  func testCMOSSolverDecouplesColumnsAndPreservesNeutralAndExposureScaling() throws {
    let means = [SIMD3<Double>(0.6,0.05,0.03), SIMD3(0.02,0.5,0.04), SIMD3(0.01,0.02,0.4)]
    let result = try CMOSCalibration.solve(means: [means[2],means[0],means[1]])
    XCTAssertEqual(result.sourceIndices, [1,2,0])
    rgb(result.coefficients.apply(SIMD3(repeating: 1)), SIMD3(repeating: 1))
    for c in 0..<3 {
      let response = result.coefficients.apply(SIMD3<Float>(means[c]))
      for other in 0..<3 where c != other { XCTAssertEqual(response[other], 0, accuracy: 1e-7) }
      XCTAssertGreaterThan(response[c], 0)
    }
    let scaled = try CMOSCalibration.solve(means: [means[0]*0.5, means[1]*1.4, means[2]*1.7])
    for (a,b) in zip(result.coefficients.values, scaled.coefficients.values) { XCTAssertEqual(a,b,accuracy: 1e-6) }
    XCTAssertThrowsError(try CMOSCalibration.solve(means: Array(repeating: SIMD3(0.3,0.3,0.3), count: 3)))
    XCTAssertThrowsError(try CMOSCalibration.solve(means: [SIMD3(.nan,0,0),means[1],means[2]]))
    XCTAssertThrowsError(try CMOSCalibration.solve(means: [SIMD3(1,0,0),means[1],means[2]]))
  }
  func testCMOSTIFFCreationUsesOnlyCentralRegionAndDoesNotChangeFiles() throws {
    let root = try folder()
    let samples: [[UInt16]] = [[40000,3000,2000], [1500,35000,2500], [1000,2000,30000]]
    var urls: [URL] = []
    for i in 0..<3 {
      let url = root.appendingPathComponent("\(i).tiff")
      try TIFFCodec.write(url: url, width: 20, height: 20, profile: nil, compression: .deflate) { rows in
        rows.flatMap { y in (0..<20).flatMap { x in
          (8..<12).contains(x) && (8..<12).contains(y) ? samples[i] : [UInt16(60000),60000,60000]
        } }
      }
      urls.append(url)
    }
    let before = try urls.map { try Data(contentsOf: $0) }
    let result = try CMOSCalibration.make(tiffs: urls)
    XCTAssertEqual(result.sourceIndices, [0,1,2])
    for i in 0..<3 { for c in 0..<3 { XCTAssertEqual(result.means[i][c], Double(samples[i][c])/65535, accuracy: 1e-12) } }
    XCTAssertEqual(try urls.map { try Data(contentsOf: $0) }, before)
    XCTAssertThrowsError(try CMOSCalibration.make(tiffs: [urls[0],urls[0],urls[1]]))
  }
  func testLinearStagesAndDensityFollowIndependentAnalyticOrderWithoutClipping() throws {
    var calibration = FilmCalibration()
    calibration.cmosMatrix = try preset([1,0.2,0, 0,1,0, -0.1,0,1])
    calibration.matrix = try preset([1,-0.1,0, 0.2,1,0, 0,0.3,1])
    calibration.gainRGB = SIMD3(2,3,4)
    let input = SIMD3<Float>(0.2,0.4,0.6)
    let l1 = SIMD3<Float>(0.28,0.4,0.58)
    let l2 = SIMD3<Float>(0.56,1.2,2.32)
    rgb(try Pipeline.process(input, calibration: calibration, adjustments: .init(), stage: .l0), input)
    rgb(try Pipeline.process(input, calibration: calibration, adjustments: .init(), stage: .l1), l1)
    rgb(try Pipeline.process(input, calibration: calibration, adjustments: .init(), stage: .l2), l2)
    let d = SIMD3<Float>(Float(-log10(0.56)/2.048),Float(-log10(1.2)/2.048),Float(-log10(2.32)/2.048))
    rgb(try Pipeline.process(input, calibration: calibration, adjustments: .init(), stage: .d1), SIMD3(d.x-0.1*d.y,0.2*d.x+d.y,0.3*d.y+d.z))
    calibration.cmosMatrix = try preset([1,-2,0, 0,1,0, 0,0,1])
    XCTAssertLessThan(try Pipeline.process(input, calibration: calibration, adjustments: .init(), stage: .l1).x, 0)
  }
  func testCMOSFilmBaseUsesMedianAfterPerPixelMatrixAndFrozenProvenance() throws {
    let groups: [[UInt16]] = [[6554,52428,30000],[13107,13107,30000],[52428,6554,30000],[58982,58982,30000]]
    let image = LinearImage(width: 4, height: 4, samples: groups.flatMap { Array(repeating: $0, count: 4).flatMap { $0 } })
    let cmos = try preset([1,1,0, 0,1,0, 0,0,1])
    let cal = try Pipeline.calibrate(image: image, rect: .init(x: 0,y: 0,width: 4,height: 4),
      matrix: .ledLightSource, sourceFrameID: UUID(), cmosMatrix: cmos)
    let base = try XCTUnwrap(cal.baseRGB)
    XCTAssertEqual(base.x, Float(58982)/65535, accuracy: 1e-6)
    XCTAssertGreaterThan(abs(base.x - 1), 0.09)
    XCTAssertEqual(cal.sampledDensityMatrix, .ledLightSource)
    XCTAssertEqual(cal.sampledCMOSMatrix, cmos)
    rgb(base * cal.gainRGB, SIMD3(repeating: 0.75))
  }
  func testLibraryPersistsAndProtectsBuiltInsCorruptionAndConflicts() throws {
    let root = try folder(), url = root.appendingPathComponent("library/matrices.json")
    let store = MatrixLibraryStore(url: url)
    let original = try preset([1,0,0, 0,1,0, 0,0,1])
    let entries = [MatrixLibraryEntry(kind: .density, preset: original)]
    try store.save(entries, replacing: [])
    XCTAssertEqual(try MatrixLibraryStore(url: url).load(), entries)
    XCTAssertThrowsError(try store.save([], replacing: []))
    XCTAssertThrowsError(try store.save([MatrixLibraryEntry(kind: .density, preset: .identity)], replacing: entries))
    XCTAssertThrowsError(try store.save(entries+entries, replacing: entries))
    try Data("broken".utf8).write(to: url)
    XCTAssertThrowsError(try store.load())
    XCTAssertThrowsError(try store.save([], replacing: entries))
    XCTAssertEqual(try Data(contentsOf: url), Data("broken".utf8))
    XCTAssertThrowsError(try RGBMatrix([1,2]))
    XCTAssertThrowsError(try RGBMatrix(Array(repeating: .nan, count: 9)))
    XCTAssertThrowsError(try MatrixPreset(id: "identity", name: "Override", coefficients: .identity))
  }
  func testProjectSwitchSaveReopenPreservesCalibrationAndMatrixSnapshots() throws {
    let root = try folder()
    try Data([0]).write(to: root.appendingPathComponent("scan.tiff"))
    var project = try ProjectStore.open(folder: root)
    project.calibration = try Pipeline.calibrate(image: LinearImage(width: 4,height: 4,samples: Array(repeating: [UInt16(12000),22000,32000],count: 16).flatMap { $0 }),
      rect: .init(x: 0,y: 0,width: 4,height: 4), matrix: .ledLightSource, sourceFrameID: project.frames[0].id)
    let before = project.calibration
    project.calibration.cmosMatrix = try preset([1,0.2,0, 0,1,0, 0,0,1])
    project.calibration.matrix = try preset([0.8,0,0, 0,0.9,0, 0,0,1.1])
    _ = try ProjectStore.save(project, folder: root, expectedModification: nil)
    let reopened = try ProjectStore.open(folder: root)
    XCTAssertEqual(reopened.calibration, project.calibration)
    XCTAssertEqual(reopened.calibration.gainRGB, before.gainRGB)
    XCTAssertEqual(reopened.calibration.filmBaseOffsetCV, before.filmBaseOffsetCV)
    XCTAssertEqual(reopened.calibration.sampledDensityMatrix, .ledLightSource)
  }
  func testSchemaThreeMigrationKeepsPictureAndBacksUpBeforeOverwrite() throws {
    let root = try folder()
    var project = RollProject()
    project.calibration = FilmCalibration()
    let encoder = JSONEncoder()
    var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(project)) as? [String:Any])
    json["schemaVersion"] = 3; json["algorithmVersion"] = "printroom-density-v2"
    var calibration = try XCTUnwrap(json["calibration"] as? [String:Any])
    for key in ["cmosMatrix","sampledDensityMatrix","sampledCMOSMatrix"] { calibration.removeValue(forKey: key) }
    json["calibration"] = calibration
    let original = try JSONSerialization.data(withJSONObject: json)
    let url = root.appendingPathComponent(ProjectStore.filename)
    try original.write(to: url)
    project = try ProjectStore.open(folder: root)
    XCTAssertEqual(project.schemaVersion, RollProject.currentSchemaVersion)
    XCTAssertEqual(project.calibration.cmosMatrix, .identity)
    XCTAssertEqual(project.calibration.gainRGB, SIMD3(repeating: 1))
    XCTAssertEqual(project.calibration.filmBaseOffsetCV, SIMD3(repeating: 0))
    _ = try ProjectStore.save(project, folder: root, expectedModification: project.loadedModificationDate)
    let backups = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(".printroom-schema3-") }
    XCTAssertEqual(backups.count, 1)
    XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), original)
    var broken = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String:Any])
    var fields = try XCTUnwrap(broken["calibration"] as? [String:Any]); fields.removeValue(forKey: "cmosMatrix"); broken["calibration"] = fields
    try JSONSerialization.data(withJSONObject: broken).write(to: url)
    let repaired = try ProjectStore.open(folder: root)
    XCTAssertEqual(repaired.calibration.cmosMatrix, repaired.calibration.matrix)
  }
  func testCustomMatricesCPUAndMetalStagesAndCacheInvalidation() throws {
    let gpu = try MetalPipeline(), session = gpu.makeSession(), cube = try lut()
    var pixels: [SIMD4<Float>] = []
    for i in 0..<48 {
      let r = Float(i)/47, g = Float((i*7)%48)/47, b = Float((i*17)%48)/47
      pixels.append(SIMD4<Float>(r,g,b,1))
    }
    let input = PixelBuffer(width: 48,height: 1,pixels: pixels)
    let identity = UUID()
    var calibration = FilmCalibration()
    calibration.cmosMatrix = try preset([1.1,-0.2,0.1, 0.05,0.95,0, -0.1,0.2,0.9])
    calibration.matrix = try preset([1.1,-0.1,0.2, 0.1,0.9,0, 0,0.3,0.8])
    calibration.gainRGB = SIMD3(2,1.2,0.7)
    for stage in PipelineStage.allCases {
      let cpu = try Pipeline.render(input, calibration: calibration, adjustments: .init(), lut: cube, stage: stage)
      let metal = try session.render(input, calibration: calibration, adjustments: .init(), lut: cube, stage: stage, inputIdentity: identity)
      for (a,b) in zip(cpu.pixels,metal.pixels) { for c in 0..<3 { XCTAssertEqual(a[c],b[c],accuracy: stage == .final ? 2e-4 : 2e-5+2e-5*abs(a[c])) } }
    }
    let count = session.statistics.densityPasses
    calibration.cmosMatrix = .identity
    _ = try session.render(input,calibration: calibration,adjustments: .init(),lut: cube,inputIdentity: identity)
    XCTAssertEqual(session.statistics.densityPasses,count+1)
    calibration.matrix = .identity
    _ = try session.render(input,calibration: calibration,adjustments: .init(),lut: cube,inputIdentity: identity)
    XCTAssertEqual(session.statistics.densityPasses,count+2)
    calibration.cmosMatrix = try preset(Array(repeating: .greatestFiniteMagnitude, count: 9))
    XCTAssertThrowsError(try session.render(input,calibration: calibration,adjustments: .init(),lut: cube))
    XCTAssertThrowsError(try Pipeline.render(input,calibration: calibration,adjustments: .init(),lut: cube))
  }
}
