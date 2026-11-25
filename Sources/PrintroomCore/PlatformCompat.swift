import Foundation

#if os(Windows)
import CWinPlatform
#endif

#if !canImport(ObjectiveC)
@inline(__always)
public func autoreleasepool<T>(_ body: () throws -> T) rethrows -> T {
  try body()
}
#endif

#if !canImport(CoreGraphics)
public typealias CGFloat = Double

public struct CGPoint: Equatable, Hashable, Sendable {
  public var x: CGFloat
  public var y: CGFloat
  public static let zero = CGPoint(x: 0, y: 0)
  public init(x: CGFloat = 0, y: CGFloat = 0) {
    self.x = x
    self.y = y
  }
  public init(x: Int, y: Int) {
    self.x = CGFloat(x)
    self.y = CGFloat(y)
  }
}

public struct CGSize: Equatable, Hashable, Sendable {
  public var width: CGFloat
  public var height: CGFloat
  public static let zero = CGSize(width: 0, height: 0)
  public init(width: CGFloat = 0, height: CGFloat = 0) {
    self.width = width
    self.height = height
  }
  public init(width: Int, height: Int) {
    self.width = CGFloat(width)
    self.height = CGFloat(height)
  }
}

public struct CGRect: Equatable, Hashable, Sendable {
  public var origin: CGPoint
  public var size: CGSize
  public static let zero = CGRect(x: 0, y: 0, width: 0, height: 0)
  public var minX: CGFloat { origin.x }
  public var minY: CGFloat { origin.y }
  public var maxX: CGFloat { origin.x + size.width }
  public var maxY: CGFloat { origin.y + size.height }
  public var midX: CGFloat { origin.x + size.width / 2 }
  public var midY: CGFloat { origin.y + size.height / 2 }
  public var width: CGFloat { size.width }
  public var height: CGFloat { size.height }
  public init(origin: CGPoint = .zero, size: CGSize = .zero) {
    self.origin = origin
    self.size = size
  }
  public init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
    self.origin = CGPoint(x: x, y: y)
    self.size = CGSize(width: width, height: height)
  }
  public init(x: Int, y: Int, width: Int, height: Int) {
    self.origin = CGPoint(x: x, y: y)
    self.size = CGSize(width: width, height: height)
  }
}
#endif

#if !canImport(simd)
/// Column-major 3x3 Double matrix matching Apple simd_double3x3 semantics.
public struct simd_double3x3: Equatable, Sendable {
  public var columns: (SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.columns.0 == rhs.columns.0
      && lhs.columns.1 == rhs.columns.1
      && lhs.columns.2 == rhs.columns.2
  }

  public init() {
    self.columns = (.zero, .zero, .zero)
  }

  public init(_ diagonal: Double) {
    self.columns = (
      SIMD3(diagonal, 0, 0),
      SIMD3(0, diagonal, 0),
      SIMD3(0, 0, diagonal)
    )
  }

  public init(columns: (SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)) {
    self.columns = columns
  }

  public init(rows: [SIMD3<Double>]) {
    precondition(rows.count == 3)
    self.columns = (
      SIMD3(rows[0].x, rows[1].x, rows[2].x),
      SIMD3(rows[0].y, rows[1].y, rows[2].y),
      SIMD3(rows[0].z, rows[1].z, rows[2].z)
    )
  }

  public subscript(column: Int) -> SIMD3<Double> {
    get {
      switch column {
      case 0: return columns.0
      case 1: return columns.1
      case 2: return columns.2
      default: fatalError("simd_double3x3 column out of range")
      }
    }
    set {
      switch column {
      case 0: columns.0 = newValue
      case 1: columns.1 = newValue
      case 2: columns.2 = newValue
      default: fatalError("simd_double3x3 column out of range")
      }
    }
  }

  public var transpose: simd_double3x3 {
    simd_double3x3(columns: (
      SIMD3(columns.0.x, columns.1.x, columns.2.x),
      SIMD3(columns.0.y, columns.1.y, columns.2.y),
      SIMD3(columns.0.z, columns.1.z, columns.2.z)
    ))
  }

