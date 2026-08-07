import SwiftUI

enum SkepAppearance: String, CaseIterable, Identifiable {
    case dark
    case light

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dark: "Night"
        case .light: "Day"
        }
    }

    var colorScheme: ColorScheme {
        switch self {
        case .dark: .dark
        case .light: .light
        }
    }
}

enum SkepUI {
    static func canvas(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .black : .white
    }

    static func rail(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.018, green: 0.018, blue: 0.018)
            : Color(red: 0.975, green: 0.975, blue: 0.975)
    }

    static func ink(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white : .black
    }

    static func inverseInk(_ scheme: ColorScheme) -> Color {
        canvas(scheme)
    }

    static func muted(_ scheme: ColorScheme) -> Color {
        ink(scheme).opacity(0.58)
    }

    static func faint(_ scheme: ColorScheme) -> Color {
        ink(scheme).opacity(0.055)
    }

    static func rule(_ scheme: ColorScheme) -> Color {
        ink(scheme).opacity(scheme == .dark ? 0.24 : 0.20)
    }

    static func strongRule(_ scheme: ColorScheme) -> Color {
        ink(scheme).opacity(scheme == .dark ? 0.62 : 0.72)
    }

    static let eyebrow = Font.system(size: 10, weight: .semibold, design: .monospaced)
    static let metadata = Font.system(size: 11, weight: .regular, design: .monospaced)
}

struct SkepPanelModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(SkepUI.canvas(colorScheme))
            .overlay(Rectangle().stroke(SkepUI.rule(colorScheme), lineWidth: 1))
    }
}

extension View {
    func skepPanel(padding: CGFloat = 20) -> some View {
        modifier(SkepPanelModifier(padding: padding))
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    var minWidth: CGFloat?

    init(minWidth: CGFloat? = nil) {
        self.minWidth = minWidth
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(SkepUI.inverseInk(colorScheme))
            .padding(.horizontal, 15)
            .frame(minWidth: minWidth, minHeight: 36)
            .contentShape(Rectangle())
            .background(SkepUI.ink(colorScheme))
            .overlay(Rectangle().stroke(SkepUI.ink(colorScheme), lineWidth: 1))
            .opacity(isEnabled ? (configuration.isPressed ? 0.68 : 1) : 0.32)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    var minWidth: CGFloat?

    init(minWidth: CGFloat? = nil) {
        self.minWidth = minWidth
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(SkepUI.ink(colorScheme))
            .padding(.horizontal, 13)
            .frame(minWidth: minWidth, minHeight: 34)
            .contentShape(Rectangle())
            .background(configuration.isPressed ? SkepUI.faint(colorScheme) : .clear)
            .overlay(Rectangle().stroke(SkepUI.strongRule(colorScheme), lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.32)
    }
}

struct AppearancePicker: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 0) {
            appearanceButton(.light)
            appearanceButton(.dark)
        }
        .overlay(Rectangle().stroke(SkepUI.strongRule(colorScheme), lineWidth: 1))
    }

    private func appearanceButton(_ appearance: SkepAppearance) -> some View {
        let selected = selection == appearance.rawValue
        return Button {
            selection = appearance.rawValue
        } label: {
            Text(appearance.label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(selected ? SkepUI.inverseInk(colorScheme) : SkepUI.ink(colorScheme))
                .frame(maxWidth: .infinity, minHeight: 29)
                .contentShape(Rectangle())
                .background(selected ? SkepUI.ink(colorScheme) : .clear)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(appearance.label) mode")
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }
}

struct ModernTextField: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let help: String?
    let prompt: String
    @Binding var text: String

    init(_ title: String, help: String? = nil, prompt: String, text: Binding<String>) {
        self.title = title
        self.help = help
        self.prompt = prompt
        _text = text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(SkepUI.eyebrow)
                .tracking(0.8)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 11)
                .frame(height: 38)
                .background(SkepUI.canvas(colorScheme))
                .overlay(Rectangle().stroke(SkepUI.strongRule(colorScheme), lineWidth: 1))
            if let help {
                Text(help)
                    .font(.system(size: 11))
                    .foregroundStyle(SkepUI.muted(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct StatusBadge: View {
    @Environment(\.colorScheme) private var colorScheme
    let text: String
    var filled = false

    var body: some View {
        HStack(spacing: 7) {
            Rectangle()
                .fill(filled ? SkepUI.inverseInk(colorScheme) : SkepUI.ink(colorScheme))
                .frame(width: 5, height: 5)
            Text(text.uppercased())
        }
        .font(SkepUI.eyebrow)
        .tracking(0.7)
        .foregroundStyle(filled ? SkepUI.inverseInk(colorScheme) : SkepUI.ink(colorScheme))
        .padding(.horizontal, 9)
        .frame(height: 25)
        .background(filled ? SkepUI.ink(colorScheme) : .clear)
        .overlay(Rectangle().stroke(SkepUI.strongRule(colorScheme), lineWidth: 1))
    }
}

struct StageHeader: View {
    @Environment(\.colorScheme) private var colorScheme
    let number: Int
    let title: String
    let subtitle: String
    var status: String?

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(String(format: "%02d", number))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .frame(width: 36, alignment: .leading)
                .foregroundStyle(SkepUI.muted(colorScheme))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(SkepUI.muted(colorScheme))
            }
            Spacer(minLength: 20)
            if let status {
                Text(status.uppercased())
                    .font(SkepUI.eyebrow)
                    .tracking(0.6)
                    .foregroundStyle(SkepUI.muted(colorScheme))
            }
        }
    }
}
