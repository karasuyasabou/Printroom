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
}