  public var determinant: Double {
    let a = columns.0, b = columns.1, c = columns.2
    return a.x * (b.y * c.z - b.z * c.y)
      - b.x * (a.y * c.z - a.z * c.y)
      + c.x * (a.y * b.z - a.z * b.y)
  }

  public var inverse: simd_double3x3 {
    let a = columns.0, b = columns.1, c = columns.2
    let r0 = SIMD3(
      b.y * c.z - b.z * c.y,
      b.z * c.x - b.x * c.z,
      b.x * c.y - b.y * c.x
    )
    let r1 = SIMD3(
      c.y * a.z - c.z * a.y,
      c.z * a.x - c.x * a.z,
      c.x * a.y - c.y * a.x
    )
    let r2 = SIMD3(
      a.y * b.z - a.z * b.y,
      a.z * b.x - a.x * b.z,
      a.x * b.y - a.y * b.x
    )
    let det = a.x * r0.x + a.y * r0.y + a.z * r0.z
    let invDet = 1.0 / det
    return simd_double3x3(columns: (
      SIMD3(r0.x, r1.x, r2.x) * invDet,
      SIMD3(r0.y, r1.y, r2.y) * invDet,
      SIMD3(r0.z, r1.z, r2.z) * invDet
    ))
  }

  public static func * (lhs: simd_double3x3, rhs: SIMD3<Double>) -> SIMD3<Double> {
    lhs.columns.0 * rhs.x + lhs.columns.1 * rhs.y + lhs.columns.2 * rhs.z
  }

  public static func * (lhs: simd_double3x3, rhs: simd_double3x3) -> simd_double3x3 {
    simd_double3x3(columns: (
      lhs * rhs.columns.0,
      lhs * rhs.columns.1,
      lhs * rhs.columns.2
    ))
  }
}

@inline(__always)
public func simd_clamp(_ x: SIMD3<Double>, _ minVal: SIMD3<Double>, _ maxVal: SIMD3<Double>) -> SIMD3<Double> {
  SIMD3(
    min(max(x.x, minVal.x), maxVal.x),
    min(max(x.y, minVal.y), maxVal.y),
    min(max(x.z, minVal.z), maxVal.z)
  )
}

@inline(__always)
public func simd_length_squared(_ v: SIMD3<Double>) -> Double {
  v.x * v.x + v.y * v.y + v.z * v.z
}
#endif

