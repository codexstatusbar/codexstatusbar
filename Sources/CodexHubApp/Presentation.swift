import Foundation
import Observation
import CodexHubCore
import CodexHubCollector

struct SessionPresentation: Identifiable {
    let monitor: ThreadMonitor
    var cwd: String?
    var model: String?
    var lastObserved: Date?
    var process: ProcessIdentity?
    var server: ProcessIdentity?
    var rootObserved = false
    var observedSource: UsageSource?
    var sourceMeasurement: CodexHubCore.Measurement?
    var sourceReconciliationPending = false
    var observationStopped = false
    var observedActivity: Activity?
    var hookCompletionCandidate = false
    var liveRate: Double?
    var liveMeasurement: CodexHubCore.Measurement = .unavailable
    var liveUnavailableReason: String?
    var usageDetails: SessionUsageDetails?
    var activity: Activity { observedActivity ?? monitor.activity }
    var measurement: CodexHubCore.Measurement { sourceMeasurement ?? monitor.measurement }
    var id: ThreadKey { monitor.key }
    var title: String { cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Session \(id.threadID.prefix(8))" }
    var source: String {
        switch observedSource ?? monitor.counter.source {
        case .rolloutLog: "Logs"
        case .directRelay: "Direct · experimental"
        case .sharedServer: "Shared server"
        }
    }
    var modelDescription: String {
        [model, usageDetails?.reasoningEffort].compactMap { $0 }.joined(separator: " · ")
    }
    var contextDescription: String {
        guard let details = usageDetails, let used = details.contextTokens, let window = details.contextWindow else { return "Unavailable" }
        return "\(used.formatted()) / \(window.formatted()) tokens"
    }
    var tokenDescription: String {
        guard let total = monitor.counter.baseline else { return "In — · Out —" }
        return "In \(total.inputTokens.formatted()) · Out \(total.outputTokens.formatted())"
    }
    var limitDescriptions: [String] {
        (usageDetails?.limits ?? []).map { limit in
            let window: String
            if let minutes = limit.windowMinutes {
                window = minutes % 1440 == 0 ? "\(minutes / 1440)d" : minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes)m"
            } else { window = limit.name.capitalized }
            let remaining = limit.remainingPercent.formatted(.number.precision(.fractionLength(0...1)))
            return "\(window) left \(remaining)%" + (limit.resetsAt.map { " · resets " + Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .shortened) } ?? "")
        }
    }
    var identity: String { process.map { "PID \($0.pid)" } ?? "Session only" }
    var status: String {
        switch monitor.connectivity {
        case .disconnected: return "Disconnected"
        case .degraded: return "Degraded"
        case .unknown: return "Unknown"
        case .connected: break
        }
        switch activity {
        case .idle: return "Idle"
        case .working: return "Working"
        case .generating: return "Generating"
        case .toolRunning: return "Tool running"
        case .approvalWait: return "Approval needed"
        case .unknown: return "Unknown"
        }
    }
    var priority: Int {
        if activity == .approvalWait || monitor.connectivity != .connected { return 0 }
        switch activity {
        case .working, .generating, .toolRunning: return 1
        case .idle: return 2
        case .unknown: return 3
        case .approvalWait: return 0
        }
    }
    func rate(at time: Double) -> String {
        guard measurement == .reported else { return "—" }
        return HubPresentation.rate(try? monitor.reportedRate(at: time))
    }
}

enum MeasurementMode: String, CaseIterable {
    case reported, live
    var label: String { self == .reported ? "Reported · 10s" : "Live · 5s" }
    var symbol: String { self == .reported ? "R" : "≈" }
}

enum HubPage: Hashable { case overview, detail(ThreadKey), preferences, connection }

