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
    var rootObserved = false
    /// Total of the subagents this session has run, listed or not (Claude only).
    var descendantUsage: TokenUsage?
    var parentThreadID: String?
    var sourceMeasurement: CodexHubCore.Measurement?
    var sourceReconciliationPending = false
    var observedActivity: Activity?
    var usageDetails: SessionUsageDetails?
    var provider = SessionProvider.codex
    var activity: Activity { observedActivity ?? monitor.activity }
    /// Rates and chart deltas exclude inherited snapshots; explicitly identified children contribute their new output.
    var contributes: Bool { rootObserved || parentThreadID != nil }
    var measurement: CodexHubCore.Measurement { sourceMeasurement ?? monitor.measurement }
    var id: ThreadKey { monitor.key }
    /// The id the provider itself uses. Rows of one Claude session continued from several folders share it, so `id` tells them apart.
    var providerThreadID: String { provider == .claude ? ClaudeCollector.claudeID(ofThread: id.threadID) : id.threadID }
    var title: String { cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Session \(id.threadID.prefix(8))" }
    var source: String { provider == .claude ? "Claude logs" : "Logs" }
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
    static let windowSeconds: Double = 3600
    static let binSeconds: Double = 60
    static let maximumPoints = 7200
    let time: Double
    let outputTokens: Int
    var id: Double { time }
}

enum HubPage: Hashable { case overview, detail(ThreadKey), preferences }

/// What the menu bar shows for speed; the per-provider rates split the combined one.
enum MenuSpeed: String, CaseIterable {
    case combined, providers, both, off
    var showsCombined: Bool { self == .combined || self == .both }
    var showsProviders: Bool { self == .providers || self == .both }
}

/// Which providers' remaining usage the menu bar lists.
enum MenuUsage: String, CaseIterable {
    case all, codex, claude, off
    func includes(_ provider: SessionProvider) -> Bool {
        self == .all || (self == .codex && provider == .codex) || (self == .claude && provider == .claude)
    }
}

/// Which usage windows of a provider the menu bar lists.
enum MenuWindows: String, CaseIterable {
    case both, session, weekly
    func includes(_ quota: ProviderQuota) -> Bool { self == .both || (self == .weekly) == quota.isWeekly }
}

@MainActor @Observable final class HubPresentation {
    var appName: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Tokloom" }
    var sessions: [SessionPresentation] = [] {
        didSet { sessionGroups = Self.groupSessions(sessions) }
    }
    private(set) var sessionGroups: [ThreadKey: [SessionPresentation]] = [:]
    var unattachedProcesses: [ProcessIdentity] = []
    var frame: ReportedFrame?
    /// Session and weekly windows of the providers that have a login; a provider without one is absent.
    var quotas: [ProviderQuota] = []
    /// Credits that cover the plan once its windows run out, per provider that has some.
    var credits: [ProviderCredits] = []
    var clock: () -> Date = { Date() }
    static let metadataClearedNotice = "Tokloom metadata cleared. Original Codex logs were preserved."
    var rateUnit = RateUnit.second
    var updateRateUnit: ((RateUnit) -> Void)?
    var configuredServiceTier: ServiceTier?
    var language = AppLanguage.system
    var saveLanguage: ((AppLanguage) -> Void)?
    func text(_ value: String) -> String { language.text(value) }
    var page = HubPage.overview
    /// How long a detail page waits for its session to come back before the overview replaces it.
    static let detailGraceSeconds: TimeInterval = 5
    private var detailMissingSince: Date?
    /// A session that ended while its detail page was open (or hidden) leaves a page with nothing to show; go back to the
    /// overview once it has been gone for a moment. The short wait keeps one refresh that misses the session from kicking the user out.
    func reconcileDetailPage() {
        guard case .detail(let key) = page, !sessions.contains(where: { $0.id == key }) else { detailMissingSince = nil; return }
        let since = detailMissingSince ?? clock()
        detailMissingSince = since
        if clock().timeIntervalSince(since) >= Self.detailGraceSeconds { page = .overview; detailMissingSince = nil }
    }
    /// What the menu bar title shows; the icon stays when nothing selected has a value.
    var menuSpeed = MenuSpeed.combined
    var menuUsage = MenuUsage.all
    var menuWindows = MenuWindows.both
    var menuShowsReset = false
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
    var codexHome = "Not selected"
    var claudeHome = "Not selected"
    var chooseHome: (() -> Void)?
    var refresh: (() -> Void)?
    var clearMetadata: (() -> Void)?
    var updateRetention: ((Int) -> Void)?
    var updateLogin: ((Bool) -> Void)?
    var saveDisplayPreferences: (() -> Void)?
    var open: (() -> Void)?
    var close: (() -> Void)?
    var popoverOpen: (() -> Bool)?
    var connectHome: ((URL) -> Void)?
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