#if !canImport(CryptoKit)
/// Standard FIPS 180-4 SHA-256 implementation matching CryptoKit's API surface used in Printroom.
public struct SHA256: Sendable {
  private static let k: [UInt32] = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ]

  private var state: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32) = (
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
  )
  private var buffer = [UInt8]()
  private var totalBytes: UInt64 = 0

  public init() {
    buffer.reserveCapacity(64)
  }

  public mutating func update<D: DataProtocol>(data: D) {
    for region in data.regions {
      region.withUnsafeBytes { raw in
        updateBytes(raw.bindMemory(to: UInt8.self))
      }
    }
  }

  private mutating func updateBytes(_ bytes: UnsafeBufferPointer<UInt8>) {
    guard let base = bytes.baseAddress, !bytes.isEmpty else { return }
    totalBytes += UInt64(bytes.count)
    var offset = 0
    if !buffer.isEmpty {
      let needed = min(64 - buffer.count, bytes.count)
      buffer.append(contentsOf: UnsafeBufferPointer(start: base, count: needed))
      offset += needed
      if buffer.count == 64 {
        buffer.withUnsafeBufferPointer { compress($0.baseAddress!) }
        buffer.removeAll(keepingCapacity: true)
      }
    }
    while offset + 64 <= bytes.count {
      compress(base.advanced(by: offset))
      offset += 64
    }
    if offset < bytes.count {
      buffer.append(contentsOf: UnsafeBufferPointer(start: base.advanced(by: offset), count: bytes.count - offset))
    }
  }

  public func finalize() -> [UInt8] {
    var copy = self
    let bitLength = copy.totalBytes &* 8
    copy.buffer.append(0x80)
    if copy.buffer.count > 56 {
      while copy.buffer.count < 64 { copy.buffer.append(0) }
      copy.buffer.withUnsafeBufferPointer { copy.compress($0.baseAddress!) }
      copy.buffer.removeAll(keepingCapacity: true)
    }
    while copy.buffer.count < 56 { copy.buffer.append(0) }
    var bigLen = bitLength.bigEndian
    withUnsafeBytes(of: &bigLen) { copy.buffer.append(contentsOf: $0) }
    copy.buffer.withUnsafeBufferPointer { copy.compress($0.baseAddress!) }
    var digest = [UInt8]()
    digest.reserveCapacity(32)
    for word in [
      copy.state.0, copy.state.1, copy.state.2, copy.state.3,
      copy.state.4, copy.state.5, copy.state.6, copy.state.7,
    ] {
      var be = word.bigEndian
      withUnsafeBytes(of: &be) { digest.append(contentsOf: $0) }
    }
    return digest
  }

  public static func hash<D: DataProtocol>(data: D) -> [UInt8] {
    var hasher = SHA256()
    hasher.update(data: data)
    return hasher.finalize()
  }

  @inline(__always)
  private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 {
    (x >> n) | (x << (32 - n))
  }

  private mutating func compress(_ block: UnsafePointer<UInt8>) {
    var w = [UInt32](repeating: 0, count: 64)
    for i in 0..<16 {
      let o = i * 4
      w[i] = (UInt32(block[o]) << 24)
        | (UInt32(block[o + 1]) << 16)
        | (UInt32(block[o + 2]) << 8)
        | UInt32(block[o + 3])
    }
    for i in 16..<64 {
      let s0 = Self.rotr(w[i - 15], 7) ^ Self.rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
      let s1 = Self.rotr(w[i - 2], 17) ^ Self.rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
      w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
    }
    var (a, b, c, d, e, f, g, h) = state
    for i in 0..<64 {
      let S1 = Self.rotr(e, 6) ^ Self.rotr(e, 11) ^ Self.rotr(e, 25)
      let ch = (e & f) ^ ((~e) & g)
      let temp1 = h &+ S1 &+ ch &+ Self.k[i] &+ w[i]
      let S0 = Self.rotr(a, 2) ^ Self.rotr(a, 13) ^ Self.rotr(a, 22)
      let maj = (a & b) ^ (a & c) ^ (b & c)
      let temp2 = S0 &+ maj
      h = g; g = f; f = e; e = d &+ temp1
      d = c; c = b; b = a; a = temp1 &+ temp2
    }
    state.0 = state.0 &+ a
    state.1 = state.1 &+ b
    state.2 = state.2 &+ c
    state.3 = state.3 &+ d
    state.4 = state.4 &+ e
    state.5 = state.5 &+ f
    state.6 = state.6 &+ g
    state.7 = state.7 &+ h
  }
}
#endif

#if os(Windows)
enum PlatformFS {
  struct FileStat {
    let size: Int64
    let mtimeSec: Int64
    let mtimeNsec: Int64
    let fileID: UInt64
    let isRegular: Bool
    let isDirectory: Bool
    let isReparse: Bool
  }

  static func formatError(_ code: UInt32) -> String {
    var buf = [CChar](repeating: 0, count: 512)
    pr_win_format_error(code, &buf, buf.count)
    return buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
  }

  static func withPath<T>(_ url: URL, _ body: (UnsafePointer<CChar>) throws -> T) throws -> T {
    try url.withUnsafeFileSystemRepresentation { ptr in
      guard let ptr else { throw PrintroomError.invalid("无效文件路径：\(url.path)") }
      return try body(ptr)
    }
  }

