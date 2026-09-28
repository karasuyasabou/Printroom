import AppKit
import PrintroomCore
import SwiftUI

struct ExportSummaryView: View {
  @ObservedObject var model: EditorModel
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(model.exportSummary?.wasCancelled == true ? "导出已取消" : "导出结果").font(.title2)
      if let summary = model.exportSummary {
        Text("成功 \(summary.completedCount) · 失败 \(summary.failedCount) · 取消/未开始 \(summary.cancelledCount) · \(summary.elapsedSeconds, specifier: "%.1f") 秒")
          .font(.callout).foregroundStyle(InterfaceColors.secondaryText)
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(summary.results) { result in
              HStack(alignment: .top) {
                Image(systemName: symbol(result.status)).foregroundStyle(result.status == .completed ? .green : .orange)
                VStack(alignment: .leading, spacing: 3) {
                  Text(result.sourceName).font(.system(.callout, design: .monospaced))
                  if let destination = result.destination {
                    Text(destination.path).font(.caption).foregroundStyle(InterfaceColors.secondaryText).textSelection(.enabled)
                  }
                  if let error = result.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                  if result.status == .notStarted { Text("未开始").font(.caption).foregroundStyle(InterfaceColors.secondaryText) }
                  if result.status == .cancelled { Text("已取消，未完成文件已清理").font(.caption).foregroundStyle(InterfaceColors.secondaryText) }
                }
                Spacer()
                if let destination = result.destination, result.status == .completed {
                  Button("显示") { NSWorkspace.shared.activateFileViewerSelecting([destination]) }.controlSize(.small)
                }
              }
              Divider()
            }
          }
        }.frame(minHeight: 160, maxHeight: 340)
      }
      HStack {
        Spacer()
        Button("完成") { model.showExportSummary = false }.keyboardShortcut(.defaultAction)
      }
    }.padding(24).frame(width: 620)
  }
  private func symbol(_ status: ExportFrameStatus) -> String {
    switch status {
    case .completed: "checkmark.circle.fill"
    case .failed: "exclamationmark.triangle"
    case .cancelled, .notStarted: "minus.circle"
    }
  }
}