    private var chartSessions: [SessionPresentation] {
        sessions.filter {
            $0.contributes && $0.monitor.connectivity == .connected &&
            !$0.monitor.counter.isPartial &&
            !$0.sourceReconciliationPending
        }
    }
    var overviewUsageHistory: [UsageHistoryPoint] {
        guard error == nil else { return [] }
        return chartSessions.flatMap { usageHistory[$0.id] ?? [] }
    }
    /// The same chart data limited to one provider's sessions.
    func overviewUsageHistory(for provider: SessionProvider) -> [UsageHistoryPoint] {
        guard error == nil else { return [] }
        return chartSessions.filter { $0.provider == provider }.flatMap { usageHistory[$0.id] ?? [] }
    }
    /// Providers that have a session or a usage window, in a fixed order.
    var visibleProviders: [SessionProvider] {
        SessionProvider.allCases.filter { provider in sessions.contains { $0.provider == provider } || quotas.contains { $0.provider == provider } }
    }

    func suspendUsageHistory() { usageAnchors.removeAll() }
    func restoreUsageHistory(_ history: [ThreadKey: [UsageHistoryPoint]]) {
        usageAnchors.removeAll()
        usageHistory = history
    }

    /// Places `tokens` on the one-second grid over the `generation` seconds that end at `time`, spread evenly
    /// so the span keeps its length even when there are fewer tokens than seconds. Returns the real duration, which
    /// callers use to position the next response; whole seconds only decide which chart bucket a point falls in.
    @discardableResult
    static func spread(_ tokens: Int, endingAt time: Double, seconds generation: Double?, into history: inout [UsageHistoryPoint]) -> Double {
        var seconds = 1
        var duration = 1.0
        if let generation, generation.isFinite, generation > 0 {
            duration = generation
            seconds = Int(min(max(duration.rounded(), 1), 86_400))
        }
        // A long response keeps its real span; only the number of chart points is limited.
        let points = max(1, min(seconds, tokens, 600))
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
        return duration
    }

