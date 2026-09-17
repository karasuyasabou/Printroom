import Foundation

/// Bounded, ungraded density analysis. Neither film-base calibration nor LUT enters detection.
public struct AutoCropSeed: Sendable {
  public let width: Int, height: Int
  public let angle: Double
  public let edges: [Double], evidence: [Double]
  fileprivate var score: Double { let e = evidence.sorted(); return e[1] + e[2] + e[3] + 0.4 * e[0] }
}

public struct AutoCropAnalysis: Sendable {
  public let width: Int, height: Int
  fileprivate let density: [Float]
  public let seedAngle: Double
  public let seedEdges: [Double]
  public let seedEvidence: [Double]
  public var seed: AutoCropSeed { AutoCropSeed(width: width, height: height, angle: seedAngle, edges: seedEdges, evidence: seedEvidence) }
  fileprivate var seedScore: Double { let e = seedEvidence.sorted(); return e[1] + e[2] + e[3] + 0.4 * e[0] }
}

public struct AutoCropTemplate: Sendable {
  public let width: Double, height: Double
  public let analysisWidth: Int, analysisHeight: Int
  public let seedCount: Int
}

public struct AutoCropResult: Sendable {
  public let crop: FrameCrop
  public let needsReview: Bool
  public let evidence: [Double]
}

/// Native implementation of the accepted offline roll experiment. All frames share one
/// measured size; three visible edges can pass. Light leaks are deliberately not rejected.
public enum AutoCropAnalyzer {
  public static func prepare(_ image: LinearImage, seed: AutoCropSeed? = nil) throws -> AutoCropAnalysis {
    guard image.width > 0, image.height > 0,
      image.width <= Int.max / image.height / 3,
      image.samples.count == image.width * image.height * 3 else {
      throw PrintroomError.invalid("自动裁切输入尺寸无效。")
    }
    let w = 800, h = max(1, Int((800 * Double(image.height) / Double(image.width)).rounded()))
    guard h <= 6400 else { throw PrintroomError.invalid("自动裁切不支持此图像尺寸。") }
    // Area averaging happens in linear samples, before logarithmic density.
    let xs = areaWeights(source: image.width, target: w)
    let ys = areaWeights(source: image.height, target: h)
    var d = [Float](repeating: 0, count: w * h)
    for y in 0..<h {
      try Task.checkCancellation()
      for x in 0..<w {
        var rgb = SIMD3<Float>(repeating: 0)
        for (sy, wy) in ys[y] { for (sx, wx) in xs[x] {
          let i = (sy * image.width + sx) * 3
          rgb += SIMD3(Float(image.samples[i]), Float(image.samples[i + 1]), Float(image.samples[i + 2])) * (wx * wy)
        } }
        d[y * w + x] = (-log(max(rgb.x, 1) / 65535) - log(max(rgb.y, 1) / 65535) - log(max(rgb.z, 1) / 65535)) / 3
      }
    }
    d = blur(d, width: w, height: h)
    if let seed {
      guard seed.width == w, seed.height == h else { throw PrintroomError.invalid("自动裁切分析尺寸已变化。") }
      return AutoCropAnalysis(width: w, height: h, density: d, seedAngle: seed.angle,
                             seedEdges: seed.edges, seedEvidence: seed.evidence)
    }
    let ranges = [(Double(w) * 0.025, Double(w) * 0.18), (Double(w) * 0.82, Double(w) * 0.99),
                  (Double(h) * 0.015, Double(h) * 0.14), (Double(h) * 0.86, Double(h) * 0.995)]
    var best = AutoCropAnalysis(width: w, height: h, density: d, seedAngle: 0, seedEdges: [], seedEvidence: [0,0,0,0])
    var bestScore = -Double.infinity
    for step in 0...60 {
      try Task.checkCancellation()
      let angle = -3 + Double(step) * 0.1
      var edges = [Double](), evidence = [Double]()
      for side in 0..<4 {
        var winner = -Double.infinity, position = ranges[side].0
        for p in stride(from: ranges[side].0, to: ranges[side].1, by: 0.5) {
          let score = profile(d, width: w, height: h, angle: angle, side: side, position: p)
          if score > winner { winner = score; position = p }
        }
        edges.append(position); evidence.append(winner)
      }
      let candidate = AutoCropAnalysis(width: w, height: h, density: d, seedAngle: angle, seedEdges: edges, seedEvidence: evidence)
      if candidate.seedScore > bestScore { best = candidate; bestScore = candidate.seedScore }
    }
    return best
  }

  public static func template(from analyses: [AutoCropAnalysis]) throws -> AutoCropTemplate {
    try template(fromSeeds: analyses.map(\.seed))
  }