@MainActor @Observable final class HubPresentation {
    var sessions: [SessionPresentation] = []
    var unattachedProcesses: [ProcessIdentity] = []
    var frame: ReportedFrame?
    var measurementMode: MeasurementMode = .reported
    var updateMeasurementMode: ((MeasurementMode) -> Void)?
    var hooksBusy = false
    var hooksResult = "Not checked. Hook trust and runtime compatibility are unverified."
    var hookAction: ((HelperConnection.HookAction) -> Void)?
    var page = HubPage.overview
    var hideIdle = false
    var compact = false
    var retentionDays = 7
    var startAtLogin = false
    var loginStatus = "Not registered"
    var diagnostics: [String] = []
    var error: String?
    var notice: String?
    var refreshedAt: Date?
    var canManageMetadata = false
    var confirmClear = false
    var busy = false
    var helperPath: String?
    var codexPath: String?
    var chooseCodex: (() -> Void)?
    var runDoctor: (() -> Void)?
    var doctorBusy = false
    var doctorResult = "Not checked. Managed relay is experimental; G0 is unverified."
    var managedCommand: String? {
        guard let helperPath, let codexPath else { return nil }
        return HelperConnection.command(home: codexHome, codex: codexPath, helper: helperPath)
    }
    var chooseHome: (() -> Void)?
    var codexHome = "Not selected"
    var refresh: (() -> Void)?
    var clearMetadata: (() -> Void)?
    var updateRetention: ((Int) -> Void)?
    var updateLogin: ((Bool) -> Void)?
    var saveDisplayPreferences: (() -> Void)?
    var close: (() -> Void)?
    var quit: (() -> Void)?

    nonisolated static func rate(_ value: Double?, symbol: String = "R") -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        return symbol + value.formatted(.number.precision(.fractionLength(0...1)))
    }
    var visibleSessions: [SessionPresentation] {
        sessions.filter { !hideIdle || $0.activity != .idle }.sorted {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            if $0.id.homeID != $1.id.homeID { return $0.id.homeID < $1.id.homeID }
            return $0.id.threadID < $1.id.threadID
        }
    }
    var summary: String {
        if error != nil { return "Unavailable" }
        guard !sessions.isEmpty else { return unattachedProcesses.isEmpty ? "No running Codex" : "Codex running" }
        if sessions.allSatisfy({ $0.monitor.connectivity == .disconnected }) { return "Disconnected" }
        if let speed = aggregateRate { return Self.rate(speed, symbol: measurementMode.symbol) }
        if sessions.contains(where: { $0.monitor.connectivity == .connected && $0.monitor.activeTurnID != nil }) { return "Working" }
        if sessions.contains(where: { $0.monitor.connectivity == .connected && $0.activity == .idle }) { return "Idle" }
        return "Unknown"
    }
    var menuTitle: String {
        let text = compact ? "Hub" : summary + ((aggregateRate != nil && error == nil) ? " tok/s · Partial" : "")
        return text + (sessions.contains { $0.monitor.connectivity == .connected && $0.activity == .approvalWait } ? " · !" : "")
    }
    func status(for session: SessionPresentation) -> String { error == nil ? session.status : "Unknown" }
    func rate(for session: SessionPresentation) -> String {
        guard error == nil else { return "—" }
        return measurementMode == .reported ? session.rate(at: frame?.time ?? 0) : Self.rate(session.liveMeasurement == .estimated ? session.liveRate : nil, symbol: "≈")
    }
    // Group coverage as reported frames do; only observed CLI root counters contribute.
    private struct RunKey: Hashable {
        let home: String
        let run: String?
        let unassignedThread: String?
        init(_ key: ThreadKey) {
            home = key.homeID; run = key.runID
            unassignedThread = key.runID == nil ? key.threadID : nil
        }
    }
    private var liveAggregate: (rate: Double?, measured: Int, eligible: Int, partial: Bool) {
        let groups = Dictionary(grouping: sessions.filter { $0.activity != .idle }, by: { RunKey($0.id) })
        var sum: Double?
        var measured = 0
        for rows in groups.values {
            var complete = true
            for row in rows {
                if row.rootObserved, !row.sourceReconciliationPending, !row.observationStopped,
                   row.monitor.connectivity == .connected, row.liveMeasurement == .estimated, let rate = row.liveRate, rate.isFinite, rate >= 0 {
                    sum = (sum ?? 0) + rate
                } else { complete = false }
            }
            if complete { measured += 1 }
        }
        return (sum?.isFinite == true ? sum : nil, measured, groups.count, measured != groups.count)
    }
    var aggregateRate: Double? { measurementMode == .reported ? frame?.tokensPerSecond : liveAggregate.rate }
    var coverage: String {
        guard error == nil, let frame else { return "Unavailable" }
        let live = liveAggregate
        let measured = measurementMode == .reported ? frame.measuredRuns : live.measured
        let eligible = measurementMode == .reported ? frame.eligibleRuns : live.eligible
        return "\(measured) measured roots / \(eligible) eligible runs · Partial"
    }
    var source: String { Set(sessions.map(\.source)).count > 1 ? "Mixed sources" : sessions.first?.source ?? "Logs" }
    var freshness: String {
        refreshedAt.map { "Checked " + $0.formatted(date: .omitted, time: .standard) } ?? "Not checked"
    }
}
