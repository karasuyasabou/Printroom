import AppKit
import PrintroomCore

/// A panel-local draft. Reading settings never changes the project's preferences.
@MainActor final class ExportOptionsView: NSView {
  let profilePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
  let compressionPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
  let prefixField = NSTextField(string: "")
  var filenamePrefix: String { prefixField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
  private let initialSettings: ProjectExportSettings

  var settings: ProjectExportSettings {
    var value = initialSettings
    if let rawValue = profilePopUp.selectedItem?.representedObject as? String,
      let profile = OutputColorProfile(rawValue: rawValue)
    { value.profile = profile }
    if let rawValue = compressionPopUp.selectedItem?.representedObject as? String,
      let compression = TIFFCompression(rawValue: rawValue)
    { value.compression = compression }
    return value
  }

  init(settings: ProjectExportSettings, filenamePrefix: String = "Printroom") {
    initialSettings = settings
    super.init(frame: NSRect(x: 0, y: 0, width: 420, height: 172))
    prefixField.stringValue = filenamePrefix
    prefixField.setAccessibilityIdentifier("export-prefix")
    prefixField.setAccessibilityLabel("文件名前缀")
    identifier = NSUserInterfaceItemIdentifier("export-options")
    profilePopUp.identifier = NSUserInterfaceItemIdentifier("export-profile")
    profilePopUp.setAccessibilityIdentifier("export-profile")
    profilePopUp.setAccessibilityLabel("输出 ICC")
    compressionPopUp.identifier = NSUserInterfaceItemIdentifier("export-compression")
    compressionPopUp.setAccessibilityIdentifier("export-compression")
    compressionPopUp.setAccessibilityLabel("压缩")

    for profile in OutputColorProfile.selectable {
      profilePopUp.addItem(withTitle: profile.label)
      profilePopUp.lastItem?.representedObject = profile.rawValue
      if profile == settings.profile { profilePopUp.select(profilePopUp.lastItem) }
    }
    for compression in TIFFCompression.allCases {
      compressionPopUp.addItem(withTitle: compression == .none ? "无压缩" : "ZIP")
      compressionPopUp.lastItem?.representedObject = compression.rawValue
      if compression == .deflate { compressionPopUp.select(compressionPopUp.lastItem) }
    }

    let grid = NSGridView(views: [
      [NSTextField(labelWithString: "文件名前缀"), prefixField],
      [NSTextField(labelWithString: "编号"), NSTextField(labelWithString: "自动追加胶卷原编号，如 -02.tiff")],
      [NSTextField(labelWithString: "格式"), NSTextField(labelWithString: "16-bit TIFF")],
      [NSTextField(labelWithString: "输出 ICC"), profilePopUp],
      [NSTextField(labelWithString: "压缩"), compressionPopUp],
    ])
    grid.columnSpacing = 12
    grid.rowSpacing = 10
    grid.rowAlignment = .firstBaseline
    grid.column(at: 0).xPlacement = .trailing
    grid.column(at: 1).xPlacement = .fill
    grid.translatesAutoresizingMaskIntoConstraints = false
    addSubview(grid)
    NSLayoutConstraint.activate([
      grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      grid.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      grid.topAnchor.constraint(equalTo: topAnchor, constant: 12),
      grid.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// Shared by the real export panels and window QA; batch options start visible.
  func attach(to panel: NSSavePanel) {
    panel.accessoryView = self
    if let openPanel = panel as? NSOpenPanel { openPanel.isAccessoryViewDisclosed = true }
  }
}
