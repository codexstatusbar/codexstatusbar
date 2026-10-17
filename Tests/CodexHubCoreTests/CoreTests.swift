import Testing
import Foundation
import CodexHubCore

@Test func C01FirstSnapshotAndRepeatedSnapshotAreNotNewOutput() throws {
    var counter = UsageCounter(source: .rolloutLog, epoch: "e1")
    let usage = try TokenUsage(outputTokens: 12_480, reasoningOutputTokens: 8_960)
    #expect(usage.nonReasoningOutputTokens == 3_520)
    #expect(counter.observe(usage, source: .rolloutLog, epoch: "e1") == .baseline)
    for _ in 0..<100 {
        #expect(counter.observe(usage, source: .rolloutLog, epoch: "e1") == .delta(0))
    }
}

@Test func C02RegressionRequiresExplicitReconciliation() throws {
    var c = UsageCounter(source: .directRelay, epoch: "e", verifiedEmptyThread: true)
    #expect(c.observe(try TokenUsage(outputTokens: 100), source: .directRelay, epoch: "e") == .delta(100))
    #expect(c.observe(try TokenUsage(outputTokens: 20), source: .directRelay, epoch: "e") == .regression)
    #expect(c.observe(try TokenUsage(outputTokens: 200), source: .directRelay, epoch: "e") == .suspended)
    c.reconcile(source: .rolloutLog, epoch: "e2", baseline: try TokenUsage(outputTokens: 200))
    #expect(c.observe(try TokenUsage(outputTokens: 900), source: .directRelay, epoch: "e2") == .secondarySource)
    #expect(c.observe(try TokenUsage(outputTokens: 900), source: .rolloutLog, epoch: "e") == .wrongEpoch)
    #expect(c.observe(try TokenUsage(outputTokens: 220), source: .rolloutLog, epoch: "e2") == .delta(20))
}

@Test func C03CompletedTurnNeverRevivesOnLateUsage() throws {
    var m = ThreadMonitor(key: ThreadKey(homeID: "h", runID: "r", threadID: "t"),
                          source: .rolloutLog, epoch: "e", verifiedEmptyThread: true)
    try m.setConnectivity(.connected, at: 0)
    try m.startTurn("turn", at: 0)
    _ = try m.observeUsage(try TokenUsage(outputTokens: 100), turnID: "turn", source: .rolloutLog, epoch: "e", at: 1)
    try m.finishTurn("turn", outcome: .completed, at: 2)
    _ = try m.observeUsage(try TokenUsage(outputTokens: 120), turnID: "turn", source: .rolloutLog, epoch: "e", at: 3)
    #expect(m.activity == .idle)
    #expect(try m.reportedRate(at: 3) == nil)
    #expect(m.turns["turn"]?.outputTokens == 120)
    #expect(m.turns["turn"]?.average == 60)
}

func monitor(_ run: String, empty: Bool = true) throws -> ThreadMonitor {
    var m = ThreadMonitor(key: ThreadKey(homeID: "h", runID: run, threadID: run),
                          source: .rolloutLog, epoch: "e", verifiedEmptyThread: empty)
    try m.setConnectivity(.connected, at: 0)
    try m.startTurn("turn", at: 0)
    return m
}

@Test func C04OneFrameAggregatesWorkAverages() throws {
    var a = try monitor("a")
    var b = try monitor("b")
    try a.observeUsage(TokenUsage(outputTokens: 600), turnID: "turn", source: .rolloutLog, epoch: "e", at: 5)
    try b.observeUsage(TokenUsage(outputTokens: 300), turnID: "turn", source: .rolloutLog, epoch: "e", at: 6)
    let frame = try ReportedFrame(monitors: [a, b], verifiedIndependentThreads: [a.key, b.key], at: 10)
    #expect(frame.tokensPerSecond == 170)
    #expect(frame.measuredRuns == 2 && frame.eligibleRuns == 2 && !frame.isPartial)
    #expect(try a.reportedRate(at: 15) == 0)
    try a.finishTurn("turn", outcome: .completed, at: 15)
    #expect(try a.reportedRate(at: 15) == nil)
}

func rejects(_ body: () throws -> Void) {
    do { try body(); Issue.record("Expected rejection") } catch {}
}

