import AppKit
import SwiftUI
import Observation
import ServiceManagement

@MainActor final class NativeMenuController: NSObject {
    let model: HubPresentation
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let statusIcon = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "Codex Hub")

    init(model: HubPresentation) {
        self.model = model
        super.init()
        statusIcon?.isTemplate = true
        statusIcon?.size = NSSize(width: 16, height: 16)
        popover.behavior = .transient
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        model.close = { [weak self] in self?.popover.performClose(nil) }
        model.quit = { NSApplication.shared.terminate(nil) }
        observeTitle()
    }

    private func observeTitle() {
        withObservationTracking {
            item.button?.toolTip = model.language.resolved == .korean ? "Codex Hub — 출력 증가량 ÷ 도구 실행·대기를 뺀 보고 구간(추정). ≈: 최근 5초 화면 출력 추정." : "Codex Hub — Output delta / report interval excluding tools (estimate). ≈: visible output estimate over 5 seconds."
            item.button?.title = model.menuTitle
            item.button?.image = model.menuTitle.isEmpty ? statusIcon : nil
            item.button?.imagePosition = model.menuTitle.isEmpty ? .imageOnly : .noImage
            item.button?.setAccessibilityLabel("Codex Hub, " + (model.menuTitle.isEmpty ? model.text(model.summary) : model.menuTitle))
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeTitle() }
        }
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
        close.toolTip = model.text("Quitting Hub stops monitoring, not your Codex sessions.")
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
        let height = min(520, max(1, (screen?.visibleFrame.height ?? 700) - 24))
        let size = NSSize(width: 380, height: height)
        let host = NSHostingController(rootView: HubView(model: model, height: height))
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
