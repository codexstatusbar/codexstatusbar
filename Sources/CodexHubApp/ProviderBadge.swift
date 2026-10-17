import SwiftUI
import CodexHubCore

extension SessionProvider {
    var badgeColor: Color { self == .claude ? Color(red: 0.85, green: 0.47, blue: 0.34) : Color(red: 0.2, green: 0.45, blue: 0.9) }
}

/// Session icon showing which tool it belongs to, without bundling third-party logos.
struct ProviderBadge: View {
    let provider: SessionProvider
    var size: CGFloat = 32

    /// Codex: a cloud holding a shell prompt. Claude: an asterisk burst.
    @ViewBuilder private var glyph: some View {
        if provider == .claude {
            Image(systemName: "asterisk").font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(provider.badgeColor)
        } else {
            Image(systemName: "cloud.fill").font(.system(size: size * 0.62)).foregroundStyle(provider.badgeColor)
                .overlay(Text(">_").font(.system(size: size * 0.2, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white).offset(y: size * 0.02))
        }
    }

    var body: some View {
        glyph
            .frame(width: size, height: size)
            .background(provider.badgeColor.opacity(0.16), in: RoundedRectangle(cornerRadius: size * 0.24))
            .accessibilityLabel(provider.displayName)
    }
}