  public static func template(fromSeeds seeds: [AutoCropSeed]) throws -> AutoCropTemplate {
    guard let first = seeds.first,
      seeds.allSatisfy({ $0.width == first.width && $0.height == first.height }) else {
      throw PrintroomError.invalid("自动裁切需要一卷尺寸一致的照片。")
    }
    var reliable = seeds.filter { $0.evidence.min()! > 0.3 }
    if reliable.count < 5 { reliable = Array(seeds.sorted { $0.score > $1.score }.prefix(18)) }
    return AutoCropTemplate(width: median(reliable.map { $0.edges[1] - $0.edges[0] }),
      height: median(reliable.map { $0.edges[3] - $0.edges[2] }),
      analysisWidth: first.width, analysisHeight: first.height, seedCount: reliable.count)
  }

  public static func fit(_ analysis: AutoCropAnalysis, template: AutoCropTemplate,
                         sourceWidth: Int, sourceHeight: Int,
                         requiresAllEdges: Bool = false) throws -> AutoCropResult {
    guard sourceWidth > 0, sourceHeight > 0,
      analysis.width == template.analysisWidth, analysis.height == template.analysisHeight else {
      throw PrintroomError.invalid("自动裁切模板尺寸不匹配。")
    }
    let e = analysis.seedEdges, w = template.width, h = template.height
    var starts = [[(e[0] + e[1]) / 2, (e[2] + e[3]) / 2, analysis.seedAngle]]
    for x in [e[0] + w / 2, e[1] - w / 2] {
      for y in [e[2] + h / 2, e[3] - h / 2] { starts.append([x, y, analysis.seedAngle]) }
    }
    func evidence(_ v: [Double]) -> [Double] {
      [v[0] - w / 2, v[0] + w / 2, v[1] - h / 2, v[1] + h / 2].enumerated().map {
        profile(analysis.density, width: analysis.width, height: analysis.height,
                angle: v[2], side: $0.offset, position: $0.element)
      }
    }
    func cost(_ v: [Double]) -> Double {
      let scores = evidence(v).sorted()
      return -(scores[1] + scores[2] + scores[3] + 0.55 * scores[0])
    }
    var winner = starts[0], best = Double.infinity
    for start in starts {
      let result = try minimize(start, cost: cost)
      let value = cost(result)
      if value < best { winner = result; best = value }
    }
    let scores = evidence(winner)
    let edgeCountPasses = requiresAllEdges
      ? scores.allSatisfy { $0 > 0.22 }
      : scores.filter { $0 > 0.22 }.count >= 3
    let pass = edgeCountPasses && scores.reduce(0,+) / 4 > 0.34 && abs(winner[2]) < 3
    let pixelWidth = w / Double(analysis.width) * Double(sourceWidth)
    let pixelHeight = h / Double(analysis.height) * Double(sourceHeight)
    let crop = FrameCrop(aspect: .free, centerX: winner[0] / Double(analysis.width),
      centerY: winner[1] / Double(analysis.height), width: w / Double(analysis.width),
      angleDegrees: max(-10, min(10, -winner[2])), freeRatio: pixelWidth / pixelHeight)
    return AutoCropResult(crop: try crop.constrained(sourceWidth: sourceWidth, sourceHeight: sourceHeight),
                          needsReview: !pass, evidence: scores)
  }

  private static func areaWeights(source: Int, target: Int) -> [[(Int, Float)]] {
    let scale = Double(source) / Double(target)
    return (0..<target).map { i in
      let low = Double(i) * scale, high = Double(i + 1) * scale
      return (Int(floor(low))..<min(source, Int(ceil(high)))).map {
        ($0, Float((min(high, Double($0 + 1)) - max(low, Double($0))) / scale))
      }
    }
  }

  private static func blur(_ source: [Float], width: Int, height: Int) -> [Float] {
    // OpenCV sigma=.65 for Float32 selects a seven-tap kernel and reflect-101 borders.
    var kernel = (-3...3).map { exp(-Double($0 * $0) / (2 * 0.65 * 0.65)) }
    let sum = kernel.reduce(0,+); kernel = kernel.map { $0 / sum }
    func reflect(_ i: Int, _ n: Int) -> Int {
      if n == 1 { return 0 }; var p = i
      while p < 0 || p >= n { p = p < 0 ? -p : 2 * n - p - 2 }
      return p
    }
    var temp = source, result = source
    for y in 0..<height { for x in 0..<width {
      var value: Float = 0
      for k in -3...3 { value += source[y * width + reflect(x + k, width)] * Float(kernel[k + 3]) }
      temp[y * width + x] = value
    } }
    for y in 0..<height { for x in 0..<width {
      var value: Float = 0
      for k in -3...3 { value += temp[reflect(y + k, height) * width + x] * Float(kernel[k + 3]) }
      result[y * width + x] = value
    } }
    return result
  }

