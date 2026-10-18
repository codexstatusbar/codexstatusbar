import AppKit
import CodexHubCore

/// What the menu bar draws: single-line items, and per provider a stack of the session window over the weekly one.
enum MenuBarItem: Equatable {
    case rate(SessionProvider?, String)
    case stack(SessionProvider, session: String?, weekly: String?)
}

/// Draws the menu bar content as one image so the remaining usage can sit on two lines, like a CPU/MEM readout.
enum MenuBarImage {
    private static let itemGap: CGFloat = 8, iconWidth: CGFloat = 13, iconGap: CGFloat = 3
    private static var rateFont: NSFont { NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular) }
    private static var stackFont: NSFont { NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium) }

    /// Colors resolve while drawing, so the image follows the menu bar's light or dark appearance.
    private static func attributes(_ font: NSFont) -> [NSAttributedString.Key: Any] { [.font: font, .foregroundColor: NSColor.labelColor] }

    private static func width(_ text: String, _ font: NSFont) -> CGFloat { text.size(withAttributes: attributes(font)).width }

    private static func itemWidth(_ item: MenuBarItem) -> CGFloat {
        switch item {
        case .rate(let provider, let text):
            return (provider == nil ? 0 : iconWidth + iconGap) + width(text, rateFont)
        case .stack(_, let session, let weekly):
            return iconWidth + iconGap + ([session, weekly].compactMap { $0 }.map { width($0, stackFont) }.max() ?? 0)
        }
    }

    static func render(_ items: [MenuBarItem], height: CGFloat) -> NSImage {
        let total = items.reduce(0) { $0 + itemWidth($1) } + itemGap * CGFloat(max(0, items.count - 1))
        return NSImage(size: NSSize(width: ceil(total), height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for item in items {
                switch item {
                case .rate(let provider, let text):
                    var textX = x
                    if let provider { drawIcon(provider, x: x, height: height); textX += iconWidth + iconGap }
                    drawLine(text, font: rateFont, x: textX, centerY: height / 2)
                case .stack(let provider, let session, let weekly):
                    drawIcon(provider, x: x, height: height)
                    let lines = [session, weekly].compactMap { $0 }
                    // Digits and capitals are about 0.72 em tall, so two lines one em apart fit the bar with room to spare.
                    let pitch = stackFont.pointSize
                    for (index, line) in lines.enumerated() {
                        let offset = (CGFloat(lines.count - 1) / 2 - CGFloat(index)) * pitch
                        drawLine(line, font: stackFont, x: x + iconWidth + iconGap, centerY: height / 2 + offset)
                    }
                }
                x += itemWidth(item) + itemGap
            }
            return true
        }
    }

    private static func drawLine(_ text: String, font: NSFont, x: CGFloat, centerY: CGFloat) {
        let size = text.size(withAttributes: attributes(font))
        text.draw(at: NSPoint(x: x, y: centerY - size.height / 2), withAttributes: attributes(font))
    }

    private static func drawIcon(_ provider: SessionProvider, x: CGFloat, height: CGFloat) {
        guard let icon = NSImage(systemSymbolName: provider == .codex ? "cloud.fill" : "asterisk", accessibilityDescription: provider.displayName)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [NSColor(provider.badgeColor)])) else { return }
        icon.draw(in: NSRect(x: x, y: (height - 12) / 2, width: iconWidth, height: 12))
    }
}
