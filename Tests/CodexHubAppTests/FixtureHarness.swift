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
        model.language = .korean
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
        precondition(model.summary == "225", "UI01 same-frame work averages")
        precondition(model.sessions[0].identity == "Session only", "UI02 no inferred PID")
        precondition(HubPresentation.rate(nil) == "—" && HubPresentation.rate(0) == "0", "UI03 missing vs zero")
        precondition(model.sessions[0].monitor.counter.baseline?.nonReasoningOutputTokens == 200)
        try capture(model, "reported-light", output, dark: false)
        try capture(model, "reported-dark", output, dark: true)
        model.frame = try ReportedFrame(monitors: [a,b], verifiedIndependentThreads: [a.key,b.key], at: 20)
        precondition(model.summary == "225", "UI35 elapsed work average does not expire after ten seconds")
        precondition(model.menuTitle == "225 T/S", "UI36 menu shows only speed and unit")
        try capture(model, "work-average-waiting", output, dark: false)
        try set([a,b], verified: [a.key,b.key])
        model.sessions[0].usageDetails = try JSONDecoder().decode(SessionUsageDetails.self, from: Data("{\"reasoningEffort\":\"high\",\"contextTokens\":600,\"contextWindow\":1000,\"limits\":[{\"name\":\"primary\",\"usedPercent\":21,\"windowMinutes\":10080}]}".utf8))
        precondition(model.sessions[0].modelDescription == "Fixture model · high", "UI21 observed model and reasoning")
        precondition(model.sessions[0].contextDescription == "60%", "UI22 context is last prompt usage, not cumulative usage")
        precondition(model.sessions[0].tokenDescription == "In 0 · Out 600", "UI23 input/output counters retain their own meaning")
        precondition(model.sessions[0].limitDescriptions() == ["79% 남음 · 갱신 시간 미확인"], "UI24 usage percent remains distinct from remaining percent")
        precondition(SessionPresentation.tokens(999) == "999" && SessionPresentation.tokens(1_000) == "1K", "UI26 small token count boundary")
        precondition(SessionPresentation.tokens(115_911) == "115.9K" && SessionPresentation.tokens(39_568_473) == "39.6M", "UI27 K/M token formatting")
        precondition(SessionPresentation.tokens(1_250_000_000) == "1.3G", "UI28 G token formatting")
        precondition(CodexConfig.configuredServiceTier(in: "service_tier = \"fast\" # default") == .fast, "UI29 home default tier parsing")
        precondition(CodexConfig.configuredServiceTier(in: "[profiles.quick]\nservice_tier = \"ultrafast\"") == nil, "UI30 profile tier is not a global default")
        precondition(CodexConfig.configuredServiceTier(in: "service_tier = \"fast\"\nservice_tier = \"ultrafast\"") == nil, "UI31 conflicting defaults stay unconfirmed")
        precondition(CodexConfig.configuredServiceTier(in: "instructions = \"\"\"\nservice_tier = \"fast\"") == nil, "UI32 multiline content cannot masquerade as a default")
        precondition(CodexConfig.configuredServiceTier(in: "service_tier = \"future-tier\"") == nil, "UI33 unknown tier stays unconfirmed")
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
        model.diagnostics = ["Fixture: logs directory readable", "No provider calls performed"]
        model.error = CollectorError.metadataInUse.message
        try capture(model, "preferences-diagnostics", output, dark: false, height: 1300)
        model.error = nil
        model.diagnostics = []
        model.language = .korean
        model.page = .overview
        try set([a,b], verified: [a.key])
        precondition(model.coverage == "2개 대상 중 1개 계산 가능" && model.summary == "150", "UI04 scope exclusion")
        try capture(model, "partial", output, dark: false)
        precondition(model.summary == "150", "UI15 work averages are the only estimate")
        try a.finishTurn("fixture-turn", outcome: .completed, at: 6)
        try b.finishTurn("fixture-turn", outcome: .completed, at: 6)
        try set([a,b], verified: [a.key,b.key])
        precondition(model.summary == "225" && model.frame?.tokensPerSecond == 225, "UI05 idle preserves last reported averages")
        try capture(model, "idle", output, dark: true)
        var historical = ThreadMonitor(key: .init(homeID: "fixture-home", runID: nil, threadID: "fixture-history"), source: .rolloutLog, epoch: "historical")
        try historical.setConnectivity(.connected, at: 0)
        try set([a,historical], verified: [a.key])
        precondition(model.summary == "150", "UI16 observed idle is not hidden by historical unknown sessions")
        precondition(model.status(for: model.sessions[1]) == "상태 미확인", "UI17 unknown history is not relabeled idle")
        try capture(model, "idle-with-history", output, dark: true)
        var active = ThreadMonitor(key: .init(homeID: "fixture-home", runID: nil, threadID: "fixture-active"), source: .rolloutLog, epoch: "active")
        try active.setConnectivity(.connected, at: 0)
        try active.startTurn("active-turn", at: 1)
        try set([a,historical,active], verified: [a.key])
        precondition(model.summary == "150", "UI18 active turn takes precedence over idle without numeric throughput")
        precondition(model.visibleSessions.first?.id == active.key, "UI25 active session sorts ahead of idle and unknown")
        try active.setConnectivity(.disconnected, at: 2)
        try set([active,historical], verified: [])
        precondition(model.summary == "상태 미확인", "UI19 disconnected work and unknown history cannot assert idle")
        try set([a,b], verified: [a.key,b.key])
        model.hideIdle = true
        precondition(model.visibleSessions.isEmpty, "UI06 idle filtering")
        model.hideIdle = false
        try a.startTurn("new-turn", at: 7)
        try a.setApproval("approval", waiting: true, turnID: "new-turn", at: 8)
        try set([a,b], verified: [a.key,b.key])
        precondition(model.summary == "225" && model.menuTitle == "225 T/S", "UI07 approval without samples")
        try capture(model, "working-approval", output, dark: false)
        try a.setConnectivity(.disconnected, at: 9)
        try set([a], verified: [a.key])
        precondition(!model.menuTitle.contains("!"), "UI11 disconnected approval is stale")
        precondition(model.summary == "연결 끊김", "UI08 disconnect not idle")
        try capture(model, "disconnected", output, dark: true)
        model.error = "Fixture read error"
        precondition(model.summary == "측정 불가", "UI09 errors invalidate menu speed")
        try capture(model, "error", output, dark: false)
        model.error = nil
        try set([], verified: [])
        precondition(model.summary == "실행 없음", "UI10 empty discovery")
        try capture(model, "empty", output, dark: false)
        model.unattachedProcesses = [ProcessIdentity(pid: 1234, osStartTime: "fixture")]
        precondition(model.summary == "정보 미확인", "UI20 running process without a session is not historical data")
        try capture(model, "running-without-session", output, dark: false)
        model.unattachedProcesses = []
        let suite = "CodexHub.LanguageFixture." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        precondition(AppLanguage.load(from: preferences) == .system, "UI37 language defaults to system")
        AppLanguage.english.save(to: preferences)
        precondition(AppLanguage.load(from: preferences) == .english, "UI38 language persists")
        preferences.set("unsupported", forKey: "appLanguage")
        precondition(AppLanguage.load(from: preferences) == .system, "UI39 invalid preference falls back")
        model.language = .english
        precondition(model.text("설정") == "Settings" && model.menuTitle.isEmpty, "UI40 live English UI and menu")
        precondition(model.text("/private/설정") == "/private/설정", "UI41 external text is preserved")
        model.page = .preferences
        try capture(model, "preferences-english", output, dark: false)
        try capture(model, "readme-settings-en", output, dark: true, height: 900)
        let readme_settings_en_language = model.language
        model.language = .korean
        try capture(model, "readme-settings-ko", output, dark: true, height: 900)
        model.language = readme_settings_en_language
        model.page = .overview
        try capture(model, "overview-english", output, dark: false)
        model.language = .korean
        precondition(model.text("Settings") == "설정" && model.menuTitle.isEmpty, "UI42 switch back immediately")
        model.page = .preferences
        try capture(model, "preferences-korean", output, dark: false)
        try set([a,b], verified: [a.key,b.key])
        precondition(model.aggregateRate != nil, "UI43 the single estimate keeps working")
        model.page = .overview
        try capture(model, "server-unavailable", output, dark: false)
        model.page = .detail(model.sessions[0].id)
        try capture(model, "server-real-schema-details", output, dark: false)
        var previewWorking = ThreadMonitor(key: .init(homeID: "fixture", runID: nil, threadID: "working"), source: .rolloutLog, epoch: "fixture", verifiedEmptyThread: true)
        try previewWorking.setConnectivity(.connected, at: 0)
        try previewWorking.startTurn("turn", at: 1)
        var previewIdle = ThreadMonitor(key: .init(homeID: "fixture", runID: nil, threadID: "idle"), source: .rolloutLog, epoch: "fixture", verifiedEmptyThread: true)
        try previewIdle.setConnectivity(.connected, at: 0)
        try previewIdle.startTurn("turn", at: 1)
        try previewIdle.finishTurn("turn", outcome: .completed, at: 2)
        model.sessions = [SessionPresentation(monitor: previewWorking, cwd: "/Synthetic/codexstatusbar", model: "GPT-6 Astra · Medium"), SessionPresentation(monitor: previewIdle, cwd: "/Synthetic/ocrfolio", model: "GPT-6 Astra · Medium")]
        model.unattachedProcesses = [ProcessIdentity(pid: 12345, osStartTime: "fixture")]
        model.frame = try ReportedFrame(monitors: [previewWorking, previewIdle], verifiedIndependentThreads: [], at: 3)
        model.page = .overview
        model.notice = "Synthetic design preview"
        precondition(model.processCount == 3 && model.activeProcessCount == 1 && model.idleProcessCount == 1, "UI47 process counts come from observed states")
        precondition(model.processBreakdown == "1 작업 · 1 대기 · 1 확인", "UI48 unresolved processes remain separate")
        try capture(model, "compact-reference-dark", output, dark: true)
        try capture(model, "compact-reference-light", output, dark: false)
        model.error = "Synthetic collection failure"
        precondition(model.activeProcessCount == 0 && model.idleProcessCount == 0 && model.processBreakdown == "0 작업 · 0 대기 · 3 확인", "UI49 collection errors do not claim current activity")
        try capture(model, "compact-collection-error", output, dark: true)
        model.error = nil
        let historyModel = HubPresentation()
        var historyMonitor = ThreadMonitor(key: .init(homeID: "fixture", runID: nil, threadID: "history"), source: .rolloutLog, epoch: "history", verifiedEmptyThread: true)
        try historyMonitor.setConnectivity(.connected, at: 0)
        try historyMonitor.startTurn("turn", at: 0)
        try historyMonitor.observeUsage(TokenUsage(outputTokens: 100), turnID: "turn", source: .rolloutLog, epoch: "history", at: 1)
        historyModel.recordUsageHistory([SessionPresentation(monitor: historyMonitor)], at: 1)
        precondition(historyModel.usageHistory[historyMonitor.key]?.isEmpty == true, "UI50 initial totals never become chart samples")
        try historyMonitor.observeUsage(TokenUsage(outputTokens: 130), turnID: "turn", source: .rolloutLog, epoch: "history", at: 2)
        historyModel.recordUsageHistory([SessionPresentation(monitor: historyMonitor)], at: 2)
        historyModel.recordUsageHistory([SessionPresentation(monitor: historyMonitor)], at: 3)
        precondition(historyModel.usageHistory[historyMonitor.key]?.map(\.outputTokens) == [30], "UI51 chart records only fresh output deltas")
        historyModel.suspendUsageHistory()
        try historyMonitor.observeUsage(TokenUsage(outputTokens: 1000), turnID: "turn", source: .rolloutLog, epoch: "history", at: 4)
        historyModel.recordUsageHistory([SessionPresentation(monitor: historyMonitor)], at: 4)
        precondition(historyModel.usageHistory[historyMonitor.key]?.count == 1, "UI52 collection gaps cannot produce catch-up bars")
        historyModel.recordUsageHistory([SessionPresentation(monitor: historyMonitor)], at: 305)
        precondition(historyModel.usageHistory[historyMonitor.key]?.count == 1, "UI64 chart samples survive beyond five minutes")
        historyModel.recordUsageHistory([SessionPresentation(monitor: historyMonitor)], at: 1805)
        precondition(historyModel.usageHistory[historyMonitor.key]?.count == 1, "UI53 chart history is kept for the sixty minutes the combined chart shows")
        historyModel.recordUsageHistory([SessionPresentation(monitor: historyMonitor)], at: 3605)
        precondition(historyModel.usageHistory[historyMonitor.key]?.isEmpty == true, "UI105 chart history expires after sixty minutes")
        historyModel.recordUsageHistory([], at: 3606)
        precondition(historyModel.usageHistory.isEmpty, "UI54 exited processes do not retain charts")
        precondition(historyModel.menuTitle.isEmpty, "UI55 unavailable speed uses an icon rather than status text")
        var newTurn = ThreadMonitor(key: historyMonitor.key, source: .rolloutLog, epoch: "new", verifiedEmptyThread: true)
        try newTurn.setConnectivity(.connected, at: 0)
        try newTurn.startTurn("fresh", at: 0)
        historyModel.recordUsageHistory([SessionPresentation(monitor: newTurn)], at: 1)
        try newTurn.observeUsage(TokenUsage(outputTokens: 50), turnID: "fresh", source: .rolloutLog, epoch: "new", at: 2)
        historyModel.recordUsageHistory([SessionPresentation(monitor: newTurn)], at: 2)
        precondition(historyModel.usageHistory[newTurn.key]?.map(\.outputTokens) == [50], "UI56 known warmup baseline retains the first fresh output")
        var spreadHistory: [UsageHistoryPoint] = []
        HubPresentation.spread(10, endingAt: 100, seconds: 4, into: &spreadHistory)
        precondition(spreadHistory.map(\.time) == [97, 98, 99, 100] && spreadHistory.map(\.outputTokens) == [2, 2, 3, 3], "UI56 a response is spread over its generation seconds without changing the total")
        var sparseHistory: [UsageHistoryPoint] = []
        HubPresentation.spread(3, endingAt: 100, seconds: 10, into: &sparseHistory)
        precondition(sparseHistory.map(\.time) == [92, 96, 99] && sparseHistory.map(\.outputTokens) == [1, 1, 1], "UI56 few tokens keep the full generation span instead of shrinking it")
        let burstKey = ThreadKey(homeID: "/burst", runID: nil, threadID: "burst")
        var burst = ThreadMonitor(key: burstKey, source: .rolloutLog, epoch: "e", verifiedEmptyThread: true)
        try burst.setConnectivity(.connected, at: 0)
        try burst.startTurn("t", at: 0)
        let burstModel = HubPresentation()
        burstModel.recordUsageHistory([SessionPresentation(monitor: burst)], at: 100)
        try burst.observeUsage(TokenUsage(outputTokens: 1000), turnID: "t", source: .rolloutLog, epoch: "e", at: 101, rateInterval: .excludingTools(10))
        try burst.observeUsage(TokenUsage(outputTokens: 1100), turnID: "t", source: .rolloutLog, epoch: "e", at: 101, rateInterval: .excludingTools(1))
        burstModel.recordUsageHistory([SessionPresentation(monitor: burst)], at: 101)
        let burstPoints = burstModel.usageHistory[burstKey] ?? []
        precondition(burstPoints.map(\.outputTokens).reduce(0, +) == 1100 && burstPoints.map(\.outputTokens).max() == 100 && burstPoints.count == 11, "UI56 several responses in one refresh are each placed over their own generation time")
        let quickKey = ThreadKey(homeID: "/quick", runID: nil, threadID: "quick")
        var quick = ThreadMonitor(key: quickKey, source: .rolloutLog, epoch: "e", verifiedEmptyThread: true)
        try quick.setConnectivity(.connected, at: 0)
        try quick.startTurn("t", at: 0)
        let quickModel = HubPresentation()
        quickModel.recordUsageHistory([SessionPresentation(monitor: quick)], at: 100)
        for total in [10, 20, 30] {
            try quick.observeUsage(TokenUsage(outputTokens: total), turnID: "t", source: .rolloutLog, epoch: "e", at: 101, rateInterval: .excludingTools(0.2))
        }
        quickModel.recordUsageHistory([SessionPresentation(monitor: quick)], at: 101)
        let quickTimes = (quickModel.usageHistory[quickKey] ?? []).map(\.time)
        precondition(quickTimes.count == 3 && quickTimes.min()! > 100.5, "UI56 short responses keep their real duration instead of being widened to whole seconds")
        var longHistory: [UsageHistoryPoint] = []
        let longDuration = HubPresentation.spread(1200, endingAt: 2000, seconds: 1200, into: &longHistory)
        precondition(longDuration == 1200 && longHistory.map(\.outputTokens).reduce(0, +) == 1200 && longHistory.first!.time < 810 && longHistory.count <= 600, "UI56 a response longer than ten minutes keeps its real duration; only the number of chart points is limited")
        historyModel.sessions = [SessionPresentation(monitor: newTurn)]
        historyModel.frame = try ReportedFrame(monitors: [newTurn], verifiedIndependentThreads: [newTurn.key], at: 2)
        historyModel.rateUnit = .minute
        precondition(historyModel.menuTitle == HubPresentation.rate(1500) + " T/M" && historyModel.rate(for: historyModel.sessions[0]) == HubPresentation.rate(1500), "UI57 minute conversion is consistent across menu and rows")
        precondition(historyModel.displayRate(nil) == "—" && historyModel.displayRate(0) == "0", "UI58 unit conversion preserves missing versus zero")
        historyModel.rateUnit = .second
        precondition(historyModel.menuTitle == "25 T/S", "UI59 second unit restores the same underlying rate")
        var chartTotal = 50
        for tick in 3...302 {
            chartTotal += [12, 24, 8, 40, 18, 4][tick % 6]
            try newTurn.observeUsage(TokenUsage(outputTokens: chartTotal, inputTokens: 10000 + tick * 100, cachedInputTokens: 5000 + tick * 40), turnID: "fresh", source: .rolloutLog, epoch: "new", at: Double(tick))
            historyModel.recordUsageHistory([SessionPresentation(monitor: newTurn)], at: Double(tick))
        }
        try newTurn.setGenerating(true, turnID: "fresh", at: 303)
        var chartSession = SessionPresentation(monitor: newTurn, cwd: "/Synthetic/graphics-preview", model: "gpt-6-astra", lastObserved: Date(timeIntervalSince1970: 1_700_000_000))
        chartSession.usageDetails = try JSONDecoder().decode(SessionUsageDetails.self, from: Data("{\"reasoningEffort\":\"medium\",\"contextTokens\":579,\"contextWindow\":1000}".utf8))
        historyModel.sessions = [chartSession]
        historyModel.frame = try ReportedFrame(monitors: [newTurn], verifiedIndependentThreads: [newTurn.key], at: 303)
        historyModel.language = .korean
        historyModel.page = .detail(chartSession.id)
        historyModel.notice = "Synthetic usage history · not live telemetry"
        precondition(historyModel.generatingProcessCount == 1 && chartSession.contextDescription == "57.9%", "UI60 generation status and context ring use observed values")
        try capture(historyModel, "graphics-detail-dark", output, dark: true, height: 900)
        historyModel.language = .english
        try capture(historyModel, "readme-details-en", output, dark: true, height: 900)
        let readme_details_en_language = historyModel.language
        historyModel.language = .korean
        try capture(historyModel, "readme-details-ko", output, dark: true, height: 900)
        historyModel.language = readme_details_en_language
        historyModel.rateUnit = .minute
        historyModel.language = .english
        try capture(historyModel, "graphics-detail-light-minute", output, dark: false, height: 900)
        try capture(historyModel, "graphics-detail-small", output, dark: true, height: 380, width: 380)
        historyModel.sessions[0].rootObserved = false
        precondition(historyModel.overviewUsageHistory.isEmpty, "UI61 unverified scopes never enter the main chart")
        historyModel.sessions[0].rootObserved = true
        precondition(historyModel.overviewUsageHistory.count == historyModel.usageHistory[newTurn.key]?.count, "UI62 main chart reuses verified observed samples")
        historyModel.language = .korean
        historyModel.page = .overview
        try capture(historyModel, "wide-overview-chart", output, dark: true)
        var claudeMonitor = ThreadMonitor(key: ThreadKey(homeID: "claude:/Synthetic", runID: nil, threadID: "claude-preview"), source: .rolloutLog, epoch: "claude")
        try claudeMonitor.setConnectivity(.connected, at: 0)
        try claudeMonitor.observeUsage(TokenUsage(outputTokens: 0), turnID: "history", source: .rolloutLog, epoch: "claude", at: 0, historical: true)
        try claudeMonitor.startTurn("claude-turn", at: 0)
        try claudeMonitor.observeUsage(TokenUsage(outputTokens: 600, inputTokens: 40000, cachedInputTokens: 32000), turnID: "claude-turn", source: .rolloutLog, epoch: "claude", at: 303, rateInterval: .excludingTools(10))
        try claudeMonitor.setGenerating(true, turnID: "claude-turn", at: 303)
        var claudeRow = SessionPresentation(monitor: claudeMonitor, cwd: "/Synthetic/claude-preview", model: "claude-opus-5-5")
        claudeRow.provider = .claude
        claudeRow.rootObserved = true
        claudeRow.process = ProcessIdentity(pid: 4242, osStartTime: "fixture")
        claudeRow.usageDetails = try JSONDecoder().decode(SessionUsageDetails.self, from: Data("{\"reasoningEffort\":\"medium\"}".utf8))
        let claudePoints = stride(from: 3, to: 302, by: 7).enumerated().map { UsageHistoryPoint(time: Double($1), outputTokens: [20, 35, 10, 50, 28][$0 % 5]) }
        let readme = HubPresentation()
        readme.notice = historyModel.notice
        readme.restoreUsageHistory(historyModel.usageHistory.merging([claudeMonitor.key: claudePoints]) { current, _ in current })
        readme.sessions = [historyModel.sessions[0], claudeRow]
        readme.frame = try ReportedFrame(monitors: readme.sessions.map(\.monitor), verifiedIndependentThreads: Set(readme.sessions.map(\.id)), at: 303)
        precondition(readme.providerRate(.codex) != nil && readme.displayRate(readme.providerRate(.claude)) == "60" && readme.visibleProviders == [.codex, .claude], "UI96 each provider reports its own speed when both run")
        readme.clock = { Date(timeIntervalSince1970: 1_792_900_000) }
        readme.quotas = [ProviderQuota(provider: .codex, usedPercent: 39, resetsAt: Date(timeIntervalSince1970: 1_792_900_000 + 3 * 86_400 + 4 * 3_600 + 30)),
                         ProviderQuota(provider: .claude, windowMinutes: 300, usedPercent: 10, resetsAt: Date(timeIntervalSince1970: 1_792_900_000 + 2 * 3_600 + 13 * 60 + 30)),
                         ProviderQuota(provider: .claude, usedPercent: 72.4, resetsAt: nil)]
        precondition(readme.menuTitle.hasSuffix("CX W 61% · CL S 90% · CL W 28%"), "UI102 the menu bar hides the time until reset by default")
        readme.menuShowsReset = true
        precondition(readme.menuTitle.hasSuffix("CX W 61% 3d 4h · CL S 90% 2h 13m · CL W 28%") && readme.quotaText(readme.quotas[1]) == "Claude 5h 90%", "UI97 menu lists every window with its remaining time; weekly without a reset shows none")
        readme.menuSpeed = .off
        readme.menuUsage = .claude
        precondition(readme.menuTitle == "CL S 90% 2h 13m · CL W 28%", "UI99 menu bar shows only the selected providers, shortest window first")
        readme.menuWindows = .session
        precondition(readme.menuTitle == "CL S 90% 2h 13m", "UI100 session-only mode hides weekly")
        readme.menuWindows = .weekly
        precondition(readme.menuTitle == "CL W 28%", "UI101 weekly-only mode hides the session")
        readme.menuWindows = .both
        readme.menuSpeed = .both
        readme.menuUsage = .off
        precondition(readme.menuTitle == "77.7 T/S · CX 17.7 T/S · CL 60 T/S", "UI103 the menu bar keeps the combined speed and adds each provider's own")
        readme.menuSpeed = .combined
        readme.menuUsage = .all
        readme.menuShowsReset = false
        precondition(CodexConfig.defaultHome(saved: nil, userHome: URL(fileURLWithPath: "/Users/fixture")) == "/Users/fixture/.codex" &&
                     CodexConfig.defaultHome(saved: "/chosen/home", userHome: URL(fileURLWithPath: "/Users/fixture")) == "/chosen/home", "UI106 the global ~/.codex is the default and a saved choice wins")
        let fixtureUser = URL(fileURLWithPath: "/Users/fixture")
        func home(_ running: [String?]) -> String { CodexConfig.defaultHome(saved: nil, running: running, userHome: fixtureUser) }
        precondition(home([]) == "/Users/fixture/.codex" && home([nil, nil, "/orca/a"]) == "/Users/fixture/.codex" &&
                     home(["/orca/a", "/orca/a", nil]) == "/orca/a" && home(["/orca/a", nil]) == "/Users/fixture/.codex" &&
                     CodexConfig.defaultHome(saved: "/chosen", running: ["/orca/a"], userHome: fixtureUser) == "/chosen",
                     "UI107 the home most running Codex processes use is detected; a saved choice wins")
        var procArgs: [UInt8] = [2, 0, 0, 0]
        procArgs += Array("/bin/codex".utf8) + [0, 0] + Array("codex".utf8) + [0] + Array("-c".utf8) + [0]
        procArgs += Array("CODEX_HOME=/x y".utf8) + [0] + Array("PATH=/bin".utf8) + [0, 0]
        let parsed = RunningCodexProcess.parseProcArgs(procArgs)
        precondition(parsed?.arguments == ["codex", "-c"] && parsed?.environment["CODEX_HOME"] == "/x y" && parsed?.environment["PATH"] == "/bin" &&
                     RunningCodexProcess.parseProcArgs([2, 0, 0, 0]) == nil,
                     "UI108 process arguments and environment are split at argc")
        let korean = HubPresentation()
        korean.language = .korean
        let settingsKeys = ["Menu bar", "Choose what the menu bar shows.", "Speed", "Combined", "By provider", "Combined + by provider", "Hidden", "Remaining usage",
                            "Usage windows", "Session + weekly", "5h limit only", "Weekly limit only", "Show time until reset", "Weekly", "Session", "left"]
        let collectorErrors: [CollectorError] = [.unsafePath, .inaccessibleSource, .database, .metadataInUse, .invalidSettings, .invalidRecord, .oversizedRecord, .sourceMismatch, .ambiguousSource]
        precondition(collectorErrors.allSatisfy { korean.text($0.message) != $0.message }, "UI109 every collector error message has a Korean translation")
        precondition(settingsKeys.allSatisfy { korean.text($0) != $0 }, "UI104 every menu bar setting and usage label has a Korean translation")
        precondition(historyModel.quotas.isEmpty && !historyModel.menuTitle.contains("%"), "UI98 providers without a login are not shown")
        readme.language = .english
        try capture(readme, "readme-overview-en", output, dark: true)
        readme.language = .korean
        try capture(readme, "readme-overview-ko", output, dark: true)
        historyModel.language = .korean
        historyModel.page = .detail(historyModel.sessions[0].id)
        try capture(historyModel, "wide-detail-full-dark", output, dark: true, height: 1600)
        historyModel.language = .english
        try capture(historyModel, "wide-detail-full-light", output, dark: false, height: 1600)
        historyModel.error = "Synthetic collection error"
        precondition(historyModel.overviewUsageHistory.isEmpty, "UI63 failed collection cannot present a stale current-window overview chart")
        historyModel.error = nil
        let archive = try UsageHistoryArchive.encode(historyModel.usageHistory, home: "fixture", monotonic: 303, wall: 10000)
        let restoredHistory = try UsageHistoryArchive.decode(archive, home: "fixture", monotonic: 3, wall: 10060)
        precondition(restoredHistory[newTurn.key]?.last?.time == -58, "UI65 chart timestamps survive reboot by preserving wall-clock age")
        let restartedModel = HubPresentation()
        restartedModel.restoreUsageHistory(restoredHistory)
        restartedModel.recordUsageHistory([], at: 3)
        precondition(restartedModel.usageHistory == restoredHistory, "UI66 initial discovery does not erase restored charts")
        restartedModel.recordUsageHistory([SessionPresentation(monitor: newTurn)], at: 4)
        precondition(restartedModel.usageHistory[newTurn.key]?.count == restoredHistory[newTurn.key]?.count, "UI67 restored charts never restore live counter anchors or invent catch-up")
        let expiredHistory = try UsageHistoryArchive.decode(archive, home: "fixture", monotonic: 3, wall: 14000)
        precondition(expiredHistory.isEmpty, "UI68 expired samples are not restored")
        precondition((try? UsageHistoryArchive.decode(archive, home: "other-home", monotonic: 3, wall: 10060)) == nil, "UI69 homes cannot share chart archives")
        precondition((try? UsageHistoryArchive.decode(Data("broken".utf8), home: "fixture", monotonic: 3, wall: 10060)) == nil, "UI70 corrupt chart archives are rejected")
        var warmingRestart = ThreadMonitor(key: newTurn.key, counter: newTurn.counter)
        try warmingRestart.setConnectivity(.connected, at: 0)
        try warmingRestart.markGap(at: 0)
        try warmingRestart.startTurn("restart", at: 1)
        restartedModel.sessions = [SessionPresentation(monitor: warmingRestart, rootObserved: true)]
        precondition(!restartedModel.overviewUsageHistory.isEmpty, "UI71 valid restored charts remain visible while live speed establishes its new baseline")
        let futureHistory = try UsageHistoryArchive.decode(archive, home: "fixture", monotonic: 3, wall: 9000)
        precondition(futureHistory.isEmpty, "UI72 clock rollback does not display future samples")
        let pathKey = ThreadKey(homeID: "/tmp/chart-home", runID: nil, threadID: "root")
        let pathHistory = [pathKey: [UsageHistoryPoint(time: 10, outputTokens: 42)]]
        precondition((try? UsageHistoryArchive.encode(pathHistory, home: "hashed-directory-id", monotonic: 11, wall: 100)) == nil, "UI73 wrong persistence scope must fail rather than silently save empty history")
        let pathArchive = try UsageHistoryArchive.encode(pathHistory, home: pathKey.homeID, monotonic: 11, wall: 100)
        let pathRestored = try UsageHistoryArchive.decode(pathArchive, home: pathKey.homeID, monotonic: 20, wall: 102)
        precondition(pathRestored[pathKey]?.first?.outputTokens == 42, "UI74 collector path identity survives chart persistence")
        let claudeKey = ThreadKey(homeID: "claude:/tmp/claude-home", runID: nil, threadID: "session")
        let mixedArchive = try UsageHistoryArchive.encode([pathKey: pathHistory[pathKey]!, claudeKey: [UsageHistoryPoint(time: 10, outputTokens: 7)]], home: pathKey.homeID, monotonic: 11, wall: 100)
        let mixedRestored = try UsageHistoryArchive.decode(mixedArchive, home: pathKey.homeID, monotonic: 20, wall: 102)
        precondition(mixedRestored[claudeKey]?.first?.outputTokens == 7 && mixedRestored[pathKey]?.first?.outputTokens == 42, "UI74 Claude chart history survives restarts beside Codex history")
        precondition((try? UsageHistoryArchive.encode([ThreadKey(homeID: "/other", runID: nil, threadID: "x"): [UsageHistoryPoint(time: 10, outputTokens: 1)]], home: pathKey.homeID, monotonic: 11, wall: 100)) == nil, "UI74 foreign Codex homes still cannot enter the archive")
        var quotaSession = model.sessions[0]
        quotaSession.usageDetails = try JSONDecoder().decode(SessionUsageDetails.self, from: Data(#"{"limits":[{"name":"primary","usedPercent":43,"windowMinutes":10080,"resetsAt":586800}]}"#.utf8))
        precondition(quotaSession.limitDescriptions(now: Date(timeIntervalSince1970: 0)) == ["57% 남음 · 6d 19h"], "UI75 reset countdown uses deadline, not quota window, and reports remaining percent")
        precondition(quotaSession.limitDescriptions(language: .english, now: Date(timeIntervalSince1970: 0)) == ["57% left · 6d 19h"], "UI76 countdown uses compact units in both languages")
        precondition(quotaSession.limitDescriptions(now: Date(timeIntervalSince1970: 586801)) == ["57% 남음 · 갱신 대기"], "UI77 expired quota does not invent a refreshed allowance")
        let idlePoints = [UsageHistoryPoint(time: 120.1, outputTokens: 10), UsageHistoryPoint(time: 120.9, outputTokens: 20)]
        let beforeTick = ObservedTokenChart(points: idlePoints, now: 180.5, emptyText: "")
        let afterTick = ObservedTokenChart(points: idlePoints, now: 181.5, emptyText: "")
        precondition(beforeTick.bins.map(\.tokens) == afterTick.bins.map(\.tokens), "UI78 idle clock ticks cannot regroup existing token samples")
        let nextMinute = ObservedTokenChart(points: idlePoints, now: 240.5, emptyText: "")
        precondition(nextMinute.bins.map(\.id) == afterTick.bins.map(\.id) && nextMinute.bins.map(\.tokens) == [30], "UI79 advancing the window preserves historical minute totals")
        precondition(ObservedTokenChart(points: idlePoints, now: 1980.5, emptyText: "").bins.isEmpty, "UI80 expired minutes leave the rolling chart")
        precondition(ObservedTokenChart(points: idlePoints, now: 120.5, emptyText: "").bins.map(\.tokens) == [10], "UI81 future samples cannot enter current minute")
        let clockPoints = [UsageHistoryPoint(time: 42.9, outputTokens: 10), UsageHistoryPoint(time: 43, outputTokens: 20)]
        let clockChart = ObservedTokenChart(points: clockPoints, now: 50, emptyText: "", wallClockOffset: 17)
        precondition(clockChart.bins.map(\.id) == [0, 60] && clockChart.bins.map(\.tokens) == [10, 20], "UI82 minute boundaries align to wall-clock second zero, not process uptime")
        var idleMonitor = ThreadMonitor(key: .init(homeID: "fixture", runID: nil, threadID: "idle-timeout"), source: .rolloutLog, epoch: "fixture", verifiedEmptyThread: true)
        try idleMonitor.setConnectivity(.connected, at: 0)
        try idleMonitor.startTurn("turn", at: 1)
        try idleMonitor.observeUsage(TokenUsage(outputTokens: 100), turnID: "turn", source: .rolloutLog, epoch: "fixture", at: 6)
        try idleMonitor.finishTurn("turn", outcome: .completed, at: 7)
        let idleModel = HubPresentation()
        idleModel.sessions = [SessionPresentation(monitor: idleMonitor, rootObserved: true)]
        idleModel.restoreUsageHistory([idleMonitor.key: [UsageHistoryPoint(time: 6, outputTokens: 100)]])
        idleModel.frame = try ReportedFrame(monitors: [idleMonitor], verifiedIndependentThreads: [idleMonitor.key], at: 16.999)
        precondition(idleModel.rate(for: idleModel.sessions[0]) == "20" && idleModel.menuTitle == "20 T/S", "UI83 idle grace retains row and aggregate speed before ten seconds")
        idleModel.frame = try ReportedFrame(monitors: [idleMonitor], verifiedIndependentThreads: [idleMonitor.key], at: 17)
        precondition(idleModel.rate(for: idleModel.sessions[0]) == "—" && idleModel.aggregateRate == nil && idleModel.menuTitle.isEmpty && !idleModel.usageHistory.isEmpty, "UI84 idle expiry clears row and menu rates without clearing chart history")
        try capture(idleModel, "idle-rate-expired", output, dark: true)
        var childMonitor = ThreadMonitor(key: .init(homeID: "fixture", runID: nil, threadID: "child-session"), source: .rolloutLog, epoch: "fixture", verifiedEmptyThread: true)
        try childMonitor.setConnectivity(.connected, at: 0)
        try childMonitor.startTurn("turn", at: 1)
        try childMonitor.observeUsage(TokenUsage(outputTokens: 100), turnID: "turn", source: .rolloutLog, epoch: "fixture", at: 6)
        let parentRow = SessionPresentation(monitor: idleMonitor, cwd: "/Synthetic/project", model: "Fixture model", rootObserved: true)
        let childRow = SessionPresentation(monitor: childMonitor, cwd: "/Synthetic/project", model: "Fixture model", parentThreadID: parentRow.id.threadID)
        let groupedModel = HubPresentation()
        groupedModel.language = .korean
        groupedModel.sessions = [parentRow, childRow]
        groupedModel.frame = try ReportedFrame(monitors: [idleMonitor, childMonitor], verifiedIndependentThreads: [idleMonitor.key], at: 10)
        groupedModel.restoreUsageHistory([parentRow.id: [UsageHistoryPoint(time: 4, outputTokens: 100)], childRow.id: [UsageHistoryPoint(time: 6, outputTokens: 60), UsageHistoryPoint(time: 8, outputTokens: 40)]])
        groupedModel.notice = "Synthetic parent/child sessions · not live telemetry"
        precondition(groupedModel.visibleSessions.map(\.id) == [parentRow.id] && groupedModel.processCount == 1 && groupedModel.auxiliarySessions(for: parentRow).map(\.id) == [childRow.id], "UI85 explicit parent links create one overview group")
        precondition(groupedModel.activeProcessCount == 1 && groupedModel.idleProcessCount == 0 && groupedModel.overviewState(for: parentRow).id == childRow.id, "UI86 active child keeps an idle parent group active")
        groupedModel.hideIdle = true
        precondition(groupedModel.visibleSessions.count == 1 && groupedModel.aggregateRate == 20 && groupedModel.rate(for: childRow) == "20" && groupedModel.usageHistory[childRow.id]?.count == 2, "UI87 grouping preserves independent rates, charts and hide-idle behavior without adding child counters")
        try capture(groupedModel, "session-group-overview", output, dark: true)
        groupedModel.page = .detail(parentRow.id)
        try capture(groupedModel, "session-group-details", output, dark: true, height: 1600)
        groupedModel.page = .detail(childRow.id)
        try capture(groupedModel, "auxiliary-session-details", output, dark: false)
        var orphan = childRow; orphan.parentThreadID = "missing"
        groupedModel.sessions = [parentRow, orphan]; groupedModel.hideIdle = false
        precondition(groupedModel.visibleSessions.count == 2, "UI88 missing parents never hide child rows")
        var cycleParent = parentRow; cycleParent.parentThreadID = childRow.id.threadID
        groupedModel.sessions = [cycleParent, childRow]
        precondition(groupedModel.visibleSessions.count == 2, "UI89 cyclic parent metadata cannot swallow rows")
        let otherHomeMonitor = ThreadMonitor(key: .init(homeID: "other-home", runID: nil, threadID: "other-child"), source: .rolloutLog, epoch: "fixture")
        groupedModel.sessions = [parentRow, SessionPresentation(monitor: otherHomeMonitor, parentThreadID: parentRow.id.threadID)]
        precondition(groupedModel.visibleSessions.count == 2, "UI90 parent links cannot cross Codex homes")
        let grandchildMonitor = ThreadMonitor(key: .init(homeID: "fixture", runID: nil, threadID: "grandchild"), source: .rolloutLog, epoch: "fixture")
        let grandchild = SessionPresentation(monitor: grandchildMonitor, parentThreadID: childRow.id.threadID)
        groupedModel.sessions = [parentRow, childRow, grandchild]
        precondition(groupedModel.visibleSessions.count == 1 && groupedModel.auxiliarySessions(for: parentRow).count == 2 && groupedModel.mainSession(for: grandchild)?.id == parentRow.id, "UI91 nested descendants stay reachable under their observed main session")
        let duplicateParent = ThreadMonitor(key: .init(homeID: "fixture", runID: "other-run", threadID: parentRow.id.threadID), source: .rolloutLog, epoch: "fixture")
        groupedModel.sessions = [parentRow, SessionPresentation(monitor: duplicateParent), childRow]
        precondition(groupedModel.visibleSessions.count == 3, "UI92 ambiguous parent identities stay separate")
        let unknownChild = SessionPresentation(monitor: grandchildMonitor, parentThreadID: parentRow.id.threadID)
        groupedModel.sessions = [parentRow, unknownChild]
        precondition(groupedModel.overviewState(for: parentRow).activity == .unknown && groupedModel.idleProcessCount == 0 && groupedModel.activeProcessCount == 0, "UI93 unknown child state agrees with overview group counts")
        let gridChildren = try (1...5).map { index -> SessionPresentation in
            var monitor = ThreadMonitor(key: .init(homeID: "fixture", runID: nil, threadID: "auxiliary-\(index)"), source: .rolloutLog, epoch: "fixture", verifiedEmptyThread: true)
            try monitor.setConnectivity(.connected, at: 0)
            try monitor.startTurn("turn", at: 1)
            try monitor.observeUsage(TokenUsage(outputTokens: index * 30), turnID: "turn", source: .rolloutLog, epoch: "fixture", at: 6)
            return SessionPresentation(monitor: monitor, cwd: "/Synthetic/project", model: "Fixture model", parentThreadID: parentRow.id.threadID)
        }
        groupedModel.sessions = [parentRow] + gridChildren
        groupedModel.restoreUsageHistory(Dictionary(uniqueKeysWithValues: gridChildren.enumerated().map { index, row in
            (row.id, [UsageHistoryPoint(time: 3, outputTokens: (index + 1) * 20), UsageHistoryPoint(time: 7, outputTokens: (index + 1) * 10)])
        }))
        groupedModel.page = .detail(parentRow.id)
        precondition(groupedModel.auxiliarySessions(for: parentRow).count == 5, "UI94 all auxiliary sessions remain available for an odd-sized grid")
        try capture(groupedModel, "auxiliary-grid-five-dark", output, dark: true, height: 1800)
        groupedModel.language = .english
        try capture(groupedModel, "auxiliary-grid-five-narrow", output, dark: false, height: 1800, width: 380)
        let hiddenModel = HubPresentation()
        hiddenModel.unattachedProcesses = [ProcessIdentity(pid: 1, osStartTime: "fixture")]
        precondition(hiddenModel.visibleUnattached.count == 1 && hiddenModel.processCount == 1, "UI95 unidentified processes are listed by default")
        hiddenModel.hideUnattached = true
        precondition(hiddenModel.visibleUnattached.isEmpty && hiddenModel.processCount == 0 && hiddenModel.summary == "실행 없음", "UI95 unidentified processes can be hidden")
        print("PASS UI01–UI109 and P01–P06; fixture PNGs: \(output)")
    }
    @MainActor static func verifyRunningProcesses() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("codex")
        let source = root.appendingPathComponent("writer.c")
        try Data("#include <fcntl.h>\n#include <unistd.h>\nint main(int n, char **v) { if (n < 2 || open(v[1], O_WRONLY | O_APPEND) < 0) return 2; char c; return read(0, &c, 1) < 0; }\n".utf8).write(to: source)
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
        precondition(RunningCodexProcess.owner(of: fileID, in: [process]) == process.identity, "P02 open transcript identifies its owner")
        precondition(RunningCodexProcess.owner(of: "missing", in: [process]) == nil, "P03 past transcript cannot match by name or cwd")
        let conflicting = RunningCodexProcess(identity: ProcessIdentity(pid: 123, osStartTime: "fixture"), writableFileIDs: [fileID])
        precondition(RunningCodexProcess.owner(of: fileID, in: [process, conflicting]) == nil, "P04 ambiguous owners remain unattached")
        child.terminate(); child.waitUntilExit()
        precondition(RunningCodexProcess.inspect(child.processIdentifier) == nil, "P05 exited process disappears")
        let host = Process()
        let hostInput = Pipe()
        host.executableURL = executable
        host.arguments = [log.path, "app-server", "--listen", "stdio://"]
        host.standardInput = hostInput
        host.standardOutput = FileHandle.nullDevice
        host.standardError = FileHandle.nullDevice
        try host.run()
        defer { hostInput.fileHandleForWriting.closeFile(); if host.isRunning { host.terminate() }; host.waitUntilExit() }
        var hostObserved: RunningCodexProcess?
        let hostDeadline = Date().addingTimeInterval(3)
        repeat {
            hostObserved = RunningCodexProcess.inspect(host.processIdentifier)
            if hostObserved?.isAppServer == true { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        } while Date() < hostDeadline
        precondition(hostObserved?.isAppServer == true && observed?.isAppServer == false, "P06 app-server hosts are told apart from terminal sessions")
    }
    @MainActor static func capture(_ model: HubPresentation, _ name: String, _ output: String, dark: Bool, height: CGFloat = 720, width: CGFloat = 460) throws {
        let view = NSHostingView(rootView: HubView(model: model, width: width, height: height).environment(\.colorScheme, dark ? .dark : .light))
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: width,height: height), styleMask: [.borderless], backing: .buffered, defer: false)
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
