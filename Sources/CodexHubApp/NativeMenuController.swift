import AppKit
import SwiftUI
import Observation
import ServiceManagement

@MainActor final class NativeMenuController: NSObject {
    let model: HubPresentation
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()

    init(model: HubPresentation) {
        self.model = model
        super.init()
        popover.behavior = .transient
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        item.button?.toolTip = "Codex Hub — R: reported output per second over 10 seconds; ≈: visible-output estimate over 5 seconds."
        model.close = { [weak self] in self?.popover.performClose(nil) }
        model.quit = { NSApplication.shared.terminate(nil) }
        observeTitle()
    }

    private func observeTitle() {
        withObservationTracking {
            item.button?.title = model.menuTitle
            item.button?.setAccessibilityLabel("Codex Hub, \(model.menuTitle), \(model.coverage) measured coverage")
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeTitle() }
        }
    }

    @objc private func toggle() {
        if popover.isShown { popover.performClose(nil); return }
        guard let button = item.button else { return }
        let screen = button.window?.screen ?? NSScreen.main
        let height = min(620, max(1, (screen?.visibleFrame.height ?? 700) - 24))
        let size = NSSize(width: 400, height: height)
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
