import SwiftUI

/// Small pill showing the `gh` authentication state.
struct GHAuthChip: View {
    let auth: GHAuthStatus

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .help(helpText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(helpText)
    }

    private var iconName: String {
        if !auth.available { return "exclamationmark.triangle.fill" }
        return auth.authenticated ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.xmark"
    }
    private var iconColor: Color {
        if !auth.available { return .orange }
        return auth.authenticated ? .green : .red
    }
    private var label: String {
        if !auth.available { return "gh missing" }
        return auth.account ?? (auth.authenticated ? "signed in" : "signed out")
    }
    private var helpText: String {
        if !auth.available { return auth.message ?? "GitHub CLI not found" }
        if auth.authenticated {
            return "gh authenticated as \(auth.account ?? "?") — scopes: \(auth.scopes.joined(separator: ", "))"
        }
        return auth.message ?? "gh is not authenticated"
    }
}

/// A dismissible status banner.
struct BannerView: View {
    let message: BannerMessage
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName).foregroundStyle(tint)
            Text(message.text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss")
        }
        .padding(8)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(tint.opacity(0.35)))
    }

    private var iconName: String {
        switch message.kind {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .error: return "exclamationmark.octagon.fill"
        }
    }
    private var tint: Color {
        switch message.kind {
        case .info: return .accentColor
        case .success: return .green
        case .error: return .red
        }
    }
}

/// A labelled key/value line used in detail panels.
struct StatRow: View {
    let label: String
    let value: String
    var mono: Bool = false
    var valueColor: Color = .primary

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(mono ? .caption.monospaced() : .caption)
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}

/// A compact section header.
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .kerning(0.5)
    }
}
