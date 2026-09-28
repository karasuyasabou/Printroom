import SwiftUI

enum PreviewViewportMode { case fit, native }

struct PreviewToolLabel<Content: View>: View {
  var selected = false
  @ViewBuilder var content: () -> Content
  @Environment(\.isEnabled) private var isEnabled
  @State private var hovering = false
  private let accent = InterfaceColors.accent

  var body: some View {
    content()
      .font(.system(size: 12, weight: .medium))
      .foregroundStyle(selected ? accent : InterfaceColors.primaryText)
      .padding(.horizontal, 9)
      .frame(height: 26)
      .background(selected ? InterfaceColors.selected : (hovering && isEnabled ? InterfaceColors.hover : Color.clear),
        in: RoundedRectangle(cornerRadius: 5))
      .contentShape(Rectangle())
      .opacity(isEnabled ? 1 : 0.4)
      .onHover { hovering = $0 }
  }
}

struct PreviewToolMenu<Content: View>: View {
  let title: String
  var value: String? = nil
  @ViewBuilder var content: () -> Content

  var body: some View {
    Menu(content: content) {
      PreviewToolLabel {
        HStack(spacing: 6) {
          Text(title)
          if let value { Text(value).foregroundStyle(InterfaceColors.secondaryText) }
          Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium))
        }
      }
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .accessibilityLabel(title)
    .accessibilityValue(value ?? "")
  }
}

/// Ordinary toolbar actions use neutral surfaces; gold remains a selection/brand signal.
struct MainToolbarButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    Surface(label: configuration.label, pressed: configuration.isPressed)
  }
  private struct Surface: View {
    let label: ButtonStyleConfiguration.Label
    let pressed: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false
    var body: some View {
      label
        .foregroundStyle(isEnabled ? InterfaceColors.primaryText : InterfaceColors.tertiaryText)
        .padding(.horizontal, 9).frame(height: 28)
        .background(pressed || (hovering && isEnabled) ? InterfaceColors.hover : InterfaceColors.control,
          in: RoundedRectangle(cornerRadius: 6))
        .opacity(isEnabled ? 1 : 0.5)
        .onHover { hovering = $0 }
    }
  }
}

struct MainToolbarVisibility: ViewModifier {
  @ViewBuilder func body(content: Content) -> some View {
    if #available(macOS 15.0, *) {
      content.windowToolbarFullScreenVisibility(.visible)
    } else {
      content
    }
  }
}