  static func lstat(_ url: URL) throws -> FileStat? {
    var raw = PRWinFileStat()
    var err: UInt32 = 0
    let status = try withPath(url) { pr_win_lstat($0, &raw, &err) }
    if status == 1 { return nil }
    guard status == 0 else {
      throw PrintroomError.invalid("无法读取文件属性（\(url.lastPathComponent)）：\(formatError(err))")
    }
    return FileStat(
      size: raw.size,
      mtimeSec: raw.mtime_sec,
      mtimeNsec: raw.mtime_nsec,
      fileID: raw.file_id,
      isRegular: raw.is_regular != 0,
      isDirectory: raw.is_directory != 0,
      isReparse: raw.is_reparse != 0
    )
  }

  static func pathExistsNoFollow(_ url: URL) throws -> Bool {
    var err: UInt32 = 0
    let status = try withPath(url) { pr_win_path_exists_nofollow($0, &err) }
    guard status >= 0 else {
      throw PrintroomError.invalid("无法检查路径（\(url.lastPathComponent)）：\(formatError(err))")
    }
    return status == 1
  }

  static func openRead(_ url: URL) throws -> Int {
    var err: UInt32 = 0
    let handle = try withPath(url) { pr_win_open_read($0, &err) }
    guard handle != -1 else {
      throw PrintroomError.invalid("无法打开文件（\(url.lastPathComponent)）：\(formatError(err))")
    }
    return handle
  }

  static func pread(handle: Int, offset: UInt64, count: Int) throws -> Data {
    var result = Data(count: count)
    if count == 0 { return result }
    var err: UInt32 = 0
    let readBytes = result.withUnsafeMutableBytes { buf in
      pr_win_pread(handle, offset, buf.baseAddress, count, &err)
    }
    guard readBytes >= 0 else {
      throw PrintroomError.invalid("无法读取文件：\(formatError(err))")
    }
    guard readBytes == count else {
      throw PrintroomError.invalid("TIFF 文件意外截断。")
    }
    return result
  }

  static func openTempExclusive(_ url: URL) throws -> Int {
    var err: UInt32 = 0
    let handle = try withPath(url) { pr_win_open_temp_excl($0, &err) }
    guard handle != -1 else {
      throw PrintroomError.invalid("无法创建临时文件（\(url.lastPathComponent)）：\(formatError(err))")
    }
    return handle
  }

  static func writeAll(handle: Int, data: Data) throws {
    var err: UInt32 = 0
    let ok = data.withUnsafeBytes { buf in
      pr_win_write_all(handle, buf.baseAddress, data.count, &err)
    }
    guard ok == 0 else {
      throw PrintroomError.invalid("无法写入文件：\(formatError(err))")
    }
  }

  static func pwriteAll(handle: Int, offset: UInt64, data: Data) throws {
    var err: UInt32 = 0
    let ok = data.withUnsafeBytes { buf in
      pr_win_pwrite_all(handle, offset, buf.baseAddress, data.count, &err)
    }
    guard ok == 0 else {
      throw PrintroomError.invalid("无法更新文件头：\(formatError(err))")
    }
  }

  static func flushAndClose(handle: Int) throws {
    var err: UInt32 = 0
    let ok = pr_win_flush_close(handle, &err)
    guard ok == 0 else {
      throw PrintroomError.invalid("无法刷新并关闭文件：\(formatError(err))")
    }
  }

  static func close(handle: Int) {
    pr_win_close(handle)
  }

  static func moveExclusive(from source: URL, to destination: URL) throws {
    var err: UInt32 = 0
    let status = try withPath(source) { src in
      try withPath(destination) { dst in
        pr_win_move_excl(src, dst, &err)
      }
    }
    if status == 1 {
      throw TIFFWriteError.destinationExists(destination.lastPathComponent)
    }
    guard status == 0 else {
      throw PrintroomError.invalid("无法发布文件（\(destination.lastPathComponent)）：\(formatError(err))")
    }
  }

  static func moveReplace(from source: URL, to destination: URL) throws {
    var err: UInt32 = 0
    let status = try withPath(source) { src in
      try withPath(destination) { dst in
        pr_win_move_replace(src, dst, &err)
      }
    }
    guard status == 0 else {
      throw PrintroomError.invalid("无法原子替换文件（\(destination.lastPathComponent)）：\(formatError(err))")
    }
  }

