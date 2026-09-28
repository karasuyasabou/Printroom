import AppKit
import PrintroomCore

/// A panel-local draft. Reading settings never changes the project's preferences.
@MainActor final class ExportOptionsView: NSView, NSTextFieldDelegate {
  let profilePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
  let formatPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
  let compressionCheckbox = NSButton(checkboxWithTitle: "ZIP 压缩", target: nil, action: nil)
  let applyCropCheckbox = NSButton(checkboxWithTitle: "应用裁剪", target: nil, action: nil)
  let prefixField = NSTextField(string: "")
  var filenamePrefix: String { prefixField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
  private let destinationField = NSTextField(labelWithString: "请选择文件夹")
  private var grid: NSGridView!
  private let rollName: String
  private var customPrefix: Bool
  var destinationURL: URL?
  var validityChanged: ((Bool) -> Void)?
  var isValid: Bool {
    guard let destinationURL else { return false }
    var directory: ObjCBool = false
    return FileManager.default.fileExists(atPath: destinationURL.path, isDirectory: &directory)
      && directory.boolValue && !filenamePrefix.isEmpty
      && !filenamePrefix.contains(where: { $0 == "/" || $0 == ":" || $0.isNewline || $0.asciiValue == 0 })
  }
  func refreshValidity() { validityChanged?(isValid) }
  func controlTextDidChange(_ notification: Notification) {
    customPrefix = true
    refreshValidity()
  }
  @objc private func chooseDestination() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "选择"
    panel.directoryURL = destinationURL
    if panel.runModal() == .OK, let url = panel.url {
      destinationURL = url
      destinationField.stringValue = url.path
      destinationField.toolTip = url.path
      refreshValidity()
    }
  }
  private let initialSettings: ProjectExportSettings

  var settings: ProjectExportSettings {
    var value = initialSettings
    if let rawValue = profilePopUp.selectedItem?.representedObject as? String,
      let profile = OutputColorProfile(rawValue: rawValue)
    { value.profile = profile }
    value.compression = compressionCheckbox.state == .on ? .deflate : .none
    value.applyCrop = applyCropCheckbox.state == .on
    value.format = ExportFormat(rawValue: formatPopUp.selectedItem?.representedObject as? String ?? "") ?? .tiff
    value.destinationPath = destinationURL?.path
    value.filenamePrefix = customPrefix ? filenamePrefix : nil
    return value
  }

  init(settings: ProjectExportSettings, filenamePrefix: String = "Printroom") {
    initialSettings = settings
    rollName = Self.safePrefix(filenamePrefix)
    customPrefix = settings.filenamePrefix != nil
    destinationURL = settings.destinationPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
    super.init(frame: NSRect(x: 0, y: 0, width: 500, height: settings.format == .tiff ? 225 : 190))
    prefixField.stringValue = settings.filenamePrefix ?? rollName
    prefixField.delegate = self
    prefixField.setAccessibilityIdentifier("export-prefix")
    prefixField.setAccessibilityLabel("文件名前缀")
    identifier = NSUserInterfaceItemIdentifier("export-options")
    profilePopUp.identifier = NSUserInterfaceItemIdentifier("export-profile")
    profilePopUp.setAccessibilityIdentifier("export-profile")
    profilePopUp.setAccessibilityLabel("输出 ICC")
    compressionCheckbox.setAccessibilityIdentifier("export-compression")
    compressionCheckbox.state = settings.compression == .deflate ? .on : .off
    applyCropCheckbox.setAccessibilityIdentifier("export-apply-crop")
    applyCropCheckbox.state = settings.applyCrop ? .on : .off

    for profile in OutputColorProfile.selectable {
      profilePopUp.addItem(withTitle: profile.label)
      profilePopUp.lastItem?.representedObject = profile.rawValue
      if profile == settings.profile { profilePopUp.select(profilePopUp.lastItem) }
    }
    formatPopUp.setAccessibilityIdentifier("export-format")
    formatPopUp.setAccessibilityLabel("格式")
    for format in ExportFormat.allCases {
      formatPopUp.addItem(withTitle: format.label)
      formatPopUp.lastItem?.representedObject = format.rawValue
      if format == settings.format { formatPopUp.select(formatPopUp.lastItem) }
    }
    formatPopUp.target = self
    formatPopUp.action = #selector(formatChanged)


    let choose = NSButton(title: "选择…", target: self, action: #selector(chooseDestination))
    destinationField.stringValue = destinationURL.map { FileManager.default.fileExists(atPath: $0.path) ? $0.path : "原文件夹不可用，请重新选择" } ?? "请选择文件夹"
    destinationField.lineBreakMode = .byTruncatingMiddle
    destinationField.toolTip = destinationURL?.path
    destinationField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    destinationField.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let destinationRow = NSStackView(views: [destinationField, choose])
    destinationRow.spacing = 8
    prefixField.setContentHuggingPriority(.defaultLow, for: .horizontal)
    grid = NSGridView(views: [
      [NSTextField(labelWithString: "目的地"), destinationRow],
      [NSTextField(labelWithString: "文件名前缀"), prefixField],
      [NSTextField(labelWithString: "格式"), formatPopUp],
      [NSTextField(labelWithString: "色彩空间"), profilePopUp],
      [NSTextField(labelWithString: ""), compressionCheckbox],
      [NSTextField(labelWithString: ""), applyCropCheckbox],
    ])
    formatChanged()
    grid.columnSpacing = 12
    grid.rowSpacing = 10
    grid.rowAlignment = .firstBaseline
    grid.setContentHuggingPriority(.required, for: .vertical)
    grid.column(at: 0).width = 90
    grid.column(at: 0).xPlacement = .trailing
    grid.column(at: 1).xPlacement = .fill
    grid.translatesAutoresizingMaskIntoConstraints = false
    addSubview(grid)
    NSLayoutConstraint.activate([
      grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      grid.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      grid.topAnchor.constraint(equalTo: topAnchor, constant: 12),
      grid.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12),
    ])
  }

  @objc func formatChanged() {
    compressionCheckbox.isEnabled = settings.format == .tiff
    grid?.row(at: 4).isHidden = settings.format != .tiff
    frame.size.height = settings.format == .tiff ? 225 : 190
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private static func safePrefix(_ name: String) -> String {
    let cleaned = String(name.map { character in
      character == "/" || character == ":" || character.isNewline || character == "\0" ? "_" : character
    }).trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned.isEmpty ? "Printroom" : cleaned
  }

}
