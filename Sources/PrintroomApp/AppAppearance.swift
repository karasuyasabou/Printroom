import AppKit
import SwiftUI

/// Application-wide appearance also covers AppKit alerts and auxiliary windows.
enum AppAppearance: String, CaseIterable {
  case light, dark

  static let defaultsKey = "appAppearance"
  var title: String { self == .light ? "浅色" : "深色" }

  @MainActor func apply() {
    NSApp.appearance = NSAppearance(named: self == .light ? .aqua : .darkAqua)
  }
}

struct AppearanceToggle: View {
  @AppStorage(AppAppearance.defaultsKey) private var appearance: AppAppearance = .dark
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    HStack(spacing: 2) {
      segment(.light, symbol: "sun.max.fill")
      segment(.dark, symbol: "moon.fill")
    }
    .padding(3)
    .background(InterfaceColors.secondaryPanel, in: Capsule())
    .overlay(Capsule().strokeBorder(InterfaceColors.separator, lineWidth: 0.5))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("外观")
    .accessibilityIdentifier("appearance-toggle")
  }

  private func segment(_ theme: AppAppearance, symbol: String) -> some View {
    let selected = (colorScheme == .dark) == (theme == .dark)
    return Button {
      appearance = theme
      theme.apply()
    } label: {
      Image(systemName: symbol)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(selected ? InterfaceColors.accent : InterfaceColors.secondaryText)
        .frame(width: 28, height: 24)
        .background(selected ? InterfaceColors.control : .clear, in: Capsule())
        .overlay(Capsule().strokeBorder(selected ? InterfaceColors.separator : .clear, lineWidth: 0.5))
        .contentShape(Capsule())
    }
    .buttonStyle(AppearanceButtonStyle())
    .help("\(theme.title)外观")
    .accessibilityLabel("\(theme.title)外观")
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

private struct AppearanceButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    Surface(label: configuration.label, pressed: configuration.isPressed)
  }

  private struct Surface: View {
    let label: ButtonStyleConfiguration.Label
    let pressed: Bool
    @State private var hovering = false

    var body: some View {
      label
        .background(hovering || pressed ? InterfaceColors.hover : .clear, in: Capsule())
        .opacity(pressed ? 0.7 : 1)
        .onHover { hovering = $0 }
    }
  }
}

/// Shared semantic roles; values are sRGB and resolve with the current AppKit appearance.
/// Photo canvas is deliberately neutral and independent of the UI surfaces.
enum InterfaceColors {
  static func native(light: UInt32, dark: UInt32) -> NSColor {
    NSColor(name: nil) { appearance in
      let rgb = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
      return NSColor(srgbRed: Double((rgb >> 16) & 255) / 255,
        green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, alpha: 1)
    }
  }
  static func color(light: UInt32, dark: UInt32) -> Color {
    Color(nsColor: native(light: light, dark: dark))
  }

  static let window = color(light: 0xF7F7F7, dark: 0x282828)
  static let panel = color(light: 0xF3F3F3, dark: 0x242424)
  static let secondaryPanel = color(light: 0xEEEEEE, dark: 0x202020)
  static let control = color(light: 0xFFFFFF, dark: 0x363636)
  static let hover = color(light: 0xE7E7E7, dark: 0x414141)
  static let selected = color(light: 0xE4E4E4, dark: 0x444033)
  static let accent = color(light: 0x86621F, dark: 0xD6B570)
  static let primaryText = color(light: 0x282828, dark: 0xE5E5E3)
  static let secondaryText = color(light: 0x666666, dark: 0xAAA9A5)
  static let tertiaryText = color(light: 0x8A8A8A, dark: 0x7F7F7B)
  static let separator = color(light: 0xD6D6D6, dark: 0x393939)
  static let subtleSeparator = separator.opacity(0.45)
  static let histogram = color(light: 0xF5F5F5, dark: 0x1E1E1E)
  static let canvas = native(light: 0xD6D6D6, dark: 0x484848)
  static let home = native(light: 0xF7F7F7, dark: 0x131313)

  // Channel colors retain their meaning but need more weight on light surfaces.
  static let red = color(light: 0xB95145, dark: 0xEB7D6E)
  static let green = color(light: 0x438454, dark: 0x7ABF8C)
  static let blue = color(light: 0x477BAD, dark: 0x78A6E0)
  static let temperature = color(light: 0xAB702A, dark: 0xFF9500)
  static let tint = color(light: 0x935DA5, dark: 0xAF52DE)
}

/// Adds a surface-only hover without altering the thumbnail's label or hit geometry.
struct FilmstripButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    FilmstripButtonSurface(label: configuration.label, pressed: configuration.isPressed)
  }
  private struct FilmstripButtonSurface: View {
    let label: ButtonStyleConfiguration.Label
    let pressed: Bool
    @State private var hovering = false
    var body: some View {
      label.background(hovering || pressed ? InterfaceColors.hover : .clear,
        in: RoundedRectangle(cornerRadius: 5))
        .onHover { hovering = $0 }
    }
  }
}
