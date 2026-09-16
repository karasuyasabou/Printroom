import AppKit
import PrintroomCore
import SwiftUI

struct HistogramView: View {
  @ObservedObject var model: EditorModel
  @AppStorage("histogramExpanded") private var isExpanded = true
  private let colors: [Color] = [ChannelColors.red, ChannelColors.green, ChannelColors.blue]
  private let densityReferences = [95, 470, 685]
  private var usesDensityUnits: Bool {
    model.histogramStage == .d3
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        if isExpanded {
          Picker("直方图阶段", selection: $model.histogramStage) {
            Text("Density").tag(PipelineStage.d3)
            Text("Final").tag(PipelineStage.final)
          }.pickerStyle(.segmented).controlSize(.mini).labelsHidden().frame(maxWidth: .infinity)
        }
        Button {
          isExpanded.toggle()
        } label: {
          HStack(spacing: 6) {
            if !isExpanded { Text("直方图") }
            Image(systemName: isExpanded ? "chevron.down" : "chevron.left")
          }
          .font(.caption)
          .padding(.vertical, 3)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "收起直方图" : "展开直方图")
        .accessibilityLabel(isExpanded ? "收起直方图" : "展开直方图")
        .accessibilityValue(isExpanded ? "已展开" : "已收起")
      }
      if isExpanded {
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
          let indices = [0, 1, 2]
          let maximum = HistogramDisplayScale.upperBound(
            channelBins: indices.map { stats.channels[$0].bins }, sampleCount: stats.sampleCount)
          for channel in indices {
            let bins = stats.channels[channel].bins
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height))
            for i in bins.indices {
              let x = CGFloat(i) / CGFloat(bins.count - 1) * size.width
              let y = size.height * (1 - CGFloat(HistogramDisplayScale.heightFraction(
                count: bins[i], upperBound: maximum)))
              path.addLine(to: CGPoint(x: x, y: y))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
            context.fill(path, with: .color(colors[channel].opacity(0.27)))
            context.stroke(path, with: .color(colors[channel].opacity(0.85)), lineWidth: 0.7)
          }
        }.frame(height: 78).clipped()
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
          }
        }.frame(height: 12).allowsHitTesting(false)
          .accessibilityLabel(usesDensityUnits ? "密度 0 至 1024 CV，参考刻度 95、470、685" : "数值 0 至 1")
      }
    }
    .padding(10)
    .frame(width: isExpanded ? 248 : nil)
    .background(HistogramPointerSurface())
    .background(.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
    .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
  }
}

/// Gives the entire floating panel an arrow cursor and absorbs canvas gestures
/// in the chart's otherwise non-interactive areas. SwiftUI controls remain above it.
struct HistogramPointerSurface: NSViewRepresentable {
  func makeNSView(context: Context) -> HistogramPointerView { HistogramPointerView() }
  func updateNSView(_ view: HistogramPointerView, context: Context) {}
}

final class HistogramPointerView: NSView {
  private var pointerTrackingArea: NSTrackingArea?
  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .arrow)
  }
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
    let area = NSTrackingArea(rect: .zero,
      options: [.inVisibleRect, .activeInKeyWindow, .cursorUpdate, .mouseMoved, .mouseEnteredAndExited],
      owner: self, userInfo: nil)
    addTrackingArea(area)
    pointerTrackingArea = area
  }
  override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }
  override func mouseEntered(with event: NSEvent) { NSCursor.arrow.set() }
  override func mouseMoved(with event: NSEvent) { NSCursor.arrow.set() }
  override func mouseDown(with event: NSEvent) {}
  override func mouseDragged(with event: NSEvent) {}
  override func mouseUp(with event: NSEvent) {}
  override func scrollWheel(with event: NSEvent) {}
}
