import AppKit
import SwiftUI

/// Colors and control styles from the Windows app's `Styles/Theme.xaml`.
enum HA {
    static let blue = Color(hex: 0x41BDF5)
    static let dark = Color(hex: 0x1C1C2E)
    static let surface = Color(hex: 0xF7F7F9)
    static let border = Color(hex: 0xE0E0E6)
    static let textPrimary = Color(hex: 0x1A1A2E)
    static let textSecondary = Color(hex: 0x6B7280)
    static let danger = Color(hex: 0xEF4444)
    static let success = Color(hex: 0x22C55E)
    static let warning = Color(hex: 0xF59E0B)

    static let sidebarMuted = Color(hex: 0x7090B0)
    static let sidebarCoffee = Color(hex: 0x8FA9C4)
    static let sidebarDivider = Color(hex: 0x29445F)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

extension Text {
    func headingStyle(size: CGFloat = 24) -> some View {
        font(.system(size: size, weight: .semibold))
            .foregroundColor(HA.textPrimary)
            .padding(.bottom, 6)
    }

    func subheadingStyle() -> some View {
        font(.system(size: 13))
            .foregroundColor(HA.textSecondary)
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
    }

    func bodyStyle(semibold: Bool = false) -> some View {
        font(.system(size: 13, weight: semibold ? .semibold : .regular))
            .foregroundColor(HA.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }

    func captionStyle() -> some View {
        font(.system(size: 11))
            .foregroundColor(HA.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension View {
    /// `CardStyle` and the other rounded bordered panels.
    func card(background: Color = .white, border: Color = HA.border, lineWidth: CGFloat = 1,
              horizontal: CGFloat = 18, vertical: CGFloat = 14) -> some View {
        padding(.horizontal, horizontal)
            .padding(.vertical, vertical)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(background))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(border, lineWidth: lineWidth))
    }
}

/// `PrimaryButton`, `SecondaryButton` and `DangerButton`. The danger button is based on the
/// primary template in WPF, so it shares its hover, pressed and disabled colors.
struct HAButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
        case danger
    }

    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        HAButton(configuration: configuration, kind: kind)
    }
}

private struct HAButton: View {
    let configuration: ButtonStyle.Configuration
    let kind: HAButtonStyle.Kind
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: kind == .secondary ? .regular : .semibold))
            .foregroundColor(foreground)
            .padding(.horizontal, kind == .secondary ? 20 : 24)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 6).fill(background))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(kind == .secondary ? HA.border : Color.clear, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onHover { hovering = $0 }
    }

    private var foreground: Color {
        switch kind {
        case .primary, .danger:
            return .white
        case .secondary:
            return isEnabled ? HA.textSecondary : Color(hex: 0xC0C0C8)
        }
    }

    private var background: Color {
        if kind == .secondary {
            return hovering && isEnabled ? Color(hex: 0xF0F0F5) : .clear
        }
        if !isEnabled { return Color(hex: 0xB0D8F0) }
        if configuration.isPressed { return Color(hex: 0x1A90C8) }
        if hovering { return Color(hex: 0x2BA8E0) }
        return kind == .danger ? HA.danger : HA.blue
    }
}

/// Default WPF progress bar look.
struct HAProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color(hex: 0xE6E6E6))
                Rectangle()
                    .fill(Color(hex: 0x06B025))
                    .frame(width: geometry.size.width * CGFloat(min(max(value, 0), 100) / 100))
            }
            .overlay(Rectangle().strokeBorder(Color(hex: 0xBCBCBC), lineWidth: 1))
        }
        .frame(height: 10)
    }
}

/// Drive tags such as "Large drive" (`DrivePill*Style`).
struct Pill: View {
    let text: String
    let background: Color
    let border: Color
    let foreground: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .lineLimit(1)
            .foregroundColor(foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 9).fill(background))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(border, lineWidth: 1))
    }
}

/// A checkbox whose label wraps like the WPF `CheckBox` with a `TextBlock`.
struct HACheckbox: View {
    @Binding var isOn: Bool
    let text: String
    var semibold = false
    var color = HA.textPrimary

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(text)
                .font(.system(size: 13, weight: semibold ? .semibold : .regular))
                .foregroundColor(color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.checkbox)
    }
}

enum AppImages {
    static func named(_ name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }

    static let installerIcon = named("InstallerIcon")
    static let coffeeButton = named("bmc-button")
}
