import SwiftUI

/// Motion for local interaction feedback. Live stats and log updates stay immediate.
enum RunnerMotion {
    static func press(reduceMotion: Bool, isPressed: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: isPressed ? 0.08 : 0.16)
    }

    static func hover(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.12)
    }

    static func content(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.18)
    }
}

/// Feedback for custom surfaces that don't get a native button bezel. Bordered
/// buttons, menus, pickers, toggles, and sidebar lists retain their system styles.
struct RunnerButtonStyle: ButtonStyle {
    enum Surface {
        case compact, row, card
    }

    var surface: Surface = .compact
    var cornerRadius: CGFloat = 6

    func makeBody(configuration: Configuration) -> some View {
        Feedback(configuration: configuration, surface: surface, cornerRadius: cornerRadius)
    }

    private struct Feedback: View {
        let configuration: ButtonStyleConfiguration
        let surface: Surface
        let cornerRadius: CGFloat

        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.colorSchemeContrast) private var contrast
        @State private var isHovered = false

        private var isPressed: Bool { isEnabled && configuration.isPressed }
        private var highlighted: Bool { isEnabled && (isHovered || isFocused) }
        private var tint: Color { configuration.role == .destructive ? .red : .accentColor }
        private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius) }

        private var fill: Color {
            if isPressed { return tint.opacity(contrast == .increased ? 0.26 : 0.16) }
            if highlighted { return Color.primary.opacity(contrast == .increased ? 0.12 : 0.06) }
            return .clear
        }

        private var scale: CGFloat {
            guard isPressed, !reduceMotion else { return 1 }
            return surface == .compact ? 0.94 : 0.995
        }

        var body: some View {
            configuration.label
                .padding(.horizontal, surface == .compact ? 6 : 0)
                .padding(.vertical, surface == .compact ? 5 : 0)
                // Keep the outer highlight and hit area stable while the label compresses.
                .scaleEffect(scale)
                .background(fill, in: shape)
                .overlay {
                    shape.strokeBorder(
                        isEnabled && isFocused ? Color.accentColor : .clear,
                        lineWidth: 2
                    )
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                .contentShape(shape)
                .opacity(isEnabled ? 1 : 0.45)
                .animation(RunnerMotion.press(reduceMotion: reduceMotion, isPressed: isPressed), value: isPressed)
                .animation(RunnerMotion.hover(reduceMotion: reduceMotion), value: highlighted)
                .onHover { isHovered = isEnabled && $0 }
                .onChange(of: isEnabled) { _, enabled in
                    if !enabled { isHovered = false }
                }
                .onDisappear { isHovered = false }
        }
    }
}
