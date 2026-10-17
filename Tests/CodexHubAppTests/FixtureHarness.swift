import AppKit
import Darwin
import SwiftUI
import CodexHubCore
import CodexHubCollector

@main struct FixtureHarness {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let output = CommandLine.arguments.dropFirst().first ?? "/tmp/codex-hub-ui"
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        try verifyRunningProcesses()
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
        model.sessions[0].usageDetails = try JSONDecoder().decode(SessionUsageDetails.self, from: Data("{\"reasoningEffort\":\"high\",\"contextTokens\":600,\"contextWindow\":1000,\"limits\":[{\"name\":\"primary\",\"usedPercent\":21,\"windowMinutes\":10080}]}".utf8))
        precondition(model.sessions[0].modelDescription == "Fixture model · high", "UI21 observed model and reasoning")
        precondition(model.sessions[0].contextDescription == "60% used", "UI22 context is last prompt usage, not cumulative usage")
        precondition(model.sessions[0].tokenDescription == "In 0 · Out 600", "UI23 input/output counters retain their own meaning")
        precondition(model.sessions[0].limitDescriptions == ["7d left 79%"], "UI24 actual rate window determines remaining usage label")
        precondition(SessionPresentation.tokens(999) == "999" && SessionPresentation.tokens(1_000) == "1K", "UI26 small token count boundary")
        precondition(SessionPresentation.tokens(115_911) == "115.9K" && SessionPresentation.tokens(39_568_473) == "39.6M", "UI27 K/M token formatting")
        precondition(SessionPresentation.tokens(1_250_000_000) == "1.3G", "UI28 G token formatting")
        precondition(HelperConnection.configuredServiceTier(in: "service_tier = \"fast\" # default") == .fast, "UI29 home default tier parsing")
        precondition(HelperConnection.configuredServiceTier(in: "[profiles.quick]\nservice_tier = \"ultrafast\"") == nil, "UI30 profile tier is not a global default")
        precondition(HelperConnection.configuredServiceTier(in: "service_tier = \"fast\"\nservice_tier = \"ultrafast\"") == nil, "UI31 conflicting defaults stay unconfirmed")
        precondition(HelperConnection.configuredServiceTier(in: "instructions = \"\"\"\nservice_tier = \"fast\"") == nil, "UI32 multiline content cannot masquerade as a default")
        precondition(HelperConnection.configuredServiceTier(in: "service_tier = \"future-tier\"") == nil, "UI33 unknown tier stays unconfirmed")
        precondition(ServiceTier.priority.displayName == "Fast" && ServiceTier.ultrafast.displayName == "Ultrafast", "UI34 speed tiers preserve the official mapping")
        model.configuredServiceTier = .fast

        try capture(model, "process-metadata", output, dark: false)
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
        precondition(model.visibleSessions.first?.id == active.key, "UI25 active session sorts ahead of idle and unknown")
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
        precondition(model.summary == "No running Codex", "UI10 empty discovery")
        try capture(model, "empty", output, dark: false)
        model.unattachedProcesses = [ProcessIdentity(pid: 1234, osStartTime: "fixture")]
        precondition(model.summary == "Codex running", "UI20 running process without a session is not historical data")
        try capture(model, "running-without-session", output, dark: false)
        model.unattachedProcesses = []
        print("PASS UI01–UI34 and P01–P06; fixture PNGs: \(output)")
    }
    @MainActor static func verifyRunningProcesses() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("codex")
        let source = root.appendingPathComponent("writer.c")
        try Data("#include <fcntl.h>\n#include <unistd.h>\nint main(int n, char **v) { if (n != 2 || open(v[1], O_WRONLY | O_APPEND) < 0) return 2; char c; return read(0, &c, 1) < 0; }\n".utf8).write(to: source)
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
        compiler.arguments = [source.path, "-o", executable.path]
        try compiler.run(); compiler.waitUntilExit()
        precondition(compiler.terminationStatus == 0, "Process fixture compiler")
        let log = root.appendingPathComponent("fixture.jsonl")
        try Data().write(to: log)
        let child = Process()
        let input = Pipe()
        child.executableURL = executable
        child.arguments = [log.path]
        child.standardInput = input
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        defer {
            input.fileHandleForWriting.closeFile()
            if child.isRunning { child.terminate() }
            child.waitUntilExit()
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: log.path)
        let fileID = "\(attributes[.systemNumber]!)" + ":" + "\(attributes[.systemFileNumber]!)"
        var observed: RunningCodexProcess?
        let deadline = Date().addingTimeInterval(3)
        repeat {
            observed = RunningCodexProcess.inspect(child.processIdentifier)
            if observed?.writableFileIDs.contains(fileID) == true { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        } while Date() < deadline
        precondition(observed?.writableFileIDs.contains(fileID) == true, "P01 live writer is mapped by exact file identity")
        let process = observed!
        precondition(RunningCodexProcess.owner(of: fileID, controller: nil, in: [process]) == process.identity, "P02 open transcript identifies its owner")
        precondition(RunningCodexProcess.owner(of: "missing", controller: nil, in: [process]) == nil, "P03 past transcript cannot match by name or cwd")
        let reused = ProcessIdentity(pid: process.identity.pid, osStartTime: "different-start")
        precondition(RunningCodexProcess.owner(of: "direct:fixture", controller: reused, in: [process]) == nil, "P04 reused PID cannot match managed identity")
        let conflicting = RunningCodexProcess(identity: ProcessIdentity(pid: 123, osStartTime: "fixture"), writableFileIDs: [fileID])
        precondition(RunningCodexProcess.owner(of: fileID, controller: nil, in: [process, conflicting]) == nil, "P05 ambiguous owners remain unattached")
        child.terminate(); child.waitUntilExit()
        precondition(RunningCodexProcess.inspect(child.processIdentifier) == nil, "P06 exited process disappears")
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