@Test func C05InvalidUsageAndBreakdown() throws {
    rejects { _ = try TokenUsage(outputTokens: -1) }
    rejects { _ = try TokenUsage(outputTokens: 1, reasoningOutputTokens: -1) }
    rejects { _ = try TokenUsage(outputTokens: 1, inputTokens: -1) }
    rejects { _ = try TokenUsage(outputTokens: 1, cachedInputTokens: -1) }
    rejects { _ = try TokenUsage(outputTokens: 1, cacheWriteInputTokens: -1) }
    rejects { _ = try TokenUsage(outputTokens: 1, totalTokens: -1) }
    #expect(try TokenUsage(outputTokens: 1, reasoningOutputTokens: 2).nonReasoningOutputTokens == nil)
    #expect(try TokenUsage(outputTokens: 1).nonReasoningOutputTokens == nil)
    var c = UsageCounter(source: .rolloutLog, epoch: "e", verifiedEmptyThread: true)
    #expect(c.observe(try TokenUsage(outputTokens: Int.max), source: .rolloutLog, epoch: "e") == .delta(Int.max))
}

@Test func C06ConcurrentToolsAndApprovalsRestoreUnderlyingActivity() throws {
    var m = try monitor("a")
    try m.setGenerating(true, turnID: "turn", at: 0)
    try m.setTool("a", running: true, turnID: "turn", at: 1)
    try m.setTool("b", running: true, turnID: "turn", at: 1)
    try m.setApproval("a", waiting: true, turnID: "turn", at: 2)
    try m.setApproval("b", waiting: true, turnID: "turn", at: 2)
    try m.setApproval("a", waiting: false, turnID: "turn", at: 3)
    #expect(m.activity == .approvalWait)
    try m.setApproval("b", waiting: false, turnID: "turn", at: 3)
    #expect(m.activity == .toolRunning)
    try m.setTool("a", running: false, turnID: "turn", at: 4)
    #expect(m.activity == .toolRunning)
    try m.setTool("b", running: false, turnID: "turn", at: 4)
    #expect(m.activity == .generating)
    try m.setGenerating(false, turnID: "turn", at: 5)
    #expect(m.activity == .working)
    #expect(try m.reportedRate(at: 100) == nil)
    #expect(m.activity == .working)
    try m.finishTurn("turn", outcome: .interrupted, at: 100)
    try m.setApproval("late", waiting: true, turnID: "turn", at: 101)
    #expect(m.activity == .idle && m.approvalIDs.isEmpty)
    rejects { try m.startTurn("turn", at: 102) }
}

@Test func C07MissingStartOrBaselineCannotProduceTurnAverage() throws {
    var m = try monitor("a", empty: false)
    try m.observeUsage(TokenUsage(outputTokens: 10_000), turnID: "turn", source: .rolloutLog, epoch: "e", at: 1)
    #expect(try m.reportedRate(at: 1) == nil)
    try m.finishTurn("turn", outcome: .completed, at: 2)
    #expect(m.turns["turn"]?.average == nil)
    try m.observeUsage(TokenUsage(outputTokens: 10_050), turnID: "missed", source: .rolloutLog, epoch: "e", at: 3)
    try m.finishTurn("missed", outcome: .completed, at: 4)
    #expect(m.turns["missed"]?.average == nil)
}

@Test func C08ReconnectAndSleepDiscardCatchupRates() throws {
    var m = try monitor("a")
    try m.observeUsage(TokenUsage(outputTokens: 100), turnID: "turn", source: .rolloutLog, epoch: "e", at: 1)
    try m.setConnectivity(.disconnected, at: 2)
    #expect(m.activity == .working && m.measurement == .unavailable)
    #expect(try m.reportedRate(at: 2) == nil)
    try m.setConnectivity(.connected, at: 3)
    try m.observeUsage(TokenUsage(outputTokens: 1_000), turnID: "turn", source: .rolloutLog, epoch: "e", at: 4)
    #expect(try m.reportedRate(at: 4) == nil)
    try m.observeUsage(TokenUsage(outputTokens: 1_100), turnID: "turn", source: .rolloutLog, epoch: "e", at: 5)
    #expect(try m.reportedRate(at: 5) == 10)
    try m.markGap(at: 6)
    try m.observeUsage(TokenUsage(outputTokens: 9_000), turnID: "turn", source: .rolloutLog, epoch: "e", at: 50)
    #expect(try m.reportedRate(at: 50) == nil)
    try m.finishTurn("turn", outcome: .completed, at: 51)
    #expect(m.turns["turn"]?.average == nil)
}

