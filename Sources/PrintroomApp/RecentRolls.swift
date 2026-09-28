import AppKit
import SwiftUI
import PrintroomCore

struct RecentRoll: Codable, Identifiable, Equatable, Sendable {
  var id: String { path }
  let path: String
  let projectID: UUID
  let openedAt: Date
  var name: String? = nil
  var displayName: String { name ?? url.lastPathComponent }
  var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
}

@MainActor final class RecentRolls: ObservableObject {
  @Published private(set) var entries: [RecentRoll]
  @Published private(set) var removed: RecentRoll?
  private let defaults: UserDefaults
  private let key = "recentRolls.v1"
  private var expiry: Task<Void, Never>?

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    entries = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([RecentRoll].self, from: $0) } ?? []
  }
  func record(folder: URL, projectID: UUID, replacing: String? = nil, date: Date = Date(), name: String? = nil) {
    let path = folder.standardizedFileURL.resolvingSymlinksInPath().path
    entries.removeAll { $0.path == path || $0.path == replacing }
    entries.insert(RecentRoll(path: path, projectID: projectID, openedAt: date, name: name), at: 0)
    entries = Array(entries.prefix(20))
    persist()
  }
  func updateName(folder: URL, name: String?) {
    let path = folder.standardizedFileURL.resolvingSymlinksInPath().path
    guard let index = entries.firstIndex(where: { $0.path == path }) else { return }
    entries[index].name = name
    persist()
  }
  func remove(_ entry: RecentRoll) {
    entries.removeAll { $0.id == entry.id }
    removed = entry
    persist()
    expiry?.cancel()
    expiry = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(6)) } catch { return }
      self?.removed = nil
    }
  }
  func undoRemoval() {
    guard let removed else { return }
    expiry?.cancel()
    if !entries.contains(where: { $0.id == removed.id }) { entries.append(removed) }
    entries.sort { $0.openedAt > $1.openedAt }
    entries = Array(entries.prefix(20))
    self.removed = nil
    persist()
  }
  private func persist() {
    if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: key) }
  }
}

struct RecentRollsView: View {
  @ObservedObject var history: RecentRolls
  @ObservedObject var model: EditorModel
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if !history.entries.isEmpty {
        Text("最近打开的胶卷").font(.system(size: 12, weight: .semibold)).foregroundStyle(InterfaceColors.secondaryText)
        ScrollView {
          LazyVStack(spacing: 2) {
            ForEach(history.entries) { entry in RecentRollRow(entry: entry, history: history, model: model) }
          }
        }.frame(height: CGFloat(min(history.entries.count, 6)) * 44)
      }
      if let removed = history.removed {
        HStack {
          Text("已移除 \(removed.displayName)").lineLimit(1).foregroundStyle(InterfaceColors.secondaryText)
          Spacer()
          Button("撤销") { history.undoRemoval() }.buttonStyle(.plain)
        }.font(.caption).frame(height: 22)
      }
    }.frame(maxWidth: 500).padding(.horizontal, 24)
  }
}

private struct RecentRollRow: View {
  let entry: RecentRoll
  @ObservedObject var history: RecentRolls
  @ObservedObject var model: EditorModel
  @Environment(\.scenePhase) private var scenePhase
  @State private var hovering = false
  @State private var available = true
  var body: some View {
    HStack(spacing: 6) {
      Button { model.openRecent(entry) } label: {
        HStack(spacing: 12) {
          Image(systemName: "folder").font(.system(size: 21)).foregroundStyle(InterfaceColors.secondaryText)
          VStack(alignment: .leading, spacing: 4) {
            Text(entry.displayName).font(.system(size: 13, weight: .medium)).lineLimit(1)
            Text(entry.path).font(.system(size: 10)).foregroundStyle(InterfaceColors.secondaryText).lineLimit(1).truncationMode(.middle)
          }
          Spacer(minLength: 8)
          Text(available ? dateLabel : "位置不可用").font(.system(size: 10)).foregroundStyle(InterfaceColors.secondaryText)
        }.contentShape(Rectangle())
      }.buttonStyle(.plain).disabled(model.isExporting)
      Button { history.remove(entry) } label: {
        Image(systemName: "xmark").font(.system(size: 10)).frame(width: 24, height: 28)
      }.buttonStyle(.plain).opacity(hovering ? 1 : 0)
        .help("从最近记录中移除").accessibilityLabel("从最近记录中移除 \(entry.displayName)")
    }.padding(.horizontal, 10).frame(height: 42)
      .background(hovering ? InterfaceColors.hover : .clear, in: RoundedRectangle(cornerRadius: 6))
      .onHover { hovering = $0 }
      .contextMenu {
        Button("重命名…") { model.renameRollPanel(recent: entry) }.disabled(!available || model.isLoading)
        Button("从最近记录中移除") { history.remove(entry) }
      }
      .task(id: scenePhase) {
        let path = entry.path
        available = await Task.detached {
          var directory: ObjCBool = false
          return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
        }.value
      }
  }
  private var dateLabel: String {
    if Calendar.current.isDateInToday(entry.openedAt) { return "今天" }
    if Calendar.current.isDateInYesterday(entry.openedAt) { return "昨天" }
    return entry.openedAt.formatted(.dateTime.month().day())
  }
}
