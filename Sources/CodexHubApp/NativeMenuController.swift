import AppKit
import SwiftUI
import Observation
import ServiceManagement

@MainActor final class NativeMenuController: NSObject {
    let model: HubPresentation
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let statusIcon = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "Tokloom")

    init(model: HubPresentation) {
        self.model = model
        super.init()
        statusIcon?.isTemplate = true
        statusIcon?.size = NSSize(width: 16, height: 16)
        popover.behavior = .transient
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        model.open = { [weak self] in self?.showPopover() }
        model.close = { [weak self] in self?.popover.performClose(nil) }
        model.popoverOpen = { [weak self] in self?.popover.isShown ?? false }
        model.quit = { NSApplication.shared.terminate(nil) }
        observeTitle()
    }

    private func observeTitle() {
        withObservationTracking {
            item.button?.toolTip = model.language.resolved == .korean ? "Tokloom — 출력 증가량 ÷ 응답 생성 구간(추정). S·W: 5시간 세션·주간 남은 사용량." : "Tokloom — Output delta / response generation interval (estimate). S·W: remaining 5-hour session and weekly usage."
            let items = model.menuItems
            if items.contains(where: { if case .stack = $0 { true } else { false } }) {
                // Remaining usage is stacked on two lines, which only an image can draw.
                item.button?.attributedTitle = NSAttributedString(string: "")
                item.button?.image = MenuBarImage.render(items, height: NSStatusBar.system.thickness)
                item.button?.imagePosition = .imageOnly
            } else {
                item.button?.attributedTitle = menuAttributedTitle()
                item.button?.image = model.menuTitle.isEmpty ? statusIcon : nil
                item.button?.imagePosition = model.menuTitle.isEmpty ? .imageOnly : .noImage
            }
            item.button?.setAccessibilityLabel("Tokloom, " + (model.menuTitle.isEmpty ? model.text(model.summary) : model.menuTitle))
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeTitle() }
        }
    }

    /// Provider icons take the place of text names so the bar stays short.
    private func menuAttributedTitle() -> NSAttributedString {
        let font = item.button?.font ?? NSFont.menuBarFont(ofSize: 0)
        let result = NSMutableAttributedString()
        for (index, part) in model.menuParts.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "  ", attributes: [.font: font])) }
            if let provider = part.provider, let icon = NSImage(systemSymbolName: provider == .codex ? "cloud.fill" : "asterisk", accessibilityDescription: provider.displayName)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [NSColor(provider.badgeColor)])) {
                let attachment = NSTextAttachment()
                attachment.image = icon
                attachment.bounds = CGRect(x: 0, y: -2, width: 13, height: 12)
                result.append(NSAttributedString(attachment: attachment))
                result.append(NSAttributedString(string: " ", attributes: [.font: font]))
            }
            result.append(NSAttributedString(string: part.text, attributes: [.font: font]))
        }
        return result
    }

    @objc private func toggle() {
        if let event = NSApp.currentEvent,
           event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showContextMenu()
            return
        }
        if popover.isShown { popover.performClose(nil); return }
        showPopover()
    }

    private func showContextMenu() {
        guard let button = item.button else { return }
        popover.performClose(nil)
        let menu = NSMenu()
        let open = NSMenuItem(title: model.text("Open"), action: #selector(openFromMenu), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let close = NSMenuItem(title: model.text("닫기"), action: #selector(quitFromMenu), keyEquivalent: "q")
        close.target = self
        close.toolTip = model.text("Quitting Tokloom stops monitoring, not your Codex sessions.")
        menu.addItem(close)
        menu.popUp(positioning: nil, at: NSPoint(x: button.bounds.minX, y: button.bounds.minY), in: button)
    }

    @objc private func openFromMenu() {
        DispatchQueue.main.async { [weak self] in self?.showPopover() }
    }

    @objc private func quitFromMenu() { model.quit?() }

    private func showPopover() {
        guard !popover.isShown, let button = item.button else { return }
        let screen = button.window?.screen ?? NSScreen.main
        let height = min(720, max(1, (screen?.visibleFrame.height ?? 700) - 24))
        let width = min(460, max(1, (screen?.visibleFrame.width ?? 800) - 24))
        let size = NSSize(width: width, height: height)
        let host = NSHostingController(rootView: HubView(model: model, width: width, height: height))
        // AppKit owns the viewport; scrolling and refreshed rows must not resize the popover.
        host.sizingOptions = []
        host.preferredContentSize = size
        host.view.setFrameSize(size)
        popover.contentViewController = host
        popover.contentSize = size
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func refreshLoginStatus() {
        let status = SMAppService.mainApp.status
        model.startAtLogin = status == .enabled || status == .requiresApproval
        switch status {
        case .enabled: model.loginStatus = "Enabled in System Settings"
        case .requiresApproval: model.loginStatus = "Approval required in System Settings → Login Items"
        case .notRegistered: model.loginStatus = "Not registered"
        case .notFound: model.loginStatus = "App registration unavailable; keep the app in a stable location."
        @unknown default: model.loginStatus = "Unknown registration status"
        }
    }

    // Called only by the user's preference toggle, never during startup or fixture tests.
    func setStartAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            model.notice = nil
            refreshLoginStatus()
        } catch {
            model.notice = "Login item change failed. Check System Settings → Login Items."
            refreshLoginStatus()
        }
    }
}
