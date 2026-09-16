import SwiftUI

enum PreviewViewportMode { case fit, native }

struct PreviewToolLabel<Content: View>: View {
  var selected = false
  @ViewBuilder var content: () -> Content
  @Environment(\.isEnabled) private var isEnabled
  @State private var hovering = false
  private let accent = Color(red: 0.84, green: 0.71, blue: 0.44)

  var body: some View {
    content()
      .font(.system(size: 12, weight: .medium))
      .foregroundStyle(selected ? accent : Color(white: 0.8))
      .padding(.horizontal, 9)
      .frame(height: 26)
      .background(selected ? accent.opacity(0.12) : .white.opacity(hovering && isEnabled ? 0.07 : 0),
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
          if let value { Text(value).foregroundStyle(.secondary) }
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
