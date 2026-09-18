import Foundation

/// A local peak plus evidence that its outside is film base, not a fixture stripe.
struct AutoCropEdgeCandidate: Sendable {
  let position: Double
  let baseDensity: Double
  var weight: Double
  func supported(by base: Double) -> Double {
    weight * exp(-abs(baseDensity - base) / 0.25)
  }
}

/// Bounded, ungraded density analysis. Neither film-base calibration nor LUT enters detection.
public struct AutoCropSeed: Sendable {
  public let width: Int, height: Int
  public let angle: Double
  public let edges: [Double], evidence: [Double]
  var candidates: [[AutoCropEdgeCandidate]] = []
  var baseDensity: Double = 0
  fileprivate var score: Double { let e = evidence.sorted(); return e[1] + e[2] + e[3] + 0.4 * e[0] }
}

public struct AutoCropAnalysis: Sendable {
  public let width: Int, height: Int
  fileprivate let density: [Float]
  public let seedAngle: Double
  public let seedEdges: [Double]
  public let seedEvidence: [Double]
  var candidates: [[AutoCropEdgeCandidate]] = []
  var baseDensity: Double = 0
  public var seed: AutoCropSeed { AutoCropSeed(width: width, height: height, angle: seedAngle, edges: seedEdges,
                                             evidence: seedEvidence, candidates: candidates, baseDensity: baseDensity) }
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

/// All frames share one size, selected from film-base-supported edge candidates.
/// Size and position share film-base evidence; review retains the original contract.
public enum AutoCropAnalyzer {
  public static let version = "roll-edge-v3"
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
                             seedEdges: seed.edges, seedEvidence: seed.evidence, candidates: seed.candidates, baseDensity: seed.baseDensity)
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
    let detected = try edgeCandidates(d, width: w, height: h, angle: best.seedAngle, ranges: ranges)
    best.candidates = detected.candidates
    best.baseDensity = detected.base
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
    let horizontal = try consensus(seeds, axis: 0)
    let vertical = try consensus(seeds, axis: 1)
    // With no supported pairs (e.g. a featureless frame), retain the original
    // suggestion. The fit/review stage still handles absent edges.
    return AutoCropTemplate(width: horizontal?.size ?? median(reliable.map { $0.edges[1] - $0.edges[0] }),
      height: vertical?.size ?? median(reliable.map { $0.edges[3] - $0.edges[2] }),
      analysisWidth: first.width, analysisHeight: first.height,
      seedCount: min(horizontal?.count ?? reliable.count, vertical?.count ?? reliable.count))
  }

  private static func edgeCandidates(_ d: [Float], width: Int, height: Int, angle: Double,
                                     ranges: [(Double, Double)]) throws -> (candidates: [[AutoCropEdgeCandidate]], base: Double) {
    var result = [[AutoCropEdgeCandidate]]()
    for side in 0..<4 {
      try Task.checkCancellation()
      let positions = Array(stride(from: ranges[side].0, to: ranges[side].1, by: 0.5))
      let scores = positions.map { profile(d, width: width, height: height, angle: angle, side: side, position: $0) }
      // Include search-band endpoints and plateau peaks; deterministic tie order.
      let peaks = positions.indices.filter { i in
        scores[i] >= 0.08 && (i == 0 || scores[i] >= scores[i - 1])
          && (i == scores.count - 1 || scores[i] >= scores[i + 1])
      }.sorted { scores[$0] == scores[$1] ? $0 < $1 : scores[$0] > scores[$1] }
      var candidates = [AutoCropEdgeCandidate]()
      for peak in peaks {
        let position = positions[peak]
        if candidates.contains(where: { abs($0.position - position) < 3 }) { continue }
        candidates.append(measureEdge(d, width: width, height: height, angle: angle,
                                      side: side, position: position, support: scores[peak]))
        if candidates.count == 8 { break }
      }
      result.append(candidates)
    }
    // A frame contributes at most one vote per side to its base estimate.
    // This stops a textured side with many peaks from dominating the base mode.
    let all = result.flatMap { $0 }
    var base = 0.0, best = -Double.infinity
    for candidate in all {
      let vote = result.reduce(0.0) { sum, side in
        sum + (side.map { $0.supported(by: candidate.baseDensity) }.max() ?? 0)
      }
      if vote > best { best = vote; base = candidate.baseDensity }
    }
    return (result.map { side in side.map { candidate in
      var weighted = candidate
      weighted.weight = candidate.supported(by: base)
      return weighted
    } }, base)
  }

  /// Shared measurements for candidate selection and continuous position fitting.
  /// The frame's reference base is estimated once and never follows the moving box.
  private static func measureEdge(_ d: [Float], width: Int, height: Int, angle: Double,
                                  side: Int, position: Double, support: Double? = nil) -> AutoCropEdgeCandidate {
    let c = cos(angle * .pi / 180), s = sin(angle * .pi / 180)
    let vertical = side < 2, sign = side == 0 || side == 2 ? 1.0 : -1.0
    let count = vertical ? 85 : 120
    let extent = vertical ? Double(height) * 0.38 : Double(width) * 0.37
    let nx = vertical ? c : -s, ny = vertical ? s : c
    let midX = Double(width) / 2, midY = Double(height) / 2
    var outside = [Double](), spreads = [Double](), rise = 0.0
    d.withUnsafeBufferPointer { pixels in
      for i in 0..<count {
        let along = -extent + 2 * extent * Double(i) / Double(count - 1)
        let u = vertical ? position - midX : along
        let v = vertical ? along : position - midY
        let x = midX + c * u - s * v, y = midY + s * u + c * v
        var outer = [Double](), inner = [Double]()
        for offset in [4.0, 6.0, 8.0] {
          outer.append(Double(sample(pixels, width, height, x - sign * nx * offset, y - sign * ny * offset)))
          inner.append(Double(sample(pixels, width, height, x + sign * nx * offset, y + sign * ny * offset)))
        }
        outside.append(contentsOf: outer)
        spreads.append(outer.max()! - outer.min()!)
        rise += min(1, max(0, (median(inner) - median(outer)) / 0.22))
      }
    }
    let strength = support ?? profile(d, width: width, height: height, angle: angle, side: side, position: position)
    return AutoCropEdgeCandidate(position: position, baseDensity: median(outside),
      weight: strength * exp(-median(spreads) / 0.2) * rise / Double(count))
  }

  private static func consensus(_ seeds: [AutoCropSeed], axis: Int) throws -> (size: Double, count: Int)? {
    typealias Pair = (size: Double, weight: Double)
    let pairs: [[Pair]] = seeds.map { seed in
      guard seed.candidates.count == 4 else { return [] }
      return seed.candidates[axis * 2].flatMap { a in
        seed.candidates[axis * 2 + 1].compactMap { b -> Pair? in
          guard min(a.weight, b.weight) > 0.03, b.position > a.position else { return nil }
          return (b.position - a.position, sqrt(a.weight * b.weight))
        }
      }
    }
    var winner: Double?, best = -Double.infinity
    // Each frame casts only its strongest vote for a proposed size. A 3px
    // triangular window rewards agreement without pooling unrelated widths.
    for proposal in Set(pairs.flatMap { $0.map(\.size) }).sorted() {
      try Task.checkCancellation()
      let score = pairs.reduce(0.0) { sum, frame in
        sum + (frame.map { $0.weight * max(0, 1 - abs($0.size - proposal) / 3) }.max() ?? 0)
      }
      if score > best { winner = proposal; best = score }
    }
    guard let winner else { return nil }
    let contributors: [Pair] = pairs.compactMap { frame in
      frame.filter { abs($0.size - winner) < 3 }.max { $0.weight < $1.weight }
    }.sorted { $0.size < $1.size }
    let half = contributors.reduce(0) { $0 + $1.weight } / 2
    var weight = 0.0
    for pair in contributors {
      weight += pair.weight
      if weight >= half { return (pair.size, contributors.count) }
    }
    return nil
  }

  public static func fit(_ analysis: AutoCropAnalysis, template: AutoCropTemplate,
                         sourceWidth: Int, sourceHeight: Int,
                         requiresAllEdges: Bool = false) throws -> AutoCropResult {
    guard sourceWidth > 0, sourceHeight > 0,
      analysis.width == template.analysisWidth, analysis.height == template.analysisHeight else {
      throw PrintroomError.invalid("自动裁切模板尺寸不匹配。")
    }
    let e = analysis.seedEdges, w = template.width, h = template.height
    func centers(axis: Int, size: Double) -> [Double] {
      guard analysis.candidates.count == 4 else { return [(e[axis * 2] + e[axis * 2 + 1]) / 2] }
      let low = analysis.candidates[axis * 2], high = analysis.candidates[axis * 2 + 1]
      let proposals = low.filter { $0.weight > 0.03 }.map { $0.position + size / 2 }
        + high.filter { $0.weight > 0.03 }.map { $0.position - size / 2 }
      func support(_ center: Double) -> Double {
        (low.map { $0.weight * max(0, 1 - abs($0.position - (center - size / 2)) / 3) }.max() ?? 0)
          + (high.map { $0.weight * max(0, 1 - abs($0.position - (center + size / 2)) / 3) }.max() ?? 0)
      }
      let extent = Double(axis == 0 ? analysis.width : analysis.height)
      let ordered = proposals.filter { $0 >= size / 2 && $0 <= extent - size / 2 }.sorted { a, b in
        let sa = support(a), sb = support(b)
        return sa == sb ? a < b : sa > sb
      }
      var selected = [Double]()
      for center in ordered where !selected.contains(where: { abs($0 - center) < 1.5 }) {
        selected.append(center)
        if selected.count == 2 { break }
      }
      return selected.isEmpty ? [(e[axis * 2] + e[axis * 2 + 1]) / 2] : selected
    }
    func fitsSource(_ v: [Double]) -> Bool {
      let c = cos(v[2] * .pi / 180), s = sin(v[2] * .pi / 180)
      let mx = Double(analysis.width) / 2, my = Double(analysis.height) / 2
      let cx = mx + c * (v[0] - mx) - s * (v[1] - my)
      let cy = my + s * (v[0] - mx) + c * (v[1] - my)
      let ex = (abs(c) * w + abs(s) * h) / 2, ey = (abs(s) * w + abs(c) * h) / 2
      return cx >= ex && cx <= 2 * mx - ex && cy >= ey && cy <= 2 * my - ey
    }
    var starts = centers(axis: 0, size: w).flatMap { x in
      centers(axis: 1, size: h).map { y in [x, y, analysis.seedAngle] }
    }
    starts = starts.filter(fitsSource)
    if starts.isEmpty { starts = [[Double(analysis.width) / 2, Double(analysis.height) / 2, 0]] }
    func evidence(_ v: [Double]) -> [Double] {
      [v[0] - w / 2, v[0] + w / 2, v[1] - h / 2, v[1] + h / 2].enumerated().map {
        profile(analysis.density, width: analysis.width, height: analysis.height,
                angle: v[2], side: $0.offset, position: $0.element)
      }
    }
    func cost(_ v: [Double]) -> Double {
      // Optimize the box actually returned. Out-of-source candidates must not
      // win and then be silently translated by FrameCrop.constrained.
      guard fitsSource(v) else { return 1_000_000 }
      let scores = [v[0] - w / 2, v[0] + w / 2, v[1] - h / 2, v[1] + h / 2].enumerated().map {
        measureEdge(analysis.density, width: analysis.width, height: analysis.height,
          angle: v[2], side: $0.offset, position: $0.element).supported(by: analysis.baseDensity)
      }.sorted()
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