@Test func C09HistoryAndOtherSourcesNeverAddCurrentRates() throws {
    var m = try monitor("a")
    try m.observeUsage(TokenUsage(outputTokens: 100), turnID: "turn", source: .rolloutLog, epoch: "e", at: 1, historical: true)
    #expect(try m.reportedRate(at: 1) == nil)
    try m.observeUsage(TokenUsage(outputTokens: 900), turnID: "turn", source: .directRelay, epoch: "e", at: 2)
    try m.observeUsage(TokenUsage(outputTokens: 900), turnID: "turn", source: .rolloutLog, epoch: "old", at: 2)
    #expect(m.counter.baseline?.outputTokens == 100)
    #expect(try m.reportedRate(at: 2) == nil)
}

@Test func C10IdentityCoverageAndUnknownScope() throws {
    var a = try monitor("a")
    try a.observeUsage(TokenUsage(outputTokens: 0), turnID: "turn", source: .rolloutLog, epoch: "e", at: 1)
    let b = try monitor("b", empty: false)
    let f = try ReportedFrame(monitors: [a, b], verifiedIndependentThreads: [a.key, b.key], at: 1)
    #expect(f.measuredRuns == 1 && f.eligibleRuns == 2 && f.isPartial)
    let unverified = try ReportedFrame(monitors: [a], verifiedIndependentThreads: [], at: 1)
    #expect(unverified.tokensPerSecond == nil && unverified.isPartial)
    rejects { _ = try ReportedFrame(monitors: [a, a], verifiedIndependentThreads: [a.key], at: 0) }
    #expect(ProcessIdentity(pid: 1, osStartTime: "first") != ProcessIdentity(pid: 1, osStartTime: "second"))
    #expect(ThreadKey(homeID: "h", runID: "a", threadID: "t") != ThreadKey(homeID: "h", runID: "b", threadID: "t"))
    let unknown = ThreadMonitor(key: ThreadKey(homeID: "h", runID: nil, threadID: "u"), source: .rolloutLog, epoch: "e")
    let u = try ReportedFrame(monitors: [unknown], verifiedIndependentThreads: [], at: 1)
    #expect(u.eligibleRuns == 1 && u.measuredRuns == 0)
}

@Test func C11InvalidTimeAndCounterRegressionSuspendRates() throws {
    var m = try monitor("a")
    try m.observeUsage(TokenUsage(outputTokens: 100), turnID: "turn", source: .rolloutLog, epoch: "e", at: 1)
    rejects { try m.setConnectivity(.connected, at: .nan) }
    rejects { _ = try m.reportedRate(at: .infinity) }
    rejects { try m.markGap(at: 0) }
    try m.observeUsage(TokenUsage(outputTokens: 50), turnID: "turn", source: .rolloutLog, epoch: "e", at: 2)
    #expect(m.measurement == .partial)
    #expect(try m.reportedRate(at: 2) == nil)
    try m.reconcile(source: .rolloutLog, epoch: "new", baseline: TokenUsage(outputTokens: 50), at: 3)
    try m.observeUsage(TokenUsage(outputTokens: 70), turnID: "turn", source: .rolloutLog, epoch: "new", at: 4)
    #expect(try m.reportedRate(at: 4) == 2)
}


@Test func C12OverflowDoesNotAdvanceCheckpoint() throws {
    var m = try monitor("a")
    try m.observeUsage(TokenUsage(outputTokens: Int.max), turnID: "turn", source: .rolloutLog, epoch: "e", at: 1)
    try m.reconcile(source: .rolloutLog, epoch: "e2", baseline: TokenUsage(outputTokens: 0), at: 2)
    rejects { try m.observeUsage(TokenUsage(outputTokens: 1), turnID: "turn", source: .rolloutLog, epoch: "e2", at: 3) }
    #expect(m.counter.baseline?.outputTokens == 0)
    #expect(m.turns["turn"]?.outputTokens == Int.max)
}

