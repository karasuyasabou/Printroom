import PrintroomCore
import SwiftUI

struct CacheManagerCommands: Commands {
  @Environment(\.openWindow) private var openWindow
  var body: some Commands {
    CommandGroup(after: .newItem) {
      Divider()
      Button("管理缓存…") { openWindow(id: "cache-manager") }
    }
  }
}

struct CacheManagerView: View {
  @State private var policy = DiskCachePolicy.load()
  @State private var limitText = ""
  @State private var bytes: Int64?
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 22) {
      Text(bytes.map { String(format: "缓存大小 %.1f/%.1f GB", Double($0) / 1_000_000_000, policy.limitGB) }
        ?? "正在统计缓存…")
        .font(.headline).monospacedDigit()
      Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 18) {
        GridRow {
          Text("缓存上限")
          HStack {
            TextField("8.0", text: $limitText).textFieldStyle(.roundedBorder)
              .frame(width: 100).onSubmit { saveLimit() }
              .accessibilityLabel("缓存上限（GB）")
            Text("GB")
            Button("应用") { saveLimit() }
          }
        }
        GridRow {
          Text("在…后删除缓存")
          Picker("在…后删除缓存", selection: $policy.retentionDays) {
            Text("3 天").tag(3)
            Text("7 天").tag(7)
            Text("30 天").tag(30)
            Text("永不").tag(0)
          }.labelsHidden().frame(width: 180)
            .onChange(of: policy.retentionDays) { _, _ in
              policy.save()
              SourceProxyService.shared.scheduleMaintenance()
            }
        }
      }
      if let error { Text(error).font(.callout).foregroundStyle(.red) }
    }
    .padding(28).frame(width: 460)
    .onAppear { policy = .load(); limitText = String(format: "%.1f", policy.limitGB) }
    .task {
      while !Task.isCancelled {
        do {
          bytes = try await Task.detached(priority: .utility) { try ManagedDiskCache.size() }.value
          try await Task.sleep(for: .seconds(2))
        } catch is CancellationError { return }
        catch {
          self.error = "无法统计缓存：\(error.localizedDescription)"
          try? await Task.sleep(for: .seconds(2))
        }
      }
    }
  }
  private func saveLimit() {
    guard let value = Double(limitText.replacingOccurrences(of: ",", with: ".")),
      value.isFinite, (0.1...100_000).contains(value) else {
      error = "请输入 0.1–100000 之间的 GB 数值。"
      return
    }
    policy.limitGB = value
    policy.save()
    error = nil
    SourceProxyService.shared.scheduleMaintenance()
  }
}
