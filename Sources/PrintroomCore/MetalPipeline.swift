import Foundation
@preconcurrency import Metal

/// The same normalized-density contract as PipelineReference; no color conversion.
public final class MetalPipeline: @unchecked Sendable {
  private let device: MTLDevice
  private let queue: MTLCommandQueue
  private let state: MTLComputePipelineState
  private let defaultSession: Session
  public var deviceName: String { device.name }

  public init() throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
      throw PrintroomError.invalid("此设备无法创建 Metal 上下文")
    }
    let options = MTLCompileOptions()
    if #available(macOS 15.0, *) {
      options.mathMode = .safe
    } else {
      options.fastMathEnabled = false
    }
    let library = try device.makeLibrary(source: Self.shader, options: options)
    guard let function = library.makeFunction(name: "printroomPipeline") else {
      throw PrintroomError.invalid("Metal 管线函数缺失")
    }
    let state = try device.makeComputePipelineState(function: function)
    self.device = device
    self.queue = queue
    self.state = state
    self.defaultSession = Session(device: device, queue: queue, state: state)
  }

  /// A lane owns its buffers, so main preview, thumbnails and ROI do not evict
  /// each other's cached source or wait for each other's CPU-side render lock.
  public func makeSession() -> Session {
    Session(device: device, queue: queue, state: state)
  }

  /// Existing export callers keep the full pipeline and reuse bounded buffers.
  public func render(
    _ input: PixelBuffer, calibration: FilmCalibration, adjustments: FrameAdjustments, lut: CubeLUT,
    stage: PipelineStage = .final
  ) throws -> PixelBuffer {
    try defaultSession.render(
      input, calibration: calibration, adjustments: adjustments, lut: lut, stage: stage)
  }

  public final class Session: @unchecked Sendable {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let state: MTLComputePipelineState
    private let lock = NSLock()
    // At most one source, result and D1 per lane, each capped at 40 MiB retained.
    // Larger 1:1 requests are supported but their buffers are released after use.
    private static let retainedPixelByteLimit = 1600 * 1600 * MemoryLayout<SIMD4<Float>>.stride
    private var source, destination, density, table: MTLBuffer?
    private var cachedSource: SourceKey?
    private var cachedDensity: DensityKey?
    private var cachedLUT: CubeLUT?
    private var counters = Statistics()

    public struct Statistics: Sendable {
      public fileprivate(set) var bufferAllocations = 0
      public fileprivate(set) var sourceUploads = 0
      public fileprivate(set) var lutUploads = 0
      public fileprivate(set) var densityPasses = 0
      public fileprivate(set) var densityCacheHits = 0
      public fileprivate(set) var retainedPixelBytes = 0
    }
    public var statistics: Statistics {
      lock.withLock {
        var result = counters
        result.retainedPixelBytes = (source?.length ?? 0) + (destination?.length ?? 0) + (density?.length ?? 0)
        return result
      }
    }

    fileprivate init(device: MTLDevice, queue: MTLCommandQueue, state: MTLComputePipelineState) {
      self.device = device
      self.queue = queue
      self.state = state
    }

    private struct SourceKey: Equatable {
      let identity: UUID
      let width, height: Int
    }
    private struct DensityKey: Equatable {
      let source: SourceKey
      let gain: SIMD3<Float>
      let matrix: PrintDensityMatrix
    }

    /// inputIdentity names an immutable pixel revision, not a frame or a memory
    /// address. A caller must change it whenever samples change. With nil, input
    /// validation/upload runs every time and no source/D1 result is reused.
    public func render(
      _ input: PixelBuffer, calibration: FilmCalibration, adjustments: FrameAdjustments, lut: CubeLUT,
      stage: PipelineStage = .final, inputIdentity: UUID? = nil
    ) throws -> PixelBuffer {
      try lock.withLock {
        try Pipeline.validate(adjustments)
        let (count, overflow) = input.width.multipliedReportingOverflow(by: input.height)
        guard input.width > 0, input.height > 0, !overflow,
          count == input.pixels.count, count <= Int(UInt32.max)
        else { throw PrintroomError.invalid("预览像素尺寸不匹配") }
        let key = inputIdentity.map { SourceKey(identity: $0, width: input.width, height: input.height) }
        let sourceIsCached = key != nil && key == cachedSource
        guard (sourceIsCached || input.pixels.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })),
          (0..<3).allSatisfy({
            calibration.gainRGB[$0].isFinite && calibration.gainRGB[$0] > 0
              && calibration.filmBaseOffsetCV[$0].isFinite
          })
        else { throw PrintroomError.invalid("管线输入包含非法值") }
        let bytes = count * MemoryLayout<SIMD4<Float>>.stride
        defer {
          if bytes > Self.retainedPixelByteLimit {
            source = nil
            destination = nil
            density = nil
            cachedSource = nil
            cachedDensity = nil
          }
        }
        if !sourceIsCached {
          // Invalidate before allocation: a later allocation failure must not
          // leave the old key pointing at a newly allocated, empty buffer.
          cachedSource = nil
          cachedDensity = nil
        }
        let src = try buffer(&source, length: bytes)
        let dst = try buffer(&destination, length: bytes)
        if !sourceIsCached {
          input.pixels.withUnsafeBytes { src.contents().copyMemory(from: $0.baseAddress!, byteCount: bytes) }
          cachedSource = key
          counters.sourceUploads += 1
        }
        let tableBytes = lut.values.count * MemoryLayout<SIMD4<Float>>.stride
        let lutBuffer = try buffer(&table, length: tableBytes)
        if cachedLUT?.size != lut.size || cachedLUT?.values != lut.values {
          lut.values.withUnsafeBytes {
            lutBuffer.contents().copyMemory(from: $0.baseAddress!, byteCount: tableBytes)
          }
          cachedLUT = lut
          counters.lutUploads += 1
        }
        let t = adjustments.timing
        let c = adjustments.contrast
        var params = Parameters(
          gain: SIMD4(calibration.gainRGB, 0),
          offset: SIMD4(
            (calibration.filmBaseOffsetCV
              + SIMD3(Float(t.master + t.red), Float(t.master + t.green), Float(t.master + t.blue)))
              / 1024, 0), contrast: SIMD4(c.master * c.red, c.master * c.green, c.master * c.blue, 0),
          count: UInt32(count), stage: UInt32(stage.rawValue), lutSize: UInt32(lut.size),
          matrix: calibration.matrix == .identity ? 0 : 1, sourceStage: 0)
        let densityKey = key.flatMap { source in
          stage.rawValue >= PipelineStage.d1.rawValue
            ? DensityKey(source: source, gain: calibration.gainRGB, matrix: calibration.matrix) : nil
        }
        let d1Buffer = try densityKey.map { _ in try buffer(&density, length: bytes) }
        guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder()
        else { throw PrintroomError.invalid("Metal 命令创建失败") }
        encoder.setComputePipelineState(state)
        encoder.setBuffer(lutBuffer, offset: 0, index: 2)
        let w = min(state.maxTotalThreadsPerThreadgroup, 256)
        func encode(source: MTLBuffer, destination: MTLBuffer, parameters: inout Parameters) {
          encoder.setBuffer(source, offset: 0, index: 0)
          encoder.setBuffer(destination, offset: 0, index: 1)
          encoder.setBytes(&parameters, length: MemoryLayout<Parameters>.stride, index: 3)
          encoder.dispatchThreads(
            MTLSize(width: count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: w, height: 1, depth: 1))
        }
        var outputBuffer = dst
        var pendingDensity: DensityKey?
        if let densityKey, let d1 = d1Buffer {
          if cachedDensity != densityKey {
            cachedDensity = nil
            var prefix = params
            prefix.stage = UInt32(PipelineStage.d1.rawValue)
            encode(source: src, destination: d1, parameters: &prefix)
            encoder.memoryBarrier(resources: [d1])
            pendingDensity = densityKey
            counters.densityPasses += 1
          } else {
            counters.densityCacheHits += 1
          }
          if stage == .d1 {
            outputBuffer = d1
          } else {
            params.sourceStage = UInt32(PipelineStage.d1.rawValue)
            encode(source: d1, destination: dst, parameters: &params)
          }
        } else {
          encode(source: src, destination: dst, parameters: &params)
        }
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        if let error = command.error {
          cachedDensity = nil
          throw error
        }
        let output = Array(UnsafeBufferPointer(
          start: outputBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: count), count: count))
        guard output.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else {
          cachedDensity = nil
          throw PrintroomError.invalid("Metal 计算产生非有限数值")
        }
        if let pendingDensity { cachedDensity = pendingDensity }
        return PixelBuffer(width: input.width, height: input.height, pixels: output)
      }
    }

    private func buffer(_ existing: inout MTLBuffer?, length: Int) throws -> MTLBuffer {
      if let existing, existing.length == length { return existing }
      guard let allocated = device.makeBuffer(length: length, options: .storageModeShared)
      else { throw PrintroomError.invalid("Metal 缓冲区分配失败") }
      existing = allocated
      counters.bufferAllocations += 1
      return allocated
    }
  }

  private struct Parameters {
    var gain, offset, contrast: SIMD4<Float>
    var count, stage, lutSize, matrix, sourceStage: UInt32
  }
  private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Params { float4 gain; float4 offset; float4 contrast; uint count; uint stage; uint lutSize; uint matrix; uint sourceStage; };
    float3 lookup(device const float4 *table, uint n, float3 p) {
        float3 q = clamp(p,0.0f,1.0f)*float(n-1);
        uint3 a=uint3(floor(q)); uint3 b=min(a+1,uint3(n-1)); float3 f=q-float3(a);
        float3 c000=table[a.x+n*a.y+n*n*a.z].xyz, c100=table[b.x+n*a.y+n*n*a.z].xyz;
        float3 c010=table[a.x+n*b.y+n*n*a.z].xyz, c110=table[b.x+n*b.y+n*n*a.z].xyz;
        float3 c001=table[a.x+n*a.y+n*n*b.z].xyz, c101=table[b.x+n*a.y+n*n*b.z].xyz;
        float3 c011=table[a.x+n*b.y+n*n*b.z].xyz, c111=table[b.x+n*b.y+n*n*b.z].xyz;
        return mix(mix(mix(c000,c100,f.x),mix(c010,c110,f.x),f.y),mix(mix(c001,c101,f.x),mix(c011,c111,f.x),f.y),f.z);
    }
    kernel void printroomPipeline(device const float4 *src [[buffer(0)]], device float4 *dst [[buffer(1)]], device const float4 *table [[buffer(2)]], constant Params& p [[buffer(3)]], uint i [[thread_position_in_grid]]) {
        if (i>=p.count) return;
        float3 v=src[i].xyz;
        if (p.sourceStage<1 && p.stage>=1) v*=p.gain.xyz;
        if (p.sourceStage<2 && p.stage>=2) v=-log10(max(v,float3(1e-6f)))/2.048f;
        if (p.sourceStage<3 && p.stage>=3 && p.matrix==1) v=float3(1.0584f*v.r-0.0204f*v.g+0.0023f*v.b,0.0753f*v.r+1.0120f*v.g-0.0693f*v.b,-0.0147f*v.r+0.1420f*v.g+0.7774f*v.b);
        if (p.sourceStage<4 && p.stage>=4) v+=p.offset.xyz;
        if (p.sourceStage<5 && p.stage>=5) v=\(contrastPivotCV).0f/1024.0f+p.contrast.xyz*(v-\(contrastPivotCV).0f/1024.0f);
        if (p.sourceStage<6 && p.stage>=6) v=lookup(table,p.lutSize,v);
        dst[i]=float4(v,1);
    }
    """
}