@Test func C13NoReportIsDifferentFromAnObservedZero() throws {
    var m = try monitor("a")
    #expect(try m.reportedRate(at: 0) == nil)
    #expect(m.measurement == .warmingUp)
    try m.observeUsage(TokenUsage(outputTokens: 0), turnID: "turn", source: .rolloutLog, epoch: "e", at: 1)
    #expect(try m.reportedRate(at: 1) == 0)
    try m.finishTurn("turn", outcome: .completed, at: 2)
    try m.startTurn("next", at: 3)
    #expect(try m.reportedRate(at: 3) == nil)
    #expect(m.activity == .working)
}

@Test func C14CoverageCountsRunsAndExcludesIdle() throws {
    var a = try monitor("r")
    try a.observeUsage(TokenUsage(outputTokens: 100), turnID: "turn", source: .rolloutLog, epoch: "e", at: 1)
    var b = ThreadMonitor(key: ThreadKey(homeID: "h", runID: "r", threadID: "child"), source: .rolloutLog, epoch: "e", verifiedEmptyThread: true)
    try b.setConnectivity(.connected, at: 0)
    try b.startTurn("childTurn", at: 0)
    let partial = try ReportedFrame(monitors: [a, b], verifiedIndependentThreads: [a.key, b.key], at: 1)
    #expect(partial.eligibleRuns == 1 && partial.measuredRuns == 0 && partial.isPartial)
    try b.observeUsage(TokenUsage(outputTokens: 50), turnID: "childTurn", source: .rolloutLog, epoch: "e", at: 1)
    let measured = try ReportedFrame(monitors: [a, b], verifiedIndependentThreads: [a.key, b.key], at: 1)
    #expect(measured.eligibleRuns == 1 && measured.measuredRuns == 1 && measured.tokensPerSecond == 150)
    try a.finishTurn("turn", outcome: .failed, at: 2)
    try b.finishTurn("childTurn", outcome: .completed, at: 2)
    let idle = try ReportedFrame(monitors: [a, b], verifiedIndependentThreads: [], at: 2)
    #expect(idle.eligibleRuns == 1 && idle.measuredRuns == 0 && idle.tokensPerSecond == nil && idle.isPartial)
}

@Test(arguments: [true, false])
func C15OptionalRegressionAcrossMissingSnapshotSuspends(reasoning: Bool) throws {
    var c = UsageCounter(source: .rolloutLog, epoch: "e")
    let known = try TokenUsage(outputTokens: 100, reasoningOutputTokens: reasoning ? 80 : nil,
                               totalTokens: reasoning ? nil : 200)
    let missing = try TokenUsage(outputTokens: 110)
    let lower = try TokenUsage(outputTokens: 120, reasoningOutputTokens: reasoning ? 10 : nil,
                               totalTokens: reasoning ? nil : 130)
    #expect(c.observe(known, source: .rolloutLog, epoch: "e") == .baseline)
    #expect(c.observe(missing, source: .rolloutLog, epoch: "e") == .delta(10))
    #expect(c.baseline == missing)
    #expect(c.baseline?.nonReasoningOutputTokens == nil)
    #expect(c.observe(lower, source: .rolloutLog, epoch: "e") == .regression)
    #expect(c.isPartial)
    #expect(c.baseline == missing)
    #expect(c.observe(try TokenUsage(outputTokens: 300, reasoningOutputTokens: 90, totalTokens: 400),
                      source: .rolloutLog, epoch: "e") == .suspended)
    #expect(c.baseline == missing)
}

