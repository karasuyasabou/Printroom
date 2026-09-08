import PrintroomCore
import SwiftUI

struct HistogramView: View {
  @ObservedObject var model: EditorModel
  @State private var showDetails = false
  private let colors: [Color] = [ChannelColors.red, ChannelColors.green, ChannelColors.blue]
  private let densityReferences = [95, 470, 685]
  private var usesDensityUnits: Bool {
    switch model.stage {
    case .d0, .d1, .d2, .d3: true
    case .l0, .l1, .final: false
    }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Picker("直方图通道", selection: $model.histogramChannel) {
          Text("RGB").tag(-1)
          Text("R").tag(0)
          Text("G").tag(1)
          Text("B").tag(2)
        }.pickerStyle(.segmented).controlSize(.mini).labelsHidden().frame(maxWidth: .infinity)
        Button {
          showDetails.toggle()
        } label: {
          Image(systemName: "info.circle").foregroundStyle(.secondary)
        }.buttonStyle(.plain).help("整张预览的直方图统计")
          .accessibilityLabel("直方图统计详情")
          .popover(isPresented: $showDetails) { details.padding(14).frame(width: 310) }
      }
      Canvas { context, size in
        if usesDensityUnits {
          for cv in densityReferences {
            let x = CGFloat(cv) / 1024 * size.width
            var reference = Path()
            reference.move(to: CGPoint(x: x, y: 0))
            reference.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(reference, with: .color(.white.opacity(0.15)), lineWidth: 0.5)
          }
        }
        guard let stats = model.histogram else { return }
        let indices = model.histogramChannel < 0 ? [0, 1, 2] : [model.histogramChannel]
        let maximum = indices.flatMap { stats.channels[$0].bins }.max() ?? 1
        for channel in indices {
          let bins = stats.channels[channel].bins
          var path = Path()
          path.move(to: CGPoint(x: 0, y: size.height))
          for i in bins.indices {
            let x = CGFloat(i) / CGFloat(bins.count - 1) * size.width
            let y = size.height * (1 - CGFloat(bins[i]) / CGFloat(max(1, maximum)))
            path.addLine(to: CGPoint(x: x, y: y))
          }
          path.addLine(to: CGPoint(x: size.width, y: size.height))
          path.closeSubpath()
          context.fill(path, with: .color(colors[channel].opacity(0.27)))
          context.stroke(path, with: .color(colors[channel].opacity(0.85)), lineWidth: 0.7)
        }
      }.frame(height: 78)
        .allowsHitTesting(false)
        .accessibilityLabel("整张预览直方图")
      Canvas { context, size in
        func label(_ value: String, x: CGFloat, anchor: UnitPoint, opacity: Double = 0.55) {
          context.draw(Text(value).font(.system(size: 9, design: .monospaced))
            .foregroundStyle(.white.opacity(opacity)),
            at: CGPoint(x: x, y: size.height / 2), anchor: anchor)
        }
        label("0", x: 0, anchor: .leading)
        label(usesDensityUnits ? "1024 CV" : "1", x: size.width, anchor: .trailing)
        if usesDensityUnits {
          for cv in densityReferences {
            label("\(cv)", x: CGFloat(cv) / 1024 * size.width, anchor: .center, opacity: 0.35)
          }
        } else {
          label(model.stage.label, x: size.width / 2, anchor: .center)
        }
      }.frame(height: 12).allowsHitTesting(false)
        .accessibilityLabel(usesDensityUnits ? "密度 0 至 1024 CV，参考刻度 95、470、685" : "数值 0 至 1")
    }
    .padding(10)
    .background(.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
    .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
  }
  private var details: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("整张预览统计").font(.caption.weight(.medium))
      if let stats = model.histogram {
        Text("\(stats.stage.label) · \(usesDensityUnits ? "CV" : stats.unit)").font(.system(size: 9))
        Text("\(stats.pixelCount) 个预览像素 · 256 bins").font(.system(size: 9)).foregroundStyle(.secondary)
        let indices = model.histogramChannel < 0 ? [0, 1, 2] : [model.histogramChannel]
        ForEach(indices, id: \.self) { index in
          let c = stats.channels[index]
          Text(String(format: "%@  ≤0 %.2f%%   ≥%@ %.2f%%", ["R", "G", "B"][index],
            Double(c.blackClipped) / Double(max(1, stats.pixelCount)) * 100,
            usesDensityUnits ? "1024" : "1",
            Double(c.whiteClipped) / Double(max(1, stats.pixelCount)) * 100))
            .font(.system(size: 9, design: .monospaced)).foregroundStyle(colors[index].opacity(0.85))
        }
        Text("域外 <0: \(stats.channels.reduce(UInt64(0)) { $0 + $1.belowRange }) · >\(usesDensityUnits ? "1024" : "1"): \(stats.channels.reduce(UInt64(0)) { $0 + $1.aboveRange }) · 非有限: \(stats.channels.reduce(UInt64(0)) { $0 + $1.nonFinite })")
          .font(.system(size: 9)).foregroundStyle(.secondary)
        Text("域外与非有限值不入 bins；端点单列。统计不改变管线值。")
          .font(.system(size: 9)).foregroundStyle(.tertiary)
      } else {
        Text(model.isRendering || model.isLoading ? "等待当前照片…" : "暂无统计")
          .font(.caption2).foregroundStyle(.secondary)
      }
    }
  }
}