  static func atomicWrite(_ data: Data, to destination: URL) throws {
    let temp = destination.deletingLastPathComponent()
      .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
    let handle = try openTempExclusive(temp)
    var closed = false
    defer {
      if !closed { PlatformFS.close(handle: handle) }
      try? FileManager.default.removeItem(at: temp)
    }
    try writeAll(handle: handle, data: data)
    try flushAndClose(handle: handle)
    closed = true
    try moveReplace(from: temp, to: destination)
  }

  static func openLock(_ url: URL) throws -> Int {
    var err: UInt32 = 0
    let handle = try withPath(url) { pr_win_lock_open($0, &err) }
    guard handle != -1 else {
      throw PrintroomError.invalid("无法锁定代理缓存目录：\(formatError(err))")
    }
    return handle
  }

  /// Returns true if acquired, false if contended, throws on unexpected error.
  static func tryLock(handle: Int, exclusive: Bool) throws -> Bool {
    var err: UInt32 = 0
    let status = pr_win_lock_try(handle, exclusive ? 1 : 0, &err)
    if status == 0 { return true }
    if status == 1 { return false }
    throw PrintroomError.invalid("代理缓存锁定失败：\(formatError(err))")
  }

  static func closeLock(handle: Int) {
    pr_win_lock_close(handle)
  }

  static func normalizedPathKey(_ url: URL) -> String {
    var p = url.standardizedFileURL.resolvingSymlinksInPath().path
      .replacingOccurrences(of: "\\", with: "/")
    while p.count > 1 && p.hasSuffix("/") {
      if p.count == 3 && p.dropFirst().hasPrefix(":/") { break }
      p.removeLast()
    }
    return p.lowercased()
  }

  static func sameDirectory(_ lhs: URL, _ rhs: URL) -> Bool {
    normalizedPathKey(lhs) == normalizedPathKey(rhs)
  }

  private static func splitDate(_ date: Date) -> (sec: Int64, nsec: Int64) {
    let interval = date.timeIntervalSince1970
    let secFloat = floor(interval)
    let sec = Int64(secFloat)
    let nsec = Int64(((interval - secFloat) * 1_000_000_000.0).rounded())
    if nsec >= 1_000_000_000 {
      return (sec + 1, nsec - 1_000_000_000)
    }
    return (sec, max(0, nsec))
  }

  static func getFileDates(_ url: URL) throws -> (creation: Date?, modification: Date?) {
    var hasC: Int32 = 0, cSec: Int64 = 0, cNsec: Int64 = 0
    var hasM: Int32 = 0, mSec: Int64 = 0, mNsec: Int64 = 0
    var err: UInt32 = 0
    let ok = try withPath(url) { path in
      pr_win_get_file_dates(path, &hasC, &cSec, &cNsec, &hasM, &mSec, &mNsec, &err)
    }
    guard ok == 0 else {
      throw PrintroomError.invalid("无法读取文件日期（\(url.lastPathComponent)）：\(formatError(err))")
    }
    let creation = hasC != 0 ? Date(timeIntervalSince1970: Double(cSec) + Double(cNsec) / 1_000_000_000.0) : nil
    let modification = hasM != 0 ? Date(timeIntervalSince1970: Double(mSec) + Double(mNsec) / 1_000_000_000.0) : nil
    return (creation, modification)
  }

  static func setFileDates(_ url: URL, creation: Date?, modification: Date?) throws {
    if creation == nil && modification == nil { return }
    let c = creation.map(splitDate) ?? (sec: Int64(0), nsec: Int64(0))
    let m = modification.map(splitDate) ?? (sec: Int64(0), nsec: Int64(0))
    var err: UInt32 = 0
    let ok = try withPath(url) { path in
      pr_win_set_file_dates(
        path,
        creation != nil ? 1 : 0, c.sec, c.nsec,
        modification != nil ? 1 : 0, m.sec, m.nsec,
        &err
      )
    }
    guard ok == 0 else {
      throw PrintroomError.invalid("无法设置文件日期（\(url.lastPathComponent)）：\(formatError(err))")
    }
  }
}
#endif