@Test func C16OptionalValidationSurvivesRejectedSourcesAndResetsOnReconcile() throws {
    var c = UsageCounter(source: .rolloutLog, epoch: "e")
    let known = try TokenUsage(outputTokens: 100, reasoningOutputTokens: 80, totalTokens: 200)
    #expect(c.observe(known, source: .rolloutLog, epoch: "e") == .baseline)
    let foreign = try TokenUsage(outputTokens: 1_000, reasoningOutputTokens: 900, totalTokens: 2_000)
    #expect(c.observe(foreign, source: .directRelay, epoch: "e") == .secondarySource)
    #expect(c.observe(foreign, source: .rolloutLog, epoch: "other") == .wrongEpoch)
    #expect(c.observe(try TokenUsage(outputTokens: 110), source: .rolloutLog, epoch: "e") == .delta(10))
    #expect(c.observe(try TokenUsage(outputTokens: 120, reasoningOutputTokens: 80, totalTokens: 200),
                      source: .rolloutLog, epoch: "e") == .delta(10))
    #expect(c.observe(try TokenUsage(outputTokens: 130), source: .rolloutLog, epoch: "e") == .delta(10))
    #expect(c.observe(try TokenUsage(outputTokens: 140, reasoningOutputTokens: 90, totalTokens: 210),
                      source: .rolloutLog, epoch: "e") == .delta(10))
    for baseline in [try TokenUsage(outputTokens: 10, reasoningOutputTokens: 2, totalTokens: 12),
                     try TokenUsage(outputTokens: 10)] {
        c.reconcile(source: .directRelay, epoch: "new", baseline: baseline)
        #expect(!c.isPartial && c.baseline == baseline)
        #expect(c.lastKnownReasoningOutputTokens == baseline.reasoningOutputTokens)
        #expect(c.lastKnownTotalTokens == baseline.totalTokens)
        #expect(c.observe(try TokenUsage(outputTokens: 20, reasoningOutputTokens: 3, totalTokens: 23),
                          source: .directRelay, epoch: "new") == .delta(10))
    }
}

@Test(arguments: [true, false])
func C17OptionalRegressionPropagatesPartialAndNilRate(reasoning: Bool) throws {
    var m = try monitor("a", empty: false)
    try m.observeUsage(TokenUsage(outputTokens: 100, reasoningOutputTokens: reasoning ? 80 : nil,
                                  totalTokens: reasoning ? nil : 200),
                       turnID: "turn", source: .rolloutLog, epoch: "e", at: 1)
    try m.observeUsage(TokenUsage(outputTokens: 110), turnID: "turn", source: .rolloutLog, epoch: "e", at: 2)
    #expect(try m.reportedRate(at: 2) == 1)
    #expect(try m.observeUsage(TokenUsage(outputTokens: 120, reasoningOutputTokens: reasoning ? 10 : nil,
                                         totalTokens: reasoning ? nil : 130),
                              turnID: "turn", source: .rolloutLog, epoch: "e", at: 3) == .regression)
    #expect(m.measurement == .partial)
    #expect(try m.reportedRate(at: 3) == nil)
    #expect(try m.observeUsage(TokenUsage(outputTokens: 300), turnID: "turn",
                              source: .rolloutLog, epoch: "e", at: 4) == .suspended)
    #expect(m.measurement == .partial && m.turns["turn"]?.outputTokens == 10)
    #expect(try m.reportedRate(at: 4) == nil)
}

@Test(arguments: ["input", "cached", "cacheWrite"])
func C18NonoptionalCounterDecreasesSuspend(field: String) throws {
    var c = UsageCounter(source: .rolloutLog, epoch: "e")
    let known = try TokenUsage(outputTokens: 100, inputTokens: 50, cachedInputTokens: 30, cacheWriteInputTokens: 20)
    #expect(c.observe(known, source: .rolloutLog, epoch: "e") == .baseline)
    let lower = try TokenUsage(outputTokens: 110, inputTokens: field == "input" ? 49 : 50,
                               cachedInputTokens: field == "cached" ? 29 : 30,
                               cacheWriteInputTokens: field == "cacheWrite" ? 19 : 20)
    #expect(c.observe(lower, source: .rolloutLog, epoch: "e") == .regression)
    #expect(c.isPartial && c.baseline == known)
    #expect(c.observe(known, source: .rolloutLog, epoch: "e") == .suspended)
}

@Test(arguments: [false, true], [false, true])
func C19CheckpointRestorePreservesValidationWithoutInventingActivity(partial: Bool, reasoning: Bool) throws {
    let missing = try TokenUsage(outputTokens: 110)
    let c = try UsageCounter(source: .rolloutLog, epoch: "e", baseline: missing,
                             lastKnownReasoningOutputTokens: 80, lastKnownTotalTokens: 200, isPartial: partial)
    var m = ThreadMonitor(key: ThreadKey(homeID: "h", runID: "r", threadID: "t"), counter: c)
    #expect(m.counter.baseline == missing)
    #expect(m.counter.lastKnownReasoningOutputTokens == 80 && m.counter.lastKnownTotalTokens == 200)
    #expect(m.activity == .unknown && m.activeTurnID == nil && m.turns.isEmpty)
    #expect(m.measurement == (partial ? .partial : .unavailable))
    #expect(try m.reportedRate(at: 0) == nil)
    #expect(try m.observeUsage(TokenUsage(outputTokens: 120, reasoningOutputTokens: reasoning ? 10 : 80,
                                         totalTokens: reasoning ? 200 : 130),
                              turnID: "old", source: .rolloutLog, epoch: "e", at: 1) == (partial ? .suspended : .regression))
    #expect(m.counter.baseline == missing && m.counter.isPartial)
    #expect(m.counter.lastKnownReasoningOutputTokens == 80 && m.counter.lastKnownTotalTokens == 200)
    #expect(m.turns.isEmpty && m.activity == .unknown)
}

