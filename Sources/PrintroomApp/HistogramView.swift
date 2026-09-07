import PrintroomCore
import SwiftUI

struct HistogramView: View {
  @ObservedObject var model: EditorModel
  @State private var showDetails = false
  private let colors: [Color] = [ChannelColors.red, ChannelColors.green, ChannelColors.blue]
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
      HStack {
        Text("0")
        Spacer()
        if model.isHistogramUpdating || model.isRendering {
          ProgressView().controlSize(.mini)
        } else {
          Text(model.histogram?.stage.label ?? "等待预览")
        }
        Spacer()
        Text("1")
      }.font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
        .frame(height: 12)
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
        Text("\(stats.stage.label) · \(stats.unit)").font(.system(size: 9))
        Text("\(stats.pixelCount) 个预览像素 · 256 bins").font(.system(size: 9)).foregroundStyle(.secondary)
        let indices = model.histogramChannel < 0 ? [0, 1, 2] : [model.histogramChannel]
        ForEach(indices, id: \.self) { index in
          let c = stats.channels[index]
          Text(String(format: "%@  ≤0 %.2f%%   ≥1 %.2f%%", ["R", "G", "B"][index],
            Double(c.blackClipped) / Double(max(1, stats.pixelCount)) * 100,
            Double(c.whiteClipped) / Double(max(1, stats.pixelCount)) * 100))
            .font(.system(size: 9, design: .monospaced)).foregroundStyle(colors[index].opacity(0.85))
        }
        Text("域外 <0: \(stats.channels.reduce(UInt64(0)) { $0 + $1.belowRange }) · >1: \(stats.channels.reduce(UInt64(0)) { $0 + $1.aboveRange }) · 非有限: \(stats.channels.reduce(UInt64(0)) { $0 + $1.nonFinite })")
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