  private static func profile(_ d: [Float], width: Int, height: Int, angle: Double,
                              side: Int, position: Double) -> Double {
    let c = cos(angle * .pi / 180), s = sin(angle * .pi / 180)
    let vertical = side < 2, sign = side == 0 || side == 2 ? 1.0 : -1.0
    let count = vertical ? 170 : 240
    let extent = vertical ? Double(height) * 0.38 : Double(width) * 0.37
    let nx = vertical ? c : -s, ny = vertical ? s : c
    let midX = Double(width) / 2, midY = Double(height) / 2
    var sum: Float = 0
    d.withUnsafeBufferPointer { pixels in
      for i in 0..<count {
        let along = -extent + 2 * extent * Double(i) / Double(count - 1)
        let u = vertical ? position - midX : along
        let v = vertical ? along : position - midY
        let x = midX + c * u - s * v, y = midY + s * u + c * v
        let delta = sample(pixels, width, height, x + sign * nx * 2, y + sign * ny * 2)
          - sample(pixels, width, height, x - sign * nx * 2, y - sign * ny * 2)
        let fine = sample(pixels, width, height, x + sign * nx * 0.6, y + sign * ny * 0.6)
          - sample(pixels, width, height, x - sign * nx * 0.6, y - sign * ny * 0.6)
        sum += 0.55 * min(1, max(0, delta / 0.22)) + 0.45 * min(1, max(0, fine / 0.9))
      }
    }
    return Double(sum / Float(count))
  }

  @inline(__always) private static func sample(_ d: UnsafeBufferPointer<Float>, _ w: Int, _ h: Int,
                                               _ x: Double, _ y: Double) -> Float {
    // cv::remap INTER_LINEAR uses a 1/32-pixel interpolation table on Float32 coordinates.
    let xx = min(Float(w - 1), max(0, (Float(x) * 32).rounded(.toNearestOrEven) / 32))
    let yy = min(Float(h - 1), max(0, (Float(y) * 32).rounded(.toNearestOrEven) / 32))
    let ix = Int(xx), iy = Int(yy), fx = xx - Float(ix), fy = yy - Float(iy)
    let jx = min(w - 1, ix + 1), jy = min(h - 1, iy + 1)
    return d[iy * w + ix] * (1 - fx) * (1 - fy) + d[iy * w + jx] * fx * (1 - fy)
      + d[jy * w + ix] * (1 - fx) * fy + d[jy * w + jx] * fx * fy
  }

  private static func median(_ values: [Double]) -> Double {
    let a = values.sorted(); return (a[(a.count - 1) / 2] + a[a.count / 2]) / 2
  }

  private static func minimize(_ start: [Double], cost: ([Double]) -> Double) throws -> [Double] {
    var points = [start]
    for k in 0..<3 { var p = start; p[k] = p[k] == 0 ? 0.00025 : p[k] * 1.05; points.append(p) }
    var scores = points.map(cost)
    func reorder() {
      let order = (0..<4).sorted { scores[$0] == scores[$1] ? $0 < $1 : scores[$0] < scores[$1] }
      points = order.map { points[$0] }; scores = order.map { scores[$0] }
    }
    reorder()
    for _ in 1..<180 {
      try Task.checkCancellation()
      if (1..<4).allSatisfy({ i in (0..<3).allSatisfy { abs(points[i][$0] - points[0][$0]) <= 0.015 } })
        && scores.dropFirst().allSatisfy({ abs($0 - scores[0]) <= 0.0001 }) { break }
      let center = (0..<3).map { (points[0][$0] + points[1][$0] + points[2][$0]) / 3 }
      func candidate(_ factor: Double) -> [Double] { (0..<3).map { center[$0] + factor * (center[$0] - points[3][$0]) } }
      let reflected = candidate(1), fr = cost(reflected)
      var shrink = false
      if fr < scores[0] {
        let expanded = candidate(2), fe = cost(expanded)
        points[3] = fe < fr ? expanded : reflected; scores[3] = min(fe, fr)
      } else if fr < scores[2] { points[3] = reflected; scores[3] = fr }
      else if fr < scores[3] {
        let contracted = candidate(0.5), fc = cost(contracted)
        if fc <= fr { points[3] = contracted; scores[3] = fc } else { shrink = true }
      } else {
        let contracted = candidate(-0.5), fc = cost(contracted)
        if fc < scores[3] { points[3] = contracted; scores[3] = fc } else { shrink = true }
      }
      if shrink { for i in 1..<4 {
        points[i] = (0..<3).map { points[0][$0] + 0.5 * (points[i][$0] - points[0][$0]) }
        scores[i] = cost(points[i])
      } }
      reorder()
    }
    return points[0]
  }
}