@Test func C20RestoreRejectsInvalidValidationState() throws {
    let known = try TokenUsage(outputTokens: 100, reasoningOutputTokens: 80, totalTokens: 200)
    for (reasoning, total) in [(-1, 200), (80, -1), (79, 200), (81, 200), (80, 199), (80, 201)] {
        rejects {
            _ = try UsageCounter(source: .rolloutLog, epoch: "e", baseline: known,
                                 lastKnownReasoningOutputTokens: reasoning, lastKnownTotalTokens: total, isPartial: false)
        }
    }
    for (reasoning, total, partial) in [(80 as Int?, nil as Int?, false), (nil, 200, false), (nil, nil, true)] {
        rejects {
            _ = try UsageCounter(source: .rolloutLog, epoch: "e", baseline: nil,
                                 lastKnownReasoningOutputTokens: reasoning, lastKnownTotalTokens: total, isPartial: partial)
        }
    }
    rejects {
        _ = try UsageCounter(source: .rolloutLog, epoch: "e", baseline: known,
                             lastKnownReasoningOutputTokens: nil, lastKnownTotalTokens: nil, isPartial: false)
    }
    let restored = try UsageCounter(source: .rolloutLog, epoch: "e", baseline: known,
                                    lastKnownReasoningOutputTokens: 80, lastKnownTotalTokens: 200, isPartial: false)
    #expect(restored.baseline == known && !restored.isPartial)
    var empty = try UsageCounter(source: .rolloutLog, epoch: "e", baseline: nil,
                                 lastKnownReasoningOutputTokens: nil, lastKnownTotalTokens: nil, isPartial: false)
    #expect(empty.observe(known, source: .rolloutLog, epoch: "e") == .baseline)
}

@Test func C21WorkAverageDoesNotExpireAfterTenSeconds() throws {
    var m = try monitor("work-average")
    try m.observeUsage(TokenUsage(outputTokens: 600), turnID: "turn", source: .rolloutLog, epoch: "e", at: 5)
    let later = try ReportedFrame(monitors: [m], verifiedIndependentThreads: [m.key], at: 30)
    #expect(later.tokensPerSecond == 120)
    let waiting = try ReportedFrame(monitors: [m], verifiedIndependentThreads: [m.key], at: 60)
    #expect(waiting.tokensPerSecond == 120)
}

@Test func C22WorkAverageIncludesToolsAndWaitsAndClosesAtIdle() throws {
    var m = try monitor("average-waits")
    try m.observeUsage(TokenUsage(outputTokens: 100), turnID: "turn", source: .rolloutLog, epoch: "e", at: 5)
    try m.setTool("tool", running: true, turnID: "turn", at: 7)
    #expect(try m.workAverageRate(at: 10) == 20)
    try m.setApproval("approval", waiting: true, turnID: "turn", at: 15)
    try m.observeUsage(TokenUsage(outputTokens: 200), turnID: "turn", source: .rolloutLog, epoch: "e", at: 20)
    #expect(try m.workAverageRate(at: 20) == 10)
    try m.finishTurn("turn", outcome: .completed, at: 40)
    #expect(m.activity == .idle)
    #expect(try m.workAverageRate(at: 40) == 10)
    #expect(m.turns["turn"]?.workAverage == 5)
    try m.observeUsage(TokenUsage(outputTokens: 240), turnID: "turn", source: .rolloutLog, epoch: "e", at: 45)
    #expect(m.turns["turn"]?.workAverage == 6)
    #expect(try m.workAverageRate(at: 45) == 6)
}

