import SwiftUI

/// The palette of the 3D panel, so the native screens read as the same app.
enum Theme {
    static let background = Color(red: 0.039, green: 0.055, blue: 0.102)
    static let raised = Color(red: 0.075, green: 0.094, blue: 0.157)
    static let surface = Color.white.opacity(0.055)
    static let surfaceHigh = Color.white.opacity(0.1)
    static let line = Color.white.opacity(0.085)
    static let text = Color(red: 0.953, green: 0.961, blue: 0.98)
    static let muted = Color(red: 0.87, green: 0.9, blue: 0.97).opacity(0.6)
    static let faint = Color(red: 0.87, green: 0.9, blue: 0.97).opacity(0.36)
    static let accent = Color(red: 0.239, green: 0.545, blue: 1)
    static let warm = Color(red: 1, green: 0.706, blue: 0.42)
    static let green = Color(red: 0.29, green: 0.87, blue: 0.5)
    static let red = Color(red: 1, green: 0.47, blue: 0.43)
}

/// A rounded glass panel: the container of every settings group.
struct Card<Content: View>: View {
    var padding: CGFloat = 0
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.line))
    }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .bold))
            .kerning(1.1)
            .foregroundStyle(Theme.faint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The rounded square with a symbol that starts a row.
struct IconBadge: View {
    let symbol: String
    var tint: Color = Theme.accent
    var size: CGFloat = 38

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: size * 0.32, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct StatusDot: View {
    let color: Color
    var pulsing = false
    @State private var on = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .shadow(color: color.opacity(0.9), radius: 4)
            .opacity(pulsing && on ? 0.35 : 1)
            .animation(pulsing ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default, value: on)
            .onAppear { on = true }
            .accessibilityHidden(true)
    }
}

struct RowDivider: View {
    var body: some View {
        Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 66)
    }
}

/// The blue call to action.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(
                LinearGradient(colors: [Color(red: 0.353, green: 0.635, blue: 1), Color(red: 0.184, green: 0.482, blue: 0.949)],
                               startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: Theme.accent.opacity(enabled ? 0.45 : 0), radius: 14, y: 8)
            .opacity(enabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var tint: Color = Theme.text

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Theme.surfaceHigh, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Rows highlight while pressed, like a list cell.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .background(configuration.isPressed ? Theme.surfaceHigh : .clear)
    }
}

/// A small capsule button at the end of a row ("Connect", "Turn off").
struct PillButtonStyle: ButtonStyle {
    var tint: Color = Theme.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(tint == Theme.accent ? .white : tint)
            .padding(.horizontal, 14)
            .frame(minHeight: 32)
            .background(tint == Theme.accent ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.surfaceHigh), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
