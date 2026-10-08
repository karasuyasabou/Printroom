import AppKit
import PrintroomCore
import SwiftUI
import UniformTypeIdentifiers

enum DensityMatrixInput {
  static func parse(_ text: String) throws -> RGBMatrix {
    let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;[]()，；"))
    let parts = text.components(separatedBy: separators).filter { !$0.isEmpty }
    guard parts.count == 9 else { throw PrintroomError.invalid("请粘贴按行排列的九个数值。") }
    let values = try parts.map { part -> Float in
      guard let value = Float(part), value.isFinite else {
        throw PrintroomError.invalid("矩阵系数必须是有限数值。")
      }
      return value
    }
    return try RGBMatrix(values)
  }
}

struct MatrixManagerView: View {
  @ObservedObject var model: EditorModel
  let kind: MatrixKind
  @Environment(\.dismiss) private var dismiss
  @State private var selected: MatrixPreset?
  @State private var draftID = UUID().uuidString
  @State private var name = ""
  @State private var fields = RGBMatrix.identity.values.map { String($0) }
  @State private var cmosReady = false
  @State private var busy = false
  @State private var message = ""
  @State private var failure: String?
  @State private var identification: [String] = []
  @State private var calibrationTask: Task<Void, Never>?
  private var readOnly: Bool { selected?.isBuiltIn == true }
  private var validDraft: MatrixPreset? {
    guard !readOnly, kind == .density || cmosReady,
      let matrix = try? DensityMatrixInput.parse(fields.joined(separator: " ")) else { return nil }
    return try? MatrixPreset(id: draftID, name: name, coefficients: matrix)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        Text("管理\(kind.label)").font(.title2.bold())
        Spacer()
        Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
      }
      if let error = model.matrixLibraryError {
        Text("矩阵库未能读取：\(error)").foregroundStyle(.red)
        Button("重新载入") { model.reloadMatrixLibrary() }
      }
      HStack(alignment: .top, spacing: 22) {
        VStack(alignment: .leading, spacing: 12) {
          ScrollView {
            VStack(alignment: .leading, spacing: 4) {
              Text("内置").font(.caption).foregroundStyle(InterfaceColors.secondaryText)
              ForEach(kind.builtIns) { preset in row(preset) }
              Divider().padding(.vertical, 6)
              Text("本机矩阵").font(.caption).foregroundStyle(InterfaceColors.secondaryText)
              ForEach(model.matrixLibrary.filter { $0.kind == kind }.map(\.preset)) { preset in row(preset) }
              let current = kind == .cmos ? model.cmosMatrix : model.matrix
              if model.isMatrixSnapshot(current, kind: kind) {
                Divider().padding(.vertical, 6)
                Text("本卷快照").font(.caption).foregroundStyle(InterfaceColors.secondaryText)
                row(current)
              }
            }
          }.frame(height: 258)
          HStack {
            Button("新增") { newDraft() }
            Button("复制") { duplicate() }.disabled(selected == nil)
            Button("删除", role: .destructive) { remove() }
              .disabled(readOnly || selected == nil || !model.matrixLibrary.contains { $0.preset.id == selected?.id })
          }.controlSize(.small)
        }.frame(width: 204).disabled(busy || model.matrixLibraryError != nil)
        Divider()
        VStack(alignment: .leading, spacing: 14) {
          TextField("矩阵名称", text: $name).textFieldStyle(.roundedBorder).disabled(readOnly || busy)
          if kind == .cmos {
            Button(busy ? "正在识别并计算…" : "选择三张 TIFF / RAW…") { selectSources() }
              .disabled(readOnly || busy || model.matrixLibraryError != nil)
          }
          Grid(horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
              Text("")
              ForEach(["输入 R", "输入 G", "输入 B"], id: \.self) { Text($0).font(.caption).foregroundStyle(InterfaceColors.secondaryText) }
            }
            ForEach(0..<3) { row in
              GridRow {
                Text(["输出 R′", "输出 G′", "输出 B′"][row]).font(.caption).foregroundStyle(InterfaceColors.secondaryText)
                ForEach(0..<3) { column in
                  Group {
                    if readOnly || kind == .cmos {
                      Text(fields[row*3+column]).textSelection(.enabled)
                        .lineLimit(1).minimumScaleFactor(0.65).help(fields[row*3+column])
                        .frame(width: 78, height: 22, alignment: .leading).padding(.horizontal, 5)
                        .background(InterfaceColors.control, in: RoundedRectangle(cornerRadius: 5))
                    } else {
                      TextField("系数", text: $fields[row*3+column])
                        .textFieldStyle(.roundedBorder).frame(width: 88).disabled(busy)
                    }
                  }
                  .font(.system(size: 12, design: .monospaced))
                  .accessibilityLabel("输出 \(["R", "G", "B"][row]) 输入 \(["R", "G", "B"][column]) 系数")
                }
              }
            }
          }
          if kind == .density {
            Button("粘贴 3×3 系数") { paste() }.disabled(readOnly || busy)
          }
          ForEach(identification, id: \.self) { Text($0).font(.caption).lineLimit(2) }
          Spacer(minLength: 0)
          if let failure { Text(failure).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
          if !message.isEmpty { Text(message).font(.caption).foregroundStyle(InterfaceColors.secondaryText) }
          HStack {
            if readOnly {
              Button("应用到本卷") {
                if let selected { model.setMatrixPreset(selected, kind: kind); message = "已应用" }
              }.disabled(model.project == nil)
            } else {
              Button("保存到电脑") { save(apply: false) }.disabled(validDraft == nil)
              Button("保存并应用到本卷") { save(apply: true) }.disabled(validDraft == nil || model.project == nil)
            }
          }.disabled(busy || model.matrixLibraryError != nil)
        }.frame(width: 370, alignment: .leading)
      }
    }
    .padding(24).frame(width: 666, height: 500)
    .onAppear { choose(kind == .cmos ? model.cmosMatrix : model.matrix) }
    .onDisappear { calibrationTask?.cancel() }
  }

  private func row(_ preset: MatrixPreset) -> some View {
    Button { choose(preset) } label: {
      HStack {
        Text(preset.name).lineLimit(2)
        Spacer(minLength: 2)
        if preset.isBuiltIn { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(InterfaceColors.secondaryText) }
      }.padding(7).frame(maxWidth: .infinity, alignment: .leading)
        .background(selected == preset ? InterfaceColors.selected : Color.clear, in: RoundedRectangle(cornerRadius: 5))
    }.buttonStyle(.plain)
  }
  private func choose(_ preset: MatrixPreset) {
    selected = preset; draftID = preset.id; name = preset.name
    fields = preset.coefficients.values.map { String($0) }
    cmosReady = true; identification = []; message = ""; failure = nil
  }
  private func newDraft() {
    selected = nil; draftID = UUID().uuidString; name = ""
    fields = RGBMatrix.identity.values.map { String($0) }
    cmosReady = false; identification = []; message = ""; failure = nil
  }
  private func duplicate() {
    guard let selected else { return }
    choose(selected)
    self.selected = nil; draftID = UUID().uuidString; name = String((selected.name + " 副本").prefix(80))
  }
  private func paste() {
    do {
      let matrix = try DensityMatrixInput.parse(NSPasteboard.general.string(forType: .string) ?? "")
      fields = matrix.values.map { String($0) }; failure = nil; message = ""
    } catch { failure = error.localizedDescription }
  }
  private func save(apply: Bool) {
    guard let preset = validDraft else { return }
    do {
      try model.saveMatrix(preset, kind: kind, apply: apply)
      selected = preset; failure = nil
      message = apply ? "已应用" : "已保存"
    } catch { failure = error.localizedDescription }
  }
  private func remove() {
    guard let selected else { return }
    do {
      try model.deleteMatrix(selected); newDraft(); message = "已删除"
    } catch { failure = error.localizedDescription }
  }
  private func selectSources() {
    let panel = NSOpenPanel()
    panel.title = "选择红、绿、蓝光源的三张 TIFF / ARW"
    panel.allowedContentTypes = [.tiff, UTType(filenameExtension: "arw") ?? .rawImage]
    panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
    guard panel.runModal() == .OK else { return }
    let urls = panel.urls
    guard urls.count == 3 else { failure = "请选择恰好三张 TIFF / ARW 照片。"; return }
    busy = true; failure = nil; message = ""; identification = []
    calibrationTask = Task {
      let worker = Task.detached(priority: .userInitiated) { try CMOSCalibration.make(sources: urls) }
      do {
        let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        try Task.checkCancellation()
        fields = result.coefficients.values.map { String($0) }
        cmosReady = true
        identification = result.sourceIndices.enumerated().map { channel, index in
          "\(["R", "G", "B"][channel]) 光源：\(urls[index].lastPathComponent)"
        }
        if name.isEmpty { name = "CMOS \(Date().formatted(date: .numeric, time: .shortened))" }
        message = "已计算"
      } catch {
        if !Task.isCancelled { failure = error.localizedDescription }
      }
      if !Task.isCancelled { busy = false }
    }
  }
}