@Test func C23MissingBaselineAndGapProduceOnlyObservedPeriodAverage() throws {
    var m = try monitor("average-gap", empty: false)
    try m.observeUsage(TokenUsage(outputTokens: 100), turnID: "turn", source: .rolloutLog, epoch: "e", at: 10)
    #expect(try m.workAverageRate(at: 10) == nil)
    try m.observeUsage(TokenUsage(outputTokens: 140), turnID: "turn", source: .rolloutLog, epoch: "e", at: 20)
    #expect(try m.workAverageRate(at: 30) == 4)
    #expect(m.workAverageIsPartial)
    try m.markGap(at: 31)
    try m.observeUsage(TokenUsage(outputTokens: 500), turnID: "turn", source: .rolloutLog, epoch: "e", at: 40)
    #expect(try m.workAverageRate(at: 40) == nil)
    try m.observeUsage(TokenUsage(outputTokens: 560), turnID: "turn", source: .rolloutLog, epoch: "e", at: 50)
    let frame = try ReportedFrame(monitors: [m], verifiedIndependentThreads: [m.key], at: 60)
    #expect(frame.tokensPerSecond == 6 && frame.isPartial)
    try m.finishTurn("turn", outcome: .completed, at: 70)
    #expect(m.turns["turn"]?.workAverage == 2)
    #expect(m.turns["turn"]?.isObservedAveragePartial == true)
}

@Test func C24WorkAverageDistinguishesNoReportFromReportedZero() throws {
    var m = try monitor("average-zero")
    #expect(try m.workAverageRate(at: 10) == nil)
    try m.observeUsage(TokenUsage(outputTokens: 0), turnID: "turn", source: .rolloutLog, epoch: "e", at: 10)
    #expect(try m.workAverageRate(at: 10) == 0)
    try m.finishTurn("turn", outcome: .completed, at: 20)
    #expect(m.turns["turn"]?.workAverage == 0)
}

@Test func C25DifferentWorkStartsSumIndividualAveragesAtOneFrame() throws {
    var a = try monitor("average-a")
    try a.observeUsage(TokenUsage(outputTokens: 100), turnID: "turn", source: .rolloutLog, epoch: "e", at: 10)
    var b = ThreadMonitor(key: ThreadKey(homeID: "h", runID: "average-b", threadID: "average-b"), source: .rolloutLog, epoch: "e", verifiedEmptyThread: true)
    try b.setConnectivity(.connected, at: 0)
    try b.startTurn("turn", at: 10)
    try b.observeUsage(TokenUsage(outputTokens: 100), turnID: "turn", source: .rolloutLog, epoch: "e", at: 20)
    let frame = try ReportedFrame(monitors: [a,b], verifiedIndependentThreads: [a.key,b.key], at: 20)
    #expect(frame.tokensPerSecond == 20)
}

@Test func C26ZeroOrUnrepresentableElapsedRateDoesNotProduceANumber() throws {
    var m = try monitor("average-time-boundary")
    try m.observeUsage(TokenUsage(outputTokens: 100), turnID: "turn", source: .rolloutLog, epoch: "e", at: 0)
    #expect(try m.workAverageRate(at: 0) == nil)
    #expect(try m.workAverageRate(at: Double.leastNonzeroMagnitude) == nil)
    #expect(try m.workAverageRate(at: 1) == nil)
    try m.observeUsage(TokenUsage(outputTokens: 100), turnID: "turn", source: .rolloutLog, epoch: "e", at: 1)
    #expect(try m.workAverageRate(at: 1) == 100)
}

@Test func C27RateChangesOnlyOnUsageAndSurvivesIdleAndNextTurn() throws {
    var m = try monitor("held-rate")
    try m.observeUsage(TokenUsage(outputTokens: 100), turnID: "turn", source: .rolloutLog, epoch: "e", at: 5)
    #expect(try m.workAverageRate(at: 50) == 20)
    try m.finishTurn("turn", outcome: .completed, at: 60)
    #expect(try m.workAverageRate(at: 60) == 20)
    try m.startTurn("next", at: 70)
    #expect(try m.workAverageRate(at: 80) == 20)
    try m.observeUsage(TokenUsage(outputTokens: 200), turnID: "next", source: .rolloutLog, epoch: "e", at: 90)
    #expect(try m.workAverageRate(at: 100) == 5)
    try m.observeUsage(TokenUsage(outputTokens: 210), turnID: "turn", source: .rolloutLog, epoch: "e", at: 101)
    #expect(try m.workAverageRate(at: 102) == 5)
    try m.markGap(at: 110)
    #expect(try m.workAverageRate(at: 110) == nil)
}


