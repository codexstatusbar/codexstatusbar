import Darwin
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

@Test func C27RateChangesOnlyOnUsageAndSurvivesBriefIdleAndNextTurn() throws {
    var m = try monitor("held-rate")
    try m.observeUsage(TokenUsage(outputTokens: 100), turnID: "turn", source: .rolloutLog, epoch: "e", at: 5)
    #expect(try m.workAverageRate(at: 50) == 20)
    try m.finishTurn("turn", outcome: .completed, at: 60)
    #expect(try m.workAverageRate(at: 60) == 20)
    try m.startTurn("next", at: 69)
    #expect(try m.workAverageRate(at: 80) == 20)
    try m.observeUsage(TokenUsage(outputTokens: 200), turnID: "next", source: .rolloutLog, epoch: "e", at: 90)
    #expect(try m.workAverageRate(at: 100) == 100.0 / 21)
    try m.observeUsage(TokenUsage(outputTokens: 210), turnID: "turn", source: .rolloutLog, epoch: "e", at: 101)
    #expect(try m.workAverageRate(at: 102) == 100.0 / 21)
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

@Test func C32IdleRateExpiresAfterTenSecondsWithoutResurrectingOnNewWork() throws {
    var m = try monitor("idle-expiry")
    try m.observeUsage(TokenUsage(outputTokens: 100), turnID: "turn", source: .rolloutLog, epoch: "e", at: 5)
    try m.finishTurn("turn", outcome: .completed, at: 6)
    #expect(try m.workAverageRate(at: 15.999) == 20)
    #expect(try m.workAverageRate(at: 16) == nil)
    let expired = try ReportedFrame(monitors: [m], verifiedIndependentThreads: [m.key], at: 16)
    #expect(expired.tokensPerSecond == nil && expired.measuredRuns == 0)
    try m.startTurn("next", at: 20)
    #expect(try m.workAverageRate(at: 21) == nil)
    try m.observeUsage(TokenUsage(outputTokens: 150), turnID: "next", source: .rolloutLog, epoch: "e", at: 25)
    #expect(try m.workAverageRate(at: 60) == 10)
}

@Test func C20CodexWindowsKeepSessionAndWeeklyApart() {
    let line = #"{"payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":12.0,"window_minutes":300,"resets_at":1},"secondary":{"used_percent":39.5,"window_minutes":10080,"resets_at":1792909120}}}}"#
    let windows = QuotaParser.codexWindows(rolloutLine: line)
    #expect(windows.map(\.windowMinutes) == [300, 10080] && windows.map(\.isWeekly) == [false, true])
    #expect(windows[1].remainingPercent == 60.5 && windows[1].resetsAt == Date(timeIntervalSince1970: 1792909120))
    #expect(QuotaParser.codexWindows(rolloutLine: "not json rate_limits").isEmpty)
}

@Test func C21ClaudeWindowsReadFiveHourAndSevenDay() {
    let body = Data(#"{"five_hour":{"utilization":3,"resets_at":"2026-10-22T09:59:00Z"},"seven_day":{"utilization":42.5,"resets_at":"2026-10-25T03:00:00.123456+00:00"}}"#.utf8)
    let windows = QuotaParser.claudeWindows(usageJSON: body)
    #expect(windows.map(\.windowMinutes) == [300, 10080] && windows.map(\.usedPercent) == [3, 42.5])
    #expect(windows.allSatisfy { $0.resetsAt != nil })
    #expect(QuotaParser.claudeWindows(usageJSON: Data(#"{"seven_day":{}}"#.utf8)).isEmpty)
}

@Test func C29ClaudeModelScopedWeeklyLimitIsKeptApartFromThePlanWindows() {
    let body = Data(#"{"five_hour":{"utilization":15,"resets_at":null},"seven_day":{"utilization":2,"resets_at":null},"limits":[{"kind":"session","percent":15},{"kind":"weekly_all","percent":2},{"kind":"weekly_scoped","percent":7,"resets_at":"2026-10-29T10:00:00+00:00","scope":{"model":{"id":null,"display_name":"Fable"}}},{"kind":"weekly_scoped","percent":9,"scope":{"model":{"display_name":""}}},{"kind":"weekly_scoped","percent":9,"scope":null}]}"#.utf8)
    let windows = QuotaParser.claudeWindows(usageJSON: body)
    #expect(windows.map(\.scope) == [nil, nil, "Fable"])
    #expect(windows.last?.usedPercent == 7 && windows.last?.isWeekly == true && windows.last?.resetsAt != nil)
}

@Test func C22QuotaIsClampedAndExpiresAfterReset() {
    let now = Date(timeIntervalSince1970: 1000)
    #expect(ProviderQuota(provider: .codex, usedPercent: 130, resetsAt: nil).remainingPercent == 0)
    #expect(ProviderQuota(provider: .codex, usedPercent: .nan, resetsAt: nil).usedPercent == 0)
    #expect(!ProviderQuota(provider: .codex, usedPercent: 10, resetsAt: Date(timeIntervalSince1970: 999)).isCurrent(at: now))
    #expect(ProviderQuota(provider: .codex, usedPercent: 10, resetsAt: Date(timeIntervalSince1970: 1001)).isCurrent(at: now))
}

@Test func C24ModelCatalogGivesEachModelsInputWindowAndIgnoresMalformedEntries() {
    let catalog = Data(#"""
    {"version":2,"catalog":{"surface":"cc","config":{"models":[
      {"id":"claude-opus-5-5","runtime":{"max_input_tokens":1000000,"max_output_tokens":128000}},
      {"id":"claude-haiku-4-5-20251001","runtime":{"max_input_tokens":200000}},
      {"id":"no-runtime"},
      {"id":"negative","runtime":{"max_input_tokens":-5}},
      {"id":"text","runtime":{"max_input_tokens":"1000000"}},
      {"runtime":{"max_input_tokens":123}}
    ]}}}
    """#.utf8)
    #expect(ModelContext.windows(fromCatalog: catalog) == ["claude-opus-5-5": 1_000_000, "claude-haiku-4-5-20251001": 200_000])
    #expect(ModelContext.windows(fromCatalog: Data("not json".utf8)).isEmpty)
}

@Test func C25CodexCreditsComeFromTheRateLimitsOfTheLog() {
    func line(_ credits: String) -> String { #"{"payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":100.0,"window_minutes":10080,"resets_at":1},"credits":"# + credits + "}}}" }
    let real = QuotaParser.codexCredits(rolloutLine: line(#"{"has_credits":true,"unlimited":false,"balance":"61949.2565750000"}"#))
    #expect(real?.provider == .codex && real?.unit == .credits && real?.unlimited == false)
    #expect(real?.remaining == 61949.256575)
    #expect(QuotaParser.codexCredits(rolloutLine: line(#"{"has_credits":true,"unlimited":false,"balance":12.5}"#))?.remaining == 12.5)      // a plain number works too
    #expect(QuotaParser.codexCredits(rolloutLine: line(#"{"has_credits":true,"unlimited":true,"balance":"0"}"#))?.unlimited == true)
    #expect(QuotaParser.codexCredits(rolloutLine: line(#"{"has_credits":false,"unlimited":false,"balance":"0"}"#)) == nil)        // no credits on this account
    #expect(QuotaParser.codexCredits(rolloutLine: line(#"{"has_credits":true,"unlimited":false,"balance":"-5"}"#)) == nil)
    #expect(QuotaParser.codexCredits(rolloutLine: line(#"{"has_credits":true,"unlimited":false,"balance":"abc"}"#)) == nil)
    #expect(QuotaParser.codexCredits(rolloutLine: line("null")) == nil)
    #expect(QuotaParser.codexCredits(rolloutLine: "not json rate_limits") == nil)
}

@Test func C26ClaudeCreditsComeFromTheSpendOrTheLegacyExtraUsageOfTheUsageResponse() {
    func credits(_ json: String) -> ProviderCredits? { QuotaParser.claudeCredits(usageJSON: Data(json.utf8)) }
    // Usage credits that cover a plan limit: the spend cap minus what was used.
    let capped = credits(#"{"spend":{"enabled":true,"used":{"amount_minor":300,"currency":"USD","exponent":2},"limit":{"amount_minor":2000,"currency":"USD","exponent":2},"balance":null}}"#)
    #expect(capped?.provider == .claude && capped?.unit == .currency("USD") && capped?.remaining == 17)
    // A prepaid balance wins over the cap, as a money object or a plain number.
    #expect(credits(#"{"spend":{"enabled":true,"used":{"amount_minor":0,"currency":"EUR","exponent":2},"balance":{"amount_minor":1234,"currency":"EUR","exponent":2}}}"#)?.remaining == 12.34)
    #expect(credits(#"{"spend":{"enabled":true,"balance":7.5}}"#)?.remaining == 7.5)
    // Older responses only send extra_usage, in minor units.
    #expect(credits(#"{"extra_usage":{"is_enabled":true,"monthly_limit":2000,"used_credits":300,"currency":"USD","decimal_places":2}}"#)?.remaining == 17)
    // This account's real answer: credits are not enabled, so there is nothing to show.
    #expect(credits(#"{"spend":{"enabled":false,"used":{"amount_minor":0,"currency":"USD","exponent":2},"limit":null,"balance":null},"extra_usage":{"is_enabled":false,"monthly_limit":null,"used_credits":null}}"#) == nil)
    #expect(credits(#"{"spend":{"enabled":true,"used":{"amount_minor":5,"currency":"USD","exponent":2}}}"#) == nil)            // neither a cap nor a balance
    #expect(credits(#"{"spend":{"enabled":true,"limit":{"amount_minor":100,"exponent":2},"used":{"amount_minor":900,"exponent":2}}}"#)?.remaining == 0)   // overspent never goes negative
    #expect(credits("not json") == nil)
}

private func controlPath() -> String { "/tmp/tokloom-\(UUID().uuidString.prefix(8)).sock" }

/// A client that sends raw bytes and reads one reply line; nil when the server hangs up first.
private func controlExchange(_ path: String, send: Data, lines: Int = 1) -> Data? {
    let client = socket(AF_UNIX, SOCK_STREAM, 0)
    defer { close(client) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else { return nil }
    var noSignal: Int32 = 1
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    _ = send.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
    var received = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while received.filter({ $0 == 10 }).count < lines {
        let count = read(client, &chunk, chunk.count)
        guard count > 0 else { return nil }
        received.append(contentsOf: chunk[..<count])
    }
    return received
}

@Test func CS01ControlSocketAnswersEveryLineOfOneConnectionInOrder() throws {
    let path = controlPath()
    let server = try ControlServer(path: path) { line in Data("echo:".utf8) + line }
    defer { server.stop() }
    #expect(controlExchange(path, send: Data("a\n".utf8)) == Data("echo:a\n".utf8))
    #expect(controlExchange(path, send: Data("a\nb\n".utf8), lines: 2) == Data("echo:a\necho:b\n".utf8))
}

@Test func CS02ControlSocketIsPrivateAndGoesAwayWhenStopped() throws {
    let path = controlPath()
    let server = try ControlServer(path: path) { $0 }
    var info = stat()
    #expect(lstat(path, &info) == 0)
    #expect(info.st_mode & 0o777 == 0o600)
    server.stop()
    #expect(lstat(path, &info) != 0)
}

@Test func CS03ControlSocketRefusesARunningServerAndAnythingThatIsNotItsOwn() throws {
    let path = controlPath()
    let first = try ControlServer(path: path) { $0 }
    defer { first.stop() }
    #expect(throws: ControlServerError.inUse) { try ControlServer(path: path) { $0 } }
    #expect(controlExchange(path, send: Data("still\n".utf8)) == Data("still\n".utf8))
    let file = controlPath()
    #expect(FileManager.default.createFile(atPath: file, contents: Data("keep".utf8)))
    defer { unlink(file) }
    #expect(throws: ControlServerError.unsafePath) { try ControlServer(path: file) { $0 } }
    #expect(FileManager.default.contents(atPath: file) == Data("keep".utf8))
    #expect(throws: ControlServerError.pathTooLong) { try ControlServer(path: "/tmp/" + String(repeating: "x", count: 200)) { $0 } }
}

@Test func CS04ControlSocketReplacesTheFileACrashLeftBehind() throws {
    let path = controlPath()
    let stale = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(stale, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    #expect(bound == 0)
    close(stale)       // the file stays with nobody listening
    let server = try ControlServer(path: path) { $0 }
    defer { server.stop() }
    #expect(controlExchange(path, send: Data("new\n".utf8)) == Data("new\n".utf8))
}

@Test func CS05ControlSocketHangsUpOnAnOversizedRequestAndKeepsServing() throws {
    let path = controlPath()
    let server = try ControlServer(path: path) { $0 }
    defer { server.stop() }
    #expect(controlExchange(path, send: Data(repeating: 65, count: ControlServer.maximumRequestBytes + 2) + [10]) == nil)
    #expect(controlExchange(path, send: Data("small\n".utf8)) == Data("small\n".utf8))
}

@Test func CS07ControlClientGetsOneReplyAndKnowsWhenNothingListens() throws {
    let path = controlPath()
    #expect(throws: ControlServerError.notRunning) { try ControlClient.exchange(path: path, line: Data("a".utf8)) }
    let server = try ControlServer(path: path) { Data(repeating: 66, count: 300_000) + $0 }
    defer { server.stop() }
    #expect(try ControlClient.exchange(path: path, line: Data("a".utf8)) == Data(repeating: 66, count: 300_000) + Data("a".utf8))
}

@Test func CS06ControlSocketDropsAnIdleClientAndFreesItsSlot() async throws {
    let path = controlPath()
    let server = try ControlServer(path: path, idleSeconds: 1) { $0 }
    defer { server.stop() }
    let held = (0..<ControlServer.maximumConnections).map { _ -> Int32 in
        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        return client
    }
    defer { held.forEach { close($0) } }
    try await Task.sleep(for: .milliseconds(200))
    #expect(controlExchange(path, send: Data("full\n".utf8)) == nil)
    try await Task.sleep(for: .seconds(2))
    #expect(controlExchange(path, send: Data("free\n".utf8)) == Data("free\n".utf8))
}
