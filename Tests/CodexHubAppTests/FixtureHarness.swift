import AppKit
import SwiftUI
import CodexHubCore

@main struct FixtureHarness {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let output = CommandLine.arguments.dropFirst().first ?? "/tmp/codex-hub-ui"
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        let model = HubPresentation()
        var a = ThreadMonitor(key: .init(homeID: "fixture-home", runID: nil, threadID: "fixture-a"), source: .rolloutLog, epoch: "fixture", verifiedEmptyThread: true)
        try a.setConnectivity(.connected, at: 0)
        try a.startTurn("fixture-turn", at: 1)
        try a.observeUsage(TokenUsage(outputTokens: 600, reasoningOutputTokens: 400), turnID: "fixture-turn", source: .rolloutLog, epoch: "fixture", at: 5)
        var b = ThreadMonitor(key: .init(homeID: "fixture-home", runID: nil, threadID: "fixture-b"), source: .rolloutLog, epoch: "fixture", verifiedEmptyThread: true)
        try b.setConnectivity(.connected, at: 0)
        try b.startTurn("fixture-turn", at: 1)
        try b.observeUsage(TokenUsage(outputTokens: 300), turnID: "fixture-turn", source: .rolloutLog, epoch: "fixture", at: 5)
        func set(_ monitors: [ThreadMonitor], verified: Set<ThreadKey>) throws {
            model.sessions = monitors.enumerated().map { i, m in SessionPresentation(monitor: m, cwd: "/Synthetic/" + (i == 0 ? "sample-project" : "second-project"), model: "Fixture model", lastObserved: Date(timeIntervalSince1970: 1_700_000_000), rootObserved: verified.contains(m.key)) }
            model.frame = try ReportedFrame(monitors: monitors, verifiedIndependentThreads: verified, at: 10)
            model.notice = "Synthetic UI fixture · not live telemetry"
        }
        try set([a,b], verified: [a.key,b.key])
        precondition(model.summary == "R90", "UI01 same-window sum")
        precondition(model.sessions[0].identity == "Session only", "UI02 no inferred PID")
        precondition(HubPresentation.rate(nil) == "—" && HubPresentation.rate(0) == "R0", "UI03 missing vs zero")
        precondition(model.sessions[0].monitor.counter.baseline?.nonReasoningOutputTokens == 200)
        try capture(model, "reported-light", output, dark: false)
        try capture(model, "reported-dark", output, dark: true)
        model.page = .detail(a.key)
        try capture(model, "detail", output, dark: false)
        model.sessions[0].cwd = "/Synthetic/" + String(repeating: "long-project-path/", count: 12)
        try capture(model, "detail-long-path", output, dark: false, height: 1100)
        try capture(model, "detail-small-screen", output, dark: false, height: 380)
        model.page = .preferences
        try capture(model, "preferences", output, dark: false)
        try capture(model, "preferences-full", output, dark: true, height: 900)
        model.page = .connection
        model.diagnostics = ["Fixture: logs directory readable", "No provider or Hook calls performed"]
        try capture(model, "connection", output, dark: false)
        try capture(model, "connection-full", output, dark: false, height: 900)
        model.page = .overview
        try set([a,b], verified: [a.key])
        precondition(model.coverage == "1 measured roots / 2 eligible runs · Partial" && model.summary == "R60", "UI04 scope exclusion")
        try capture(model, "partial", output, dark: false)
        model.measurementMode = .live
        model.sessions[0].liveRate = 12
        model.sessions[0].liveMeasurement = .estimated
        model.sessions[1].liveRate = 34
        model.sessions[1].liveMeasurement = .estimated
        precondition(model.summary == "≈12" && model.menuTitle.contains("Partial"), "UI12 Live excludes unknown roots and reported samples")
        try capture(model, "live-partial", output, dark: false)
        model.sessions[0].liveMeasurement = .warmingUp
        model.sessions[0].liveRate = nil
        precondition(model.aggregateRate == nil && model.rate(for: model.sessions[0]) == "—", "UI13 warming up is not numeric zero")
        model.sessions[0].liveMeasurement = .estimated
        model.sessions[0].liveRate = 12
        model.sessions[0].sourceReconciliationPending = true
        precondition(model.aggregateRate == nil, "UI14 source reconciliation suppresses Live subtotal")
        model.measurementMode = .reported
        precondition(model.summary == "R60", "UI15 selected Reported frame remains separate from Live")
        try a.finishTurn("fixture-turn", outcome: .completed, at: 6)
        try b.finishTurn("fixture-turn", outcome: .completed, at: 6)
        try set([a,b], verified: [a.key,b.key])
        precondition(model.summary == "Idle" && model.frame?.tokensPerSecond == nil, "UI05 idle clears speed")
        try capture(model, "idle", output, dark: true)
        var historical = ThreadMonitor(key: .init(homeID: "fixture-home", runID: nil, threadID: "fixture-history"), source: .rolloutLog, epoch: "historical")
        try historical.setConnectivity(.connected, at: 0)
        try set([a,historical], verified: [a.key])
        precondition(model.summary == "Idle", "UI16 observed idle is not hidden by historical unknown sessions")
        precondition(model.status(for: model.sessions[1]) == "Unknown", "UI17 unknown history is not relabeled idle")
        try capture(model, "idle-with-history", output, dark: true)
        var active = ThreadMonitor(key: .init(homeID: "fixture-home", runID: nil, threadID: "fixture-active"), source: .rolloutLog, epoch: "active")
        try active.setConnectivity(.connected, at: 0)
        try active.startTurn("active-turn", at: 1)
        try set([a,historical,active], verified: [a.key])
        precondition(model.summary == "Working", "UI18 active turn takes precedence over idle without numeric throughput")
        try active.setConnectivity(.disconnected, at: 2)
        try set([active,historical], verified: [])
        precondition(model.summary == "Unknown", "UI19 disconnected work and unknown history cannot assert idle")
        try set([a,b], verified: [a.key,b.key])
        model.hideIdle = true
        precondition(model.visibleSessions.isEmpty, "UI06 idle filtering")
        model.hideIdle = false
        try a.startTurn("new-turn", at: 7)
        try a.setApproval("approval", waiting: true, turnID: "new-turn", at: 8)
        try set([a,b], verified: [a.key,b.key])
        precondition(model.summary == "Working" && model.menuTitle.contains("!"), "UI07 approval without samples")
        try capture(model, "working-approval", output, dark: false)
        try a.setConnectivity(.disconnected, at: 9)
        try set([a], verified: [a.key])
        precondition(!model.menuTitle.contains("!"), "UI11 disconnected approval is stale")
        precondition(model.summary == "Disconnected", "UI08 disconnect not idle")
        try capture(model, "disconnected", output, dark: true)
        model.error = "Fixture read error"
        precondition(model.summary == "Unavailable", "UI09 errors invalidate menu speed")
        try capture(model, "error", output, dark: false)
        model.error = nil
        try set([], verified: [])
        precondition(model.summary == "No sessions", "UI10 empty discovery")
        try capture(model, "empty", output, dark: false)
        print("PASS UI01–UI19; fixture PNGs: \(output)")
    }
    @MainActor static func capture(_ model: HubPresentation, _ name: String, _ output: String, dark: Bool, height: CGFloat = 620) throws {
        let view = NSHostingView(rootView: HubView(model: model, height: height).environment(\.colorScheme, dark ? .dark : .light))
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 400,height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFront(nil)
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("No bitmap") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("No PNG") }
        try data.write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png"))
        window.orderOut(nil)
    }
}