@Test func C28RequestEstimateUsesOnlyExplicitDurationAndHoldsThroughMissingTiming() throws {
    var m = try monitor("request-rate")
    try m.observeUsage(TokenUsage(outputTokens: 100), turnID: "turn", source: .rolloutLog, epoch: "e", at: 100, rateInterval: .excludingTools(4))
    #expect(try m.workAverageRate(at: 200) == 25)
    try m.observeUsage(TokenUsage(outputTokens: 140), turnID: "turn", source: .rolloutLog, epoch: "e", at: 210, rateInterval: .excludingTools(nil))
    #expect(try m.workAverageRate(at: 220) == 25)
    try m.observeUsage(TokenUsage(outputTokens: 180), turnID: "turn", source: .rolloutLog, epoch: "e", at: 230, rateInterval: .excludingTools(2))
    #expect(try m.workAverageRate(at: 240) == 20)
}

@Test func C29ServerTimingParsesMetadataWithoutInventingDecodeRate() {
    let payload = #"{"type":"responsesapi.websocket_timing","timing_metrics":{"engine_service_total_ms":450,"engine_service_ttft_total_ms":340,"engine_service_tbt_across_engine_calls_ms":260}}"#
    let line = "TRACE codex_api::responses_websocket_timing: thread_id=thread-1 turn_id=turn-1 warmup=false payload=" + payload
    let timing = ServerTiming.parse(logLine: line)
    #expect(timing?.threadID == "thread-1")
    #expect(timing?.inferenceMilliseconds == 450)
    #expect(timing?.firstTokenMilliseconds == 340)
    #expect(timing?.betweenTokenMilliseconds == 260)
    #expect(ServerTiming.parse(logLine: line.replacingOccurrences(of: "warmup=false", with: "warmup=true")) == nil)
    #expect(ServerTiming.parse(logLine: line.replacingOccurrences(of: "thread_id=thread-1", with: "thread_id=")) == nil)
    #expect(ServerTiming.parse(logLine: String(repeating: "x", count: 65_537)) == nil)
}


@Test func C30ServerTimingRejectsInvalidFieldsAndAcceptsQuotedTracePayload() throws {
    let payload = #"{"type":"responsesapi.websocket_timing","timing_metrics":{"engine_service_total_ms":12.5}}"#
    let quoted = String(data: try JSONEncoder().encode(payload), encoding: .utf8)!
    let prefix = "TRACE codex_api::responses_websocket_timing: thread_id=\"thread-1\" turn_id=\"turn-1\" warmup=false payload="
    #expect(ServerTiming.parse(logLine: prefix + quoted)?.inferenceMilliseconds == 12.5)
    for invalid in ["-1", "true", "null", "\"12.5\""] {
        #expect(ServerTiming.parse(logLine: prefix + payload.replacingOccurrences(of: "12.5", with: invalid)) == nil)
    }
    #expect(ServerTiming.parse(logLine: prefix + "not-json") == nil)
}

@Test func C31ActualServerStreamTimingSchemaIsPreservedWithoutInventingEngineTime() {
    let payload = #"{"type":"responsesapi.websocket_timing","timing_metrics":{"timing_scope":"logical_turn","response_id":"response-fixture","websocket_output_text_delta_tbt_ms":16.467705253164556,"websocket_output_text_delta_count":159,"pre_inference_ms":235.108268,"client_tool_pause_total_ms":0,"num_engine_calls":1,"num_sampled_tokens_total":163,"critical_path":{"scope":"response","coverage":"missing_harness_boundary"}}}"#
    let line = "TRACE codex_api::responses_websocket_timing: thread_id=thread-fixture turn_id=turn-fixture warmup=false payload=" + payload
    let timing = ServerTiming.parse(logLine: line)
    #expect(timing?.sampledTokens == 163)
    #expect(timing?.outputDeltaCount == 159)
    #expect(timing?.outputDeltaMeanMilliseconds == 16.467705253164556)
    #expect(timing?.coverage == "missing_harness_boundary")
    #expect(timing?.inferenceMilliseconds == nil && timing?.betweenTokenMilliseconds == nil)
    #expect(timing?.responseID == "response-fixture")
}
