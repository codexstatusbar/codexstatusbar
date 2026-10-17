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
    var serverTiming: ServerTiming?
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
    func limitDescriptions(language: AppLanguage = .korean) -> [String] {
        (usageDetails?.limits ?? []).map { limit in
            let window: String
            if let minutes = limit.windowMinutes {
                window = minutes % 1440 == 0 ? "\(minutes / 1440)" + (language.resolved == .korean ? "일" : "d") : minutes % 60 == 0 ? "\(minutes / 60)" + (language.resolved == .korean ? "시간" : "h") : "\(minutes)" + (language.resolved == .korean ? "분" : "m")
            } else { window = limit.name.capitalized }
            let remaining = limit.remainingPercent.formatted(.number.precision(.fractionLength(0...1)))
            return "\(window) \(remaining)% " + (language.resolved == .korean ? "남음" : "left") + (limit.resetsAt.map { (language.resolved == .korean ? " · 갱신 " : " · resets ") + Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .shortened) } ?? "")
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
    var suffix: String { self == .second ? "tok/s" : "tok/m" }
    var multiplier: Double { self == .second ? 1 : 60 }
}

enum MeasurementMode: String, CaseIterable {
    case server, reported, live
    var label: String {
        switch self {
        case .server: "서버 타이밍 진단"
        case .reported: "도구 제외 추정"
        case .live: "실시간 추정 · 5초"
        }
    }
    var symbol: String { self == .live ? "≈" : "" }
}

struct UsageHistoryPoint: Identifiable {
    let time: Double
    let outputTokens: Int
    var id: Double { time }
}

enum HubPage: Hashable { case overview, detail(ThreadKey), preferences, connection }

@MainActor @Observable final class HubPresentation {
    var sessions: [SessionPresentation] = []
    var unattachedProcesses: [ProcessIdentity] = []
    var frame: ReportedFrame?
    var rateUnit = RateUnit.second
    var updateRateUnit: ((RateUnit) -> Void)?
    var measurementMode: MeasurementMode = .reported
    var updateMeasurementMode: ((MeasurementMode) -> Void)?
    var configuredServiceTier: ServiceTier?
    var language = AppLanguage.system
    var saveLanguage: ((AppLanguage) -> Void)?
    func text(_ value: String) -> String { language.text(value) }
    var hooksBusy = false
    var hooksResult = "Not checked. Hook trust and runtime compatibility are unverified."
    var hookAction: ((HelperConnection.HookAction) -> Void)?
    var page = HubPage.overview
    var hideIdle = false
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
    }
    private var usageAnchors: [ThreadKey: UsageAnchor] = [:]
    private(set) var usageHistory: [ThreadKey: [UsageHistoryPoint]] = [:]

    func suspendUsageHistory() { usageAnchors.removeAll() }

    func recordUsageHistory(_ rows: [SessionPresentation], at time: Double) {
        guard time.isFinite, time >= 0 else { return }
        let keys = Set(rows.map(\.id))
        usageAnchors = usageAnchors.filter { keys.contains($0.key) }
        usageHistory = usageHistory.filter { keys.contains($0.key) }
        for row in rows {
            usageHistory[row.id] = usageHistory[row.id, default: []].filter { $0.time > time - 300 }
            guard row.monitor.connectivity == .connected, row.measurement == .reported || row.measurement == .warmingUp,
                  let counter = row.monitor.counter.baseline else {
                usageAnchors.removeValue(forKey: row.id)
                continue
            }
            let source = row.observedSource ?? row.monitor.counter.source
            if let previous = usageAnchors[row.id], previous.epoch == row.monitor.counter.epoch,
               previous.source == source, time > previous.time, time - previous.time <= 5,
               counter.outputTokens > previous.output {
                usageHistory[row.id, default: []].append(UsageHistoryPoint(time: time, outputTokens: counter.outputTokens - previous.output))
                usageHistory[row.id] = Array(usageHistory[row.id, default: []].suffix(600))
            }
            usageAnchors[row.id] = UsageAnchor(time: time, output: counter.outputTokens, epoch: row.monitor.counter.epoch, source: source)
        }
    }

    nonisolated static func rate(_ value: Double?, symbol: String = "") -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        return symbol + value.formatted(.number.precision(.fractionLength(0...1)))
    }
    func displayRate(_ value: Double?, symbol: String = "") -> String {
        Self.rate(value.map { $0 * rateUnit.multiplier }, symbol: symbol)
    }

    var visibleSessions: [SessionPresentation] {
        sessions.filter { !hideIdle || $0.activity != .idle }.sorted {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            if $0.id.homeID != $1.id.homeID { return $0.id.homeID < $1.id.homeID }
            return $0.id.threadID < $1.id.threadID
        }
    }
    var processCount: Int { sessions.count + unattachedProcesses.count }
    var generatingProcessCount: Int { sessions.filter { error == nil && $0.monitor.connectivity == .connected && $0.activity == .generating }.count }
    var activeProcessCount: Int { sessions.filter { error == nil && $0.monitor.connectivity == .connected && [.working, .generating, .toolRunning, .approvalWait].contains($0.activity) }.count }
    var idleProcessCount: Int { sessions.filter { error == nil && $0.monitor.connectivity == .connected && $0.activity == .idle }.count }
    var activitySummary: String {
        language.resolved == .korean ? "\(activeProcessCount)개 작업 중" : "\(activeProcessCount) working"
    }
    var processBreakdown: String {
        let unknown = processCount - activeProcessCount - idleProcessCount
        return language.resolved == .korean ? "\(activeProcessCount) 작업 · \(idleProcessCount) 대기 · \(unknown) 확인" : "\(activeProcessCount) active · \(idleProcessCount) idle · \(unknown) unknown"
    }

    var summary: String {
        if error != nil { return "측정 불가" }
        guard !sessions.isEmpty else { return unattachedProcesses.isEmpty ? "실행 없음" : "정보 미확인" }
        if sessions.allSatisfy({ $0.monitor.connectivity == .disconnected }) { return "연결 끊김" }
        if measurementMode == .server { return sessions.contains { $0.serverTiming != nil } ? "생성 시간 미검증" : "서버 측정 필요" }
        if let speed = aggregateRate { return displayRate(speed, symbol: measurementMode.symbol) }
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
        guard error == nil, measurementMode != .server else { return "—" }
        if measurementMode == .reported {
            guard session.measurement == .reported || session.measurement == .warmingUp else { return "—" }
            return displayRate(try? session.monitor.workAverageRate(at: frame?.time ?? 0))
        }
        return displayRate(session.liveMeasurement == .estimated ? session.liveRate : nil, symbol: "≈")
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
    var aggregateRate: Double? {
        // Codex 0.163.0 exposes raw TBT but no verified per-response decode-duration contract.
        // Do not invert or subtract metrics with unverified scopes, or reuse a log estimate here.
        guard measurementMode != .server else { return nil }
        return measurementMode == .reported ? frame?.tokensPerSecond : liveAggregate.rate
    }
    var coverage: String {
        if measurementMode == .server { return text("순수 생성 시간 확인 필요") }
        guard error == nil, let frame else { return "측정 불가" }
        let live = liveAggregate
        let measured = measurementMode == .reported ? frame.measuredRuns : live.measured
        let eligible = measurementMode == .reported ? frame.eligibleRuns : live.eligible
        return language.resolved == .korean ? "\(eligible)개 대상 중 \(measured)개 계산 가능" : "\(measured) of \(eligible) eligible runs measured"
    }
    var freshness: String {
        refreshedAt.map { text("확인 ") + $0.formatted(date: .omitted, time: .standard) } ?? text("미확인")
    }
}
