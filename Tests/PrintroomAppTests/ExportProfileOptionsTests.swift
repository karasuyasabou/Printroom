import AppKit
import PrintroomCore
import Testing

@testable import PrintroomApp

@Suite(.serialized) @MainActor
struct ExportProfileOptionsTests {
  @Test func menuMatchesLightroomAndSelectionStaysInDraft() {
    let initial = ProjectExportSettings(profile: .displayP3, compression: .none)
    let view = ExportOptionsView(settings: initial)
    #expect(view.profilePopUp.itemTitles == [
      "sRGB IEC61966-2.1", "Display P3", "Adobe RGB (1998)", "ProPhoto RGB", "Rec. 2020",
    ])
    #expect(initial.profile == .displayP3)
    #expect(view.settings.profile == .displayP3)
    #expect(view.settings.profileSHA256 == OutputColorProfile.displayP3.profileSHA256)
    #expect(ProjectExportSettings().profile == .displayP3)
    for (index, profile) in OutputColorProfile.selectable.enumerated() {
      view.profilePopUp.selectItem(at: index)
      #expect(view.settings.profile == profile)
      #expect(view.settings.profileSHA256 == profile.profileSHA256)
      let reopened = ExportOptionsView(settings: view.settings)
      #expect(reopened.settings.profile == profile)
    }
  }
  @Test func formatDraftAndCompressionAvailability() throws {
    let original = ProjectExportSettings()
    let view = ExportOptionsView(settings: original)
    #expect(view.formatPopUp.itemTitles == ["16-bit TIFF", "8-bit JPG"])
    view.formatPopUp.selectItem(at: 1)
    view.formatChanged()
    #expect(view.settings.bitsPerSample == 8)
    #expect(!view.compressionCheckbox.isEnabled)
    #expect(original.bitsPerSample == 16)
    let decoded = try JSONDecoder().decode(ProjectExportSettings.self,
      from: JSONEncoder().encode(view.settings))
    #expect(decoded.format == .jpeg)
    let reopened = ExportOptionsView(settings: decoded)
    #expect(reopened.settings.format == .jpeg)
    reopened.formatPopUp.selectItem(at: 0)
    reopened.formatChanged()
    #expect(reopened.compressionCheckbox.isEnabled)
    #expect(reopened.settings.bitsPerSample == 16)
  }

  @Test func rollNameAndDestinationStayPerRollUntilExport() throws {
    let folder = URL(fileURLWithPath: "/tmp", isDirectory: true)
    let original = ProjectExportSettings()
    let draft = ExportOptionsView(settings: original, filenamePrefix: "京都/250D")
    #expect(draft.filenamePrefix == "京都_250D")
    #expect(!draft.isValid)
    draft.destinationURL = folder
    #expect(draft.isValid)
    #expect(original.destinationPath == nil)
    let saved = draft.settings
    #expect(saved.destinationPath == folder.path)
    #expect(saved.filenamePrefix == nil)
    let encoded = try JSONEncoder().encode(saved)
    let decoded = try JSONDecoder().decode(ProjectExportSettings.self, from: encoded)
    let reopened = ExportOptionsView(settings: decoded, filenamePrefix: "新卷名")
    #expect(reopened.filenamePrefix == "新卷名")
    #expect(reopened.destinationURL == folder)
    reopened.prefixField.stringValue = "自定前缀"
    reopened.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    #expect(reopened.settings.filenamePrefix == "自定前缀")
    #expect(ExportOptionsView(settings: reopened.settings, filenamePrefix: "再次改名").filenamePrefix == "自定前缀")
  }

  @Test func exportCheckboxesPersistWithoutChangingInitialDraft() throws {
    let initial = ProjectExportSettings()
    let draft = ExportOptionsView(settings: initial)
    #expect(draft.compressionCheckbox.state == .on)
    #expect(draft.applyCropCheckbox.state == .on)
    draft.compressionCheckbox.state = .off
    draft.applyCropCheckbox.state = .off
    #expect(initial.compression == .deflate)
    #expect(initial.applyCrop)
    let decoded = try JSONDecoder().decode(ProjectExportSettings.self,
      from: JSONEncoder().encode(draft.settings))
    let reopened = ExportOptionsView(settings: decoded)
    #expect(reopened.compressionCheckbox.state == .off)
    #expect(reopened.applyCropCheckbox.state == .off)
    reopened.formatPopUp.selectItem(at: 1)
    reopened.formatChanged()
    #expect(reopened.applyCropCheckbox.isEnabled)
    #expect(!reopened.settings.applyCrop)
    var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
    legacy.removeValue(forKey: "applyCrop")
    let restored = try JSONDecoder().decode(ProjectExportSettings.self,
      from: JSONSerialization.data(withJSONObject: legacy))
    #expect(restored.applyCrop)
  }

}
