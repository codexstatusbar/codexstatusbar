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
    var parentThreadID: String?
    var observedSource: UsageSource?
    var sourceMeasurement: CodexHubCore.Measurement?
    var sourceReconciliationPending = false
    var observationStopped = false
    var observedActivity: Activity?
    var hookCompletionCandidate = false
    var usageDetails: SessionUsageDetails?
    var serverTiming: ServerTiming?
    var provider = SessionProvider.codex
    var activity: Activity { observedActivity ?? monitor.activity }
    var measurement: CodexHubCore.Measurement { sourceMeasurement ?? monitor.measurement }
    var id: ThreadKey { monitor.key }
    var title: String { cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Session \(id.threadID.prefix(8))" }
    var source: String {
        switch observedSource ?? monitor.counter.source {
        case .rolloutLog: provider == .claude ? "Claude logs" : "Logs"
        case .directRelay: "Direct · experimental"
        case .sharedServer: "Shared server"
        }
    }
    var modelDescription: String {
        [model, usageDetails?.reasoningEffort, usageDetails?.serviceTier?.displayName].compactMap { $0 }.joined(separator: " · ")
    }
    var contextDescription: String {
        guard let details = usageDetails, let used = details.contextTokens, let window = details.contextWindow, window > 0 else { return "미확인" }
        return (100 * Double(used) / Double(window)).formatted(.number.precision(.fractionLength(0...1))) + "%"
    }
    var tokenDescription: String {
        guard let total = monitor.counter.baseline else { return "In — · Out —" }
        return "In \(Self.tokens(total.inputTokens)) · Out \(Self.tokens(total.outputTokens))"
    }
    static func tokens(_ count: Int) -> String {
        for (scale, suffix) in [(1_000_000_000, "G"), (1_000_000, "M"), (1_000, "K")] where count >= scale {
            let rounded = (10 * Double(count) / Double(scale)).rounded() / 10
            return rounded.formatted(.number.precision(.fractionLength(0...1))) + suffix
        }
        return count.formatted()
    }
    func limitDescriptions(language: AppLanguage = .korean, now: Date = Date()) -> [String] {
        (usageDetails?.limits ?? []).map { limit in
            let remaining = limit.remainingPercent.formatted(.number.precision(.fractionLength(0...1)))
            let reset: String
            if let timestamp = limit.resetsAt {
                let seconds = timestamp - now.timeIntervalSince1970
                if seconds > 0 {
                    let hours = Int(seconds / 3600)
                    reset = "\(hours / 24)d \(hours % 24)h"
                } else {
                    reset = language.resolved == .korean ? "갱신 대기" : "Awaiting reset"
                }
            } else {
                reset = language.resolved == .korean ? "갱신 시간 미확인" : "Reset time unknown"
            }
            return "\(remaining)% " + (language.resolved == .korean ? "남음" : "left") + " · " + reset
        }
    }
    var identity: String { process.map { "PID \($0.pid)" } ?? "Session only" }
    var status: String {
        switch monitor.connectivity {
        case .disconnected: return "연결 끊김"
        case .degraded: return "수집 확인 필요"
        case .unknown: return "상태 미확인"
        case .connected: break
        }
        switch activity {
        case .idle: return "대기 중"
        case .working: return "작업 중"
        case .generating: return "응답 생성 중"
        case .toolRunning: return "도구 실행 중"
        case .approvalWait: return "승인 대기"
        case .unknown: return "상태 미확인"
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

}

enum RateUnit: String, CaseIterable {
    case second, minute
    var suffix: String { self == .second ? "t/s" : "t/m" }
    var multiplier: Double { self == .second ? 1 : 60 }
}

struct UsageHistoryPoint: Identifiable, Equatable {
    static let windowSeconds: Double = 1800
    static let binSeconds: Double = 60
    static let maximumPoints = 3600
    let time: Double
    let outputTokens: Int
    var id: Double { time }
}

enum HubPage: Hashable { case overview, detail(ThreadKey), preferences, connection }

@MainActor @Observable final class HubPresentation {
    var appName: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Tokloom" }
    var sessions: [SessionPresentation] = [] {
        didSet { sessionGroups = Self.groupSessions(sessions) }
    }
    private(set) var sessionGroups: [ThreadKey: [SessionPresentation]] = [:]
    var unattachedProcesses: [ProcessIdentity] = []
    var frame: ReportedFrame?
    var rateUnit = RateUnit.second
    var updateRateUnit: ((RateUnit) -> Void)?
    var configuredServiceTier: ServiceTier?
    var language = AppLanguage.system
    var saveLanguage: ((AppLanguage) -> Void)?
    func text(_ value: String) -> String { language.text(value) }
    var hooksBusy = false
    var hooksResult = "Not checked. Hook trust and runtime compatibility are unverified."
    var hookAction: ((HelperConnection.HookAction) -> Void)?
    var page = HubPage.overview
    var hideIdle = false
    var hideUnattached = false
    var retentionDays = 7
    var startAtLogin = false
    var loginStatus = "Not registered"
    var diagnostics: [String] = []
    var historyError: String?
    var error: String?
    var notice: String?
    var refreshedAt: Date?
    var canManageMetadata = false
    var confirmClear = false
    var busy = false
    var checkingConnection = false
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

    private struct UsageAnchor {
        let time: Double
        let output: Int
        let epoch: String
        let source: UsageSource
        let generation: Int
    }
    private var usageAnchors: [ThreadKey: UsageAnchor] = [:]
    let chartWallClockOffset = Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime
    private(set) var usageHistory: [ThreadKey: [UsageHistoryPoint]] = [:]

    var overviewUsageHistory: [UsageHistoryPoint] {
        guard error == nil else { return [] }
        return sessions.filter {
            $0.rootObserved && $0.monitor.connectivity == .connected &&
            !$0.monitor.counter.isPartial &&
            !$0.sourceReconciliationPending && !$0.observationStopped
        }.flatMap { usageHistory[$0.id] ?? [] }
    }

    func suspendUsageHistory() { usageAnchors.removeAll() }
    func restoreUsageHistory(_ history: [ThreadKey: [UsageHistoryPoint]]) {
        usageAnchors.removeAll()
        usageHistory = history
    }

    /// Places `tokens` on the one-second grid over the `generation` seconds that end at `time`, spread evenly
    /// so the span keeps its length even when there are fewer tokens than seconds. Returns the seconds covered.
    @discardableResult
    static func spread(_ tokens: Int, endingAt time: Double, seconds generation: Double?, into history: inout [UsageHistoryPoint]) -> Int {
        var seconds = 1
        if let generation, generation.isFinite, generation > 0 { seconds = Int(min(max(generation.rounded(), 1), 600)) }
        let points = max(1, min(seconds, tokens))
        let base = tokens / points, extra = tokens % points
        for index in 0..<points {
            // The last `extra` points carry one more token so the total is exact.
            let amount = base + (index >= points - extra ? 1 : 0)
            let slot = min(seconds - 1, Int((Double(index) + 0.5) * Double(seconds) / Double(points)))
            let at = time - Double(seconds - 1 - slot)
            if let existing = history.firstIndex(where: { $0.time == at }) {
                history[existing] = UsageHistoryPoint(time: at, outputTokens: history[existing].outputTokens + amount)
            } else {
                history.append(UsageHistoryPoint(time: at, outputTokens: amount))
            }
        }
        history.sort { $0.time < $1.time }
        return seconds
    }

    func recordUsageHistory(_ rows: [SessionPresentation], at time: Double) {
        guard time.isFinite, time >= 0 else { return }
        let keys = Set(rows.map(\.id))
        usageAnchors = usageAnchors.filter { keys.contains($0.key) }
        usageHistory = usageHistory.compactMapValues {
            let kept = $0.filter { $0.time > time - UsageHistoryPoint.windowSeconds && $0.time <= time }
            return kept.isEmpty ? nil : kept
        }
        for row in rows {
            usageHistory[row.id] = usageHistory[row.id, default: []].filter { $0.time > time - UsageHistoryPoint.windowSeconds }
            guard row.monitor.connectivity == .connected, row.measurement == .reported || row.measurement == .warmingUp,
                  let counter = row.monitor.counter.baseline else {
                usageAnchors.removeValue(forKey: row.id)
                continue
            }
            let source = row.observedSource ?? row.monitor.counter.source
            if let previous = usageAnchors[row.id], previous.epoch == row.monitor.counter.epoch,
               previous.source == source, time > previous.time, time - previous.time <= 5,
               counter.outputTokens > previous.output {
                let delta = counter.outputTokens - previous.output
                // Logs report whole responses at once; place each one back over the time it took to generate.
                let generations = row.monitor.generations
                let fresh = generations.filter { $0.id > previous.generation || previous.generation > (generations.last?.id ?? -1) }
                var history = usageHistory[row.id, default: []]
                if !fresh.isEmpty, fresh.reduce(0, { $0 + $1.tokens }) == delta {
                    var end = time
                    for generation in fresh.reversed() {
                        end -= Double(Self.spread(generation.tokens, endingAt: end, seconds: generation.seconds, into: &history))
                    }
                } else {
                    Self.spread(delta, endingAt: time, seconds: nil, into: &history)
                }
                usageHistory[row.id] = Array(history.suffix(UsageHistoryPoint.maximumPoints))
            }
            usageAnchors[row.id] = UsageAnchor(time: time, output: counter.outputTokens, epoch: row.monitor.counter.epoch, source: source, generation: row.monitor.generations.last?.id ?? -1)
        }
    }

    nonisolated static func rate(_ value: Double?, symbol: String = "") -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        return symbol + value.formatted(.number.precision(.fractionLength(0...1)))
    }
    func displayRate(_ value: Double?, symbol: String = "") -> String {
        Self.rate(value.map { $0 * rateUnit.multiplier }, symbol: symbol)
    }

    private static func groupSessions(_ rows: [SessionPresentation]) -> [ThreadKey: [SessionPresentation]] {
        let index = Dictionary(grouping: rows) { ThreadKey(homeID: $0.id.homeID, runID: nil, threadID: $0.id.threadID) }
        var parents: [ThreadKey: ThreadKey] = [:]
        for row in rows {
            guard let parent = row.parentThreadID,
                  let candidates = index[ThreadKey(homeID: row.id.homeID, runID: nil, threadID: parent)],
                  candidates.count == 1, let candidate = candidates.first, candidate.id != row.id else { continue }
            parents[row.id] = candidate.id
        }
        var groups: [ThreadKey: [SessionPresentation]] = [:]
        for row in rows {
            var root = row.id
            var visited: Set<ThreadKey> = []
            while let parent = parents[root] {
                guard visited.insert(root).inserted else { root = row.id; break }
                root = parent
            }
            groups[root, default: []].append(row)
        }
        return groups
    }

    func auxiliarySessions(for session: SessionPresentation) -> [SessionPresentation] {
        (sessionGroups[session.id] ?? []).filter { $0.id != session.id }.sorted { $0.id.threadID < $1.id.threadID }
    }
    func mainSession(for session: SessionPresentation) -> SessionPresentation? {
        guard let key = sessionGroups.first(where: { $0.key != session.id && $0.value.contains { $0.id == session.id } })?.key else { return nil }
        return sessions.first { $0.id == key }
    }
    func overviewState(for session: SessionPresentation) -> SessionPresentation {
        let members = sessionGroups[session.id] ?? [session]
        let active = members.filter { $0.monitor.connectivity == .connected && [.working, .generating, .toolRunning, .approvalWait].contains($0.activity) }
        return active.min { a, b in
            if a.priority != b.priority { return a.priority < b.priority }
            if (a.activity == .generating) != (b.activity == .generating) { return a.activity == .generating }
            return a.id.threadID < b.id.threadID
        } ?? members.first { $0.monitor.connectivity != .connected || $0.activity == .unknown } ?? session
    }
    var visibleSessions: [SessionPresentation] {
        sessions.filter { row in
            guard let members = sessionGroups[row.id] else { return false }
            return !hideIdle || members.contains { $0.activity != .idle }
        }.sorted {
            let a = overviewState(for: $0).priority, b = overviewState(for: $1).priority
            if a != b { return a < b }
            if $0.id.homeID != $1.id.homeID { return $0.id.homeID < $1.id.homeID }
            return $0.id.threadID < $1.id.threadID
        }
    }
    /// Processes that could not be matched to a session; the user may hide them.
    var visibleUnattached: [ProcessIdentity] { hideUnattached ? [] : unattachedProcesses }
    var processCount: Int { sessionGroups.count + visibleUnattached.count }
    var generatingProcessCount: Int { error == nil ? sessionGroups.values.filter { $0.contains { $0.monitor.connectivity == .connected && $0.activity == .generating } }.count : 0 }
    var activeProcessCount: Int { error == nil ? sessionGroups.values.filter { $0.contains { $0.monitor.connectivity == .connected && [.working, .generating, .toolRunning, .approvalWait].contains($0.activity) } }.count : 0 }
    var idleProcessCount: Int { error == nil ? sessionGroups.values.filter { $0.allSatisfy { $0.monitor.connectivity == .connected && $0.activity == .idle } }.count : 0 }
    var activitySummary: String {
        language.resolved == .korean ? "\(activeProcessCount)개 작업 중" : "\(activeProcessCount) working"
    }
    var processBreakdown: String {
        let unknown = processCount - activeProcessCount - idleProcessCount
        return language.resolved == .korean ? "\(activeProcessCount) 작업 · \(idleProcessCount) 대기 · \(unknown) 확인" : "\(activeProcessCount) active · \(idleProcessCount) idle · \(unknown) unknown"
    }

    var summary: String {
        if error != nil { return "측정 불가" }
        guard !sessions.isEmpty else { return visibleUnattached.isEmpty ? "실행 없음" : "정보 미확인" }
        if sessions.allSatisfy({ $0.monitor.connectivity == .disconnected }) { return "연결 끊김" }
        if let speed = aggregateRate { return displayRate(speed) }
        if sessions.contains(where: { $0.monitor.connectivity == .connected && $0.monitor.activeTurnID != nil }) { return "계산 준비 중" }
        if sessions.contains(where: { $0.monitor.connectivity == .connected && $0.activity == .idle }) { return "대기 중" }
        return "상태 미확인"
    }
    var menuTitle: String {
        guard aggregateRate != nil, error == nil, summary != "—" else { return "" }
        return summary + " " + rateUnit.suffix
    }
    func status(for session: SessionPresentation) -> String { text(error == nil ? session.status : "상태 미확인") }
    func rate(for session: SessionPresentation) -> String {
        guard error == nil else { return "—" }
        guard session.measurement == .reported || session.measurement == .warmingUp else { return "—" }
        return displayRate(try? session.monitor.workAverageRate(at: frame?.time ?? 0))
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
    var aggregateRate: Double? {
        return frame?.tokensPerSecond
    }
    /// Per-provider share of the combined rate; only shown when more than one provider is observed.
    var providerBreakdown: String? {
        guard error == nil, let time = frame?.time,
              Set(sessions.map(\.provider)).count > 1 else { return nil }
        let parts = SessionProvider.allCases.compactMap { provider -> String? in
            let rows = sessions.filter { $0.provider == provider }
            guard !rows.isEmpty else { return nil }
            let rates = rows.filter { $0.rootObserved && ($0.measurement == .reported || $0.measurement == .warmingUp) }
                .compactMap { try? $0.monitor.workAverageRate(at: time) }
            return provider.displayName + " " + displayRate(rates.isEmpty ? nil : rates.reduce(0, +))
        }
        return parts.joined(separator: " · ") + " " + rateUnit.suffix
    }
    var coverage: String {
        guard error == nil, let frame else { return "측정 불가" }
        let measured = frame.measuredRuns
        let eligible = frame.eligibleRuns
        return language.resolved == .korean ? "\(eligible)개 대상 중 \(measured)개 계산 가능" : "\(measured) of \(eligible) eligible runs measured"
    }
    var freshness: String {
        refreshedAt.map { text("확인 ") + $0.formatted(date: .omitted, time: .standard) } ?? text("미확인")
    }
}
