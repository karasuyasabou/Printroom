import Foundation
@preconcurrency import Metal

/// The same normalized-density contract as PipelineReference; no color conversion.
public final class MetalPipeline: @unchecked Sendable {
  private let device: MTLDevice
  private let queue: MTLCommandQueue
  private let state: MTLComputePipelineState
  public var deviceName: String { device.name }
  public init() throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
      throw PrintroomError.invalid("此设备无法创建 Metal 上下文")
    }
    self.device = device
    self.queue = queue
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
    self.state = try device.makeComputePipelineState(function: function)
  }
  public func render(
    _ input: PixelBuffer, calibration: FilmCalibration, adjustments: FrameAdjustments, lut: CubeLUT,
    stage: PipelineStage = .final
  ) throws -> PixelBuffer {
    try Pipeline.validate(adjustments)
    guard !input.pixels.isEmpty, input.pixels.count == input.width * input.height else {
      throw PrintroomError.invalid("预览像素尺寸不匹配")
    }
    guard input.pixels.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }),
      (0..<3).allSatisfy({
        calibration.gainRGB[$0].isFinite && calibration.gainRGB[$0] > 0
          && calibration.filmBaseOffsetCV[$0].isFinite
      })
    else { throw PrintroomError.invalid("管线输入包含非法值") }
    let t = adjustments.timing
    let c = adjustments.contrast
    var params = Parameters(
      gain: SIMD4(calibration.gainRGB, 0),
      offset: SIMD4(
        (calibration.filmBaseOffsetCV
          + SIMD3(Float(t.master + t.red), Float(t.master + t.green), Float(t.master + t.blue)))
          / 1024, 0), contrast: SIMD4(c.master * c.red, c.master * c.green, c.master * c.blue, 0),
      count: UInt32(input.pixels.count), stage: UInt32(stage.rawValue), lutSize: UInt32(lut.size),
      matrix: calibration.matrix == .identity ? 0 : 1)
    let bytes = input.pixels.count * MemoryLayout<SIMD4<Float>>.stride
    guard
      let src = device.makeBuffer(bytes: input.pixels, length: bytes, options: .storageModeShared),
      let dst = device.makeBuffer(length: bytes, options: .storageModeShared),
      let table = device.makeBuffer(
        bytes: lut.values, length: lut.values.count * MemoryLayout<SIMD4<Float>>.stride,
        options: .storageModeShared), let command = queue.makeCommandBuffer(),
      let encoder = command.makeComputeCommandEncoder()
    else { throw PrintroomError.invalid("Metal 缓冲区分配失败") }
    encoder.setComputePipelineState(state)
    encoder.setBuffer(src, offset: 0, index: 0)
    encoder.setBuffer(dst, offset: 0, index: 1)
    encoder.setBuffer(table, offset: 0, index: 2)
    encoder.setBytes(&params, length: MemoryLayout<Parameters>.stride, index: 3)
    let w = min(state.maxTotalThreadsPerThreadgroup, 256)
    encoder.dispatchThreads(
      MTLSize(width: input.pixels.count, height: 1, depth: 1),
      threadsPerThreadgroup: MTLSize(width: w, height: 1, depth: 1))
    encoder.endEncoding()
    command.commit()
    command.waitUntilCompleted()
    if let error = command.error { throw error }
    let output = Array(
      UnsafeBufferPointer(
        start: dst.contents().bindMemory(to: SIMD4<Float>.self, capacity: input.pixels.count),
        count: input.pixels.count))
    guard output.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else {
      throw PrintroomError.invalid("Metal 计算产生非有限数值")
    }
    return PixelBuffer(width: input.width, height: input.height, pixels: output)
  }
  private struct Parameters {
    var gain, offset, contrast: SIMD4<Float>
    var count, stage, lutSize, matrix: UInt32
  }
  private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Params { float4 gain; float4 offset; float4 contrast; uint count; uint stage; uint lutSize; uint matrix; };
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
        if (p.stage>=1) v*=p.gain.xyz;
        if (p.stage>=2) v=-log10(max(v,float3(1e-6f)))/2.048f;
        if (p.stage>=3 && p.matrix==1) v=float3(1.0584f*v.r-0.0204f*v.g+0.0023f*v.b,0.0753f*v.r+1.0120f*v.g-0.0693f*v.b,-0.0147f*v.r+0.1420f*v.g+0.7774f*v.b);
        if (p.stage>=4) v+=p.offset.xyz;
        if (p.stage>=5) v=\(contrastPivotCV).0f/1024.0f+p.contrast.xyz*(v-\(contrastPivotCV).0f/1024.0f);
        if (p.stage>=6) v=lookup(table,p.lutSize,v);
        dst[i]=float4(v,1);
    }
    """
}