    func recordUsageHistory(_ rows: [SessionPresentation], at time: Double) {
        guard time.isFinite, time >= 0 else { return }
        let keys = Set(rows.map(\.id))
        usageAnchors = usageAnchors.filter { keys.contains($0.key) }
        // Codex closes a finished child's rollout, which ends its row; what it wrote stays with the parent's charts.
        for row in sessions where !keys.contains(row.id) {
            guard let thread = row.parentThreadID, usageHistory[row.id] != nil else { continue }
            let parent = ThreadKey(homeID: row.id.homeID, runID: nil, threadID: thread)
            guard keys.contains(parent), let points = usageHistory.removeValue(forKey: row.id) else { continue }
            let merged = Dictionary((usageHistory[parent, default: []] + points).map { ($0.time, $0.outputTokens) }, uniquingKeysWith: +)
            usageHistory[parent] = Array(merged.map { UsageHistoryPoint(time: $0.key, outputTokens: $0.value) }.sorted { $0.time < $1.time }.suffix(UsageHistoryPoint.maximumPoints))
        }
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
            let source = row.monitor.counter.source
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
                        end -= Self.spread(generation.tokens, endingAt: end, seconds: generation.seconds, into: &history)
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

    /// How long an auxiliary session that has stopped working stays on the list.
    static let auxiliaryLingerSeconds: TimeInterval = 600
    /// Logs keep every helper a session ever started. One that is not working and was last seen long ago is leftover
    /// history, not information; a session whose last activity is unknown is kept, since it cannot be shown stale.
    private func isLeftover(_ session: SessionPresentation) -> Bool {
        guard let seen = session.lastObserved,
              ![.working, .generating, .toolRunning, .approvalWait].contains(session.activity) else { return false }
        return clock().timeIntervalSince(seen) > Self.auxiliaryLingerSeconds
    }
    func auxiliarySessions(for session: SessionPresentation) -> [SessionPresentation] {
        (sessionGroups[session.id] ?? []).filter { $0.id != session.id && !isLeftover($0) }.sorted { $0.id.threadID < $1.id.threadID }
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
    /// One menu bar item: a provider icon (nil for the combined speed), a mark (`T/S`, `S`, `W`) and its value.
    struct MenuPart: Equatable {
        enum Kind { case speed, session, weekly }
        let provider: SessionProvider?
        let kind: Kind
        let mark: String
        let value: String
        /// The unit trails a speed (`77.7 T/S`); a window mark leads its percentage (`S 90%`).
        var text: String { kind == .speed ? value + " " + mark : mark + " " + value }
    }
    var menuParts: [MenuPart] {
        let unit = rateUnit.suffix.uppercased()
        var parts: [MenuPart] = []
        if menuSpeed.showsCombined, aggregateRate != nil, error == nil, summary != "—" { parts.append(MenuPart(provider: nil, kind: .speed, mark: unit, value: summary)) }
        for provider in SessionProvider.allCases where menuSpeed.showsProviders {
            if let rate = providerRate(provider) { parts.append(MenuPart(provider: provider, kind: .speed, mark: unit, value: displayRate(rate))) }
        }
        let shown = quotas.filter { $0.scope == nil && menuUsage.includes($0.provider) }.filter(menuWindows.includes).sorted {
            $0.provider != $1.provider ? $0.provider == .codex : $0.windowMinutes < $1.windowMinutes
        }
        return parts + shown.map {
            MenuPart(provider: $0.provider, kind: $0.isWeekly ? .weekly : .session, mark: $0.isWeekly ? "W" : "S",
                     value: String(Int($0.remainingPercent.rounded())) + "%" + (menuShowsReset ? remainingTime($0).map { " " + $0 } ?? "" : ""))
        }
    }
    /// The same parts grouped for drawing: each provider's windows stack, session above weekly.
    var menuItems: [MenuBarItem] {
        var items: [MenuBarItem] = []
        for part in menuParts {
            switch part.kind {
            case .speed:
                items.append(.rate(part.provider, part.text))
            case .session, .weekly:
                guard let provider = part.provider else { continue }
                var session: String?, weekly: String?
                if case .stack(let last, let s, let w)? = items.last, last == provider { session = s; weekly = w; items.removeLast() }
                if part.kind == .session { session = part.text } else { weekly = part.text }
                items.append(.stack(provider, session: session, weekly: weekly))
            }
        }
        return items
    }
    /// Plain-text form of the menu bar, used for accessibility and tests; the bar itself draws icons.
    var menuTitle: String {
        menuParts.map { ($0.provider.map { $0 == .codex ? "CX " : "CL " } ?? "") + $0.text }.joined(separator: " · ")
    }
    /// "Codex 61%" (menu bar: "CX 61%", a session window "CX 5h 90%") is the share of that window still unused.
    func quotaText(_ quota: ProviderQuota, short: Bool = false) -> String {
        let name = short ? (quota.provider == .codex ? "CX" : "CL") : quota.provider.displayName
        return name + (quota.scope.map { " " + $0 } ?? "") + (quota.isWeekly ? "" : " " + windowLabel(quota)) + " " + String(Int(quota.remainingPercent.rounded())) + "%"
    }
    /// Time until the window resets, compact: "3d 4h", "2h 13m", "45m".
    func remainingTime(_ quota: ProviderQuota) -> String? {
        guard let reset = quota.resetsAt else { return nil }
        let minutes = Int(reset.timeIntervalSince(clock()) / 60)
        guard minutes > 0 else { return nil }
        if minutes >= 1440 { return "\(minutes / 1440)d \(minutes % 1440 / 60)h" }
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
    /// The credits value as shown: a plain number for Codex credits, money for Claude, or "unlimited".
    func creditsValue(_ credits: ProviderCredits) -> String {
        if credits.unlimited { return text("Unlimited") }
        let remaining = credits.remaining ?? 0
        let locale = Locale(identifier: language.resolved == .korean ? "ko_KR" : "en_US")
        switch credits.unit {
        case .credits: return remaining.formatted(.number.precision(.fractionLength(remaining < 100 ? 0...1 : 0...0)).locale(locale))
        case .currency(let code): return remaining.formatted(.currency(code: code).locale(locale))
        }
    }
    /// Session windows are named by their length, e.g. "5h".
    func windowLabel(_ quota: ProviderQuota) -> String {
        quota.windowMinutes % 60 == 0 ? "\(quota.windowMinutes / 60)h" : "\(quota.windowMinutes)m"
    }
    func status(for session: SessionPresentation) -> String { text(error == nil ? session.status : "상태 미확인") }
    /// Linked subagents contribute their own rates and newly observed output.
    func subagents(of session: SessionPresentation) -> [SessionPresentation] {
        auxiliarySessions(for: session)
    }
    /// Whether the session's totals stand for more than itself: it has listed subagents, or has run some that left the list.
    func hasSubagents(_ session: SessionPresentation) -> Bool {
        (session.provider == .claude && session.descendantUsage != nil) || !subagents(of: session).isEmpty
    }
    /// The session's own counter plus every subagent it has run (the total the session carries, not the listed rows again).
    func familyUsage(of session: SessionPresentation) -> TokenUsage? {
        let own = session.monitor.counter.baseline
        guard session.provider == .claude, let sub = session.descendantUsage else { return own }
        return try? TokenUsage(outputTokens: (own?.outputTokens ?? 0) + sub.outputTokens,
                               reasoningOutputTokens: (own?.reasoningOutputTokens == nil && sub.reasoningOutputTokens == nil) ? nil : (own?.reasoningOutputTokens ?? 0) + (sub.reasoningOutputTokens ?? 0),
                               inputTokens: (own?.inputTokens ?? 0) + sub.inputTokens, cachedInputTokens: (own?.cachedInputTokens ?? 0) + sub.cachedInputTokens,
                               cacheWriteInputTokens: (own?.cacheWriteInputTokens ?? 0) + sub.cacheWriteInputTokens)
    }
    /// Output history of the session together with its subagents, including those that have left the list.
    func familyHistory(for session: SessionPresentation) -> [UsageHistoryPoint] {
        (sessionGroups[session.id] ?? [session]).flatMap { usageHistory[$0.id] ?? [] }
    }
    /// One session on its own.
    func ownRateValue(for session: SessionPresentation) -> Double? {
        guard error == nil, session.measurement == .reported || session.measurement == .warmingUp else { return nil }
        return try? session.monitor.workAverageRate(at: frame?.time ?? 0)
    }
    func ownRate(for session: SessionPresentation) -> String { displayRate(ownRateValue(for: session)) }
    /// The session's speed: itself plus the subagents working for it.
    func rateValue(for session: SessionPresentation) -> Double? {
        let rates = ([session] + subagents(of: session)).compactMap(ownRateValue)
        return rates.isEmpty ? nil : rates.reduce(0, +)
    }
    func rate(for session: SessionPresentation) -> String { displayRate(rateValue(for: session)) }
    // Group coverage as reported frames do.
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
    /// Summed work-average rate of one provider's measured roots and children; nil when none is measured.
    func providerRate(_ provider: SessionProvider) -> Double? {
        guard error == nil, let time = frame?.time else { return nil }
        let rates = sessions.filter { $0.provider == provider && $0.contributes && ($0.measurement == .reported || $0.measurement == .warmingUp) }
            .compactMap { try? $0.monitor.workAverageRate(at: time) }
        return rates.isEmpty ? nil : rates.reduce(0, +)
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
