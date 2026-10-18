import Foundation
import Darwin
import Testing
@testable import CodexHubCollector
import CSQLite
import CryptoKit

@Test func S201InitialIndexNeverInventsCurrentActivity() async throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("home/sessions"), withIntermediateDirectories: true)
    let log = root.appendingPathComponent("home/sessions/a.jsonl")
    let content = """
    {"type":"session_meta","payload":{"id":"session-a","cwd":"/project"}}
    {"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-a"}}
    {"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"output_tokens":10000}}}}
    
    """
    try Data(content.utf8).write(to: log)
    let collector = try LogCollector(codexHome: root.appendingPathComponent("home"), metadataDirectory: root.appendingPathComponent("metadata"))
    let snapshot = try await collector.refresh()
    #expect(snapshot.sessions.count == 1)
    #expect(snapshot.sessions.first?.monitor.activity == .unknown)
    #expect(snapshot.sessions.first?.monitor.counter.baseline?.outputTokens == 10_000)
}

private final class Sandbox {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var home: URL { root.appendingPathComponent("home") }
    var metadata: URL { root.appendingPathComponent("metadata") }
    var log: URL { home.appendingPathComponent("sessions/a.jsonl") }
    init() throws { try FileManager.default.createDirectory(at: home.appendingPathComponent("sessions"), withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: root) }
    func collector() throws -> LogCollector { try LogCollector(codexHome: home, metadataDirectory: metadata, monotonic: { 100 }) }
    func write(_ text: String) throws { try Data(text.utf8).write(to: log) }
    func append(_ text: String) throws { try append(Data(text.utf8)) }
    func append(_ bytes: Data) throws {
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: bytes)
    }
}
private let meta = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"session-a\",\"cwd\":\"/project\"}}\n"
private func start(_ id: String) -> String { "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"\(id)\"}}\n" }
private func complete(_ id: String) -> String { "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"\(id)\",\"last_agent_message\":\"PRIVATE_SENTINEL\"}}\n" }
private func usage(_ n: Int) -> String { "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"output_tokens\":\(n)},\"last_token_usage\":{\"output_tokens\":999999}}}}\n" }

@Test func S202AppendLifecycleDuplicatesAndLateUsage() async throws {
    let s = try Sandbox(); try s.write(meta + usage(100))
    let c = try s.collector(); _ = try await c.refresh()
    try s.append(start("next") + usage(200) + usage(200))
    let active = try await c.refresh()
    #expect(active.sessions[0].monitor.activity == .working)
    #expect(try active.sessions[0].monitor.reportedRate(at: 100) == 10)
    try s.append(complete("next") + usage(250))
    let done = try await c.refresh()
    #expect(done.sessions[0].monitor.activity == .idle)
    #expect(done.sessions[0].monitor.turns["next"]?.outputTokens == 150)
    #expect(try done.sessions[0].monitor.reportedRate(at: 100) == nil)
}

@Test func S203PartialUTF8AndNewlineCheckpoint() async throws {
    let s = try Sandbox(); try s.write(meta + usage(10))
    let c = try s.collector(); _ = try await c.refresh()
    let text = Data("{\"type\":\"turn_context\",\"payload\":{\"turn_id\":\"t\",\"model\":\"모델\"}}\n".utf8)
    let split = try #require(text.firstIndex(of: 0xEB)) + 1
    try s.append(Data(text[..<split]))
    let partial = try await c.refresh()
    #expect(partial.sessions[0].model == nil)
    try s.append(Data(text[split...]))
    let whole = try await c.refresh()
    #expect(whole.sessions[0].model == "모델")
    #expect(whole.diagnostics.isEmpty)
}

@Test func S204MalformedNullAndMissingTurnAreIsolated() async throws {
    let s = try Sandbox(); try s.write(meta + "bad-json\n" + "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":null}}\n" + usage(90))
    let c = try s.collector()
    let result = try await c.refresh()
    #expect(result.sessions[0].monitor.counter.baseline?.outputTokens == 90)
    #expect(result.sessions[0].monitor.activity == .unknown)
    #expect(result.sessions[0].monitor.turns.isEmpty)
    #expect(result.diagnostics.contains { $0.error == .invalidRecord })
}

private final class CollectorBox: @unchecked Sendable { var collector: LogCollector? }

@Test func S250NewCollectorWaitsBrieflyForThePreviousOneToReleaseTheMetadataLock() async throws {
    let s = try Sandbox(); try s.write(meta + usage(100))
    let box = CollectorBox()
    box.collector = try s.collector()
    // Releasing an actor is not synchronous with dropping the last reference, so a restart may race the old lock.
    Task.detached { try? await Task.sleep(for: .milliseconds(150)); box.collector = nil }
    let next = try s.collector()
    #expect(try await next.refresh().sessions.count == 1)
}

@Test func S205RestartRestoresCheckpointWithoutLiveReplay() async throws {
    let s = try Sandbox(); try s.write(meta + start("old") + usage(100))
    var c: LogCollector? = try s.collector()
    _ = try await c?.refresh()
    c = nil
    try s.append(usage(200) + complete("old"))
    let next = try s.collector()
    let restored = try await next.refresh()
    #expect(restored.sessions[0].monitor.counter.baseline?.outputTokens == 200)
    #expect(restored.sessions[0].monitor.activity == .unknown)
    #expect(try restored.sessions[0].monitor.reportedRate(at: 100) == nil)
    try s.append(start("fresh") + usage(250))
    let fresh = try await next.refresh()
    #expect(try fresh.sessions[0].monitor.reportedRate(at: 100) == 5)
}

@Test func S206TruncateRotationAndMoveRemainHistorical() async throws {
    let s = try Sandbox(); try s.write(meta + start("old") + usage(1000))
    let c = try s.collector(); _ = try await c.refresh()
    try s.write(meta + usage(1))
    let truncated = try await c.refresh()
    #expect(truncated.sessions[0].hasGap)
    #expect(truncated.sessions[0].monitor.counter.baseline?.outputTokens == 1)
    let moved = s.log.deletingLastPathComponent().appendingPathComponent("moved.jsonl")
    try FileManager.default.moveItem(at: s.log, to: moved)
    let renamed = try await c.refresh()
    #expect(renamed.sessions.count == 1)
    try Data((meta + usage(400)).utf8).write(to: s.log)
    let rotated = try await c.refresh()
    #expect(rotated.sessions.allSatisfy { $0.monitor.activity == .unknown })
}

@Test func S207DatabaseFailureDoesNotAdvancePublishedState() async throws {
    let s = try Sandbox(); try s.write(meta + usage(100))
    let c = try s.collector(); _ = try await c.refresh()
    try s.append(start("live") + usage(200))
    try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: s.metadata.path)
    do { _ = try await c.refresh(); Issue.record("Expected unsafe metadata failure") } catch {}
    let unchanged = await c.snapshot()
    #expect(unchanged.sessions[0].monitor.counter.baseline?.outputTokens == 100)
    #expect(unchanged.diagnostics.contains { $0.error == .database })
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: s.metadata.path)
    let retry = try await c.refresh()
    #expect(try retry.sessions[0].monitor.reportedRate(at: 100) == 10)
}

@Test func S208RawTextNeverPersistsAndSourcesRemainUnchanged() async throws {
    let s = try Sandbox()
    let original = meta + start("old") + usage(100) + complete("old") + "{\"type\":\"response_item\",\"payload\":{\"body\":\"PRIVATE_SENTINEL\",\"auth\":\"PRIVATE_SENTINEL\"}}\n"
    try s.write(original)
    let c = try s.collector(); _ = try await c.refresh()
    #expect(try String(contentsOf: s.log, encoding: .utf8) == original)
    for name in try FileManager.default.contentsOfDirectory(atPath: s.metadata.path) {
        let bytes = try Data(contentsOf: s.metadata.appendingPathComponent(name))
        #expect(bytes.range(of: Data("PRIVATE_SENTINEL".utf8)) == nil)
        let attributes = try FileManager.default.attributesOfItem(atPath: s.metadata.appendingPathComponent(name).path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
}

@Test func S209ReadOnlyHardlinksAreAcceptedButSymlinksAreRejected() async throws {
    let s = try Sandbox(); try s.write(meta + usage(10))
    let outside = s.root.appendingPathComponent("outside.jsonl")
    try Data((meta.replacingOccurrences(of: "session-a", with: "session-b") + usage(999)).utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(at: s.home.appendingPathComponent("sessions/link.jsonl"), withDestinationURL: outside)
    try FileManager.default.linkItem(at: outside, to: s.home.appendingPathComponent("sessions/hard.jsonl"))
    let c = try s.collector()
    let result = try await c.refresh()
    #expect(result.sessions.count == 2)
    #expect(result.sessions.first { $0.monitor.key.threadID == "session-b" }?.monitor.counter.baseline?.outputTokens == 999)
    #expect(result.diagnostics.contains { $0.error == .unsafePath })
    #expect(try String(contentsOf: outside, encoding: .utf8) == meta.replacingOccurrences(of: "session-a", with: "session-b") + usage(999))
    let bad = s.root.appendingPathComponent("metadata-link")
    try FileManager.default.createSymbolicLink(at: bad, withDestinationURL: s.metadata)
    #expect(throws: (any Error).self) { _ = try LogCollector(codexHome: s.home, metadataDirectory: bad) }
}

@Test func S210RetentionClearAndIndependentSessions() async throws {
    let s = try Sandbox(); try s.write(meta + usage(100))
    try Data((meta.replacingOccurrences(of: "session-a", with: "session-b") + usage(200)).utf8).write(to: s.home.appendingPathComponent("sessions/b.jsonl"))
    let c = try s.collector()
    let initial = try await c.refresh()
    #expect(initial.sessions.count == 2)
    try await c.updateRetention(RetentionPolicy(days: 7, maximumSessions: 1))
    #expect(await c.snapshot().sessions.count == 1)
    try await c.clearMetadata()
    #expect(await c.snapshot().sessions.isEmpty)
    #expect(FileManager.default.fileExists(atPath: s.log.path))
    #expect(throws: (any Error).self) { _ = try RetentionPolicy(days: 0) }
}

@Test func S211OversizedAndInvalidCountersDoNotBlockOtherFiles() async throws {
    let s = try Sandbox(); try s.write(meta + usage(10))
    let bad = s.home.appendingPathComponent("sessions/bad.jsonl")
    try Data(String(repeating: "x", count: 300_000).utf8).write(to: bad)
    let c = try s.collector()
    let first = try await c.refresh()
    #expect(first.sessions.count == 1)
    #expect(first.diagnostics.contains { $0.error == .oversizedRecord })
    try s.append(start("live") + usage(-10))
    let invalid = try await c.refresh()
    #expect(invalid.sessions[0].monitor.counter.baseline?.outputTokens == 10)
    #expect(invalid.diagnostics.contains { $0.error == .invalidRecord })
}

@Test func S212SleepGapDropsQueuedHistoryAndMissingRootDisconnects() async throws {
    let s = try Sandbox(); try s.write(meta + usage(10))
    let c = try s.collector(); _ = try await c.refresh()
    try s.append(start("live") + usage(20)); _ = try await c.refresh()
    try await c.markGap()
    try s.append(usage(1000))
    let resumed = try await c.refresh()
    #expect(try resumed.sessions[0].monitor.reportedRate(at: 100) == nil)
    let moved = s.home.appendingPathComponent("gone")
    try FileManager.default.moveItem(at: s.home.appendingPathComponent("sessions"), to: moved)
    let missing = try await c.refresh()
    #expect(missing.diagnostics.contains { $0.error == .inaccessibleSource })
    #expect(missing.sessions[0].monitor.connectivity == .disconnected)
    #expect(try missing.sessions[0].monitor.reportedRate(at: 100) == nil)
}

@Test func S213MetadataBoundaryAndExclusiveOwner() async throws {
    let s = try Sandbox(); try s.write(meta)
    #expect(throws: (any Error).self) { _ = try LogCollector(codexHome: s.home, metadataDirectory: s.home.appendingPathComponent("hub")) }
    let c = try s.collector()
    #expect(throws: (any Error).self) { _ = try s.collector() }
    _ = try await c.refresh()
    let target = s.root.appendingPathComponent("unrelated")
    try Data("KEEP".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: s.metadata.appendingPathComponent("metadata.sqlite-journal"), withDestinationURL: target)
    do { try await c.clearMetadata(); Issue.record("Expected journal link rejection") } catch {}
    #expect(try String(contentsOf: target, encoding: .utf8) == "KEEP")
}

@Test func S214ExpiredFilesAndSameLengthRewrite() async throws {
    let s = try Sandbox(); try s.write(meta + usage(100))
    let c = try s.collector(); _ = try await c.refresh()
    try s.write(meta + usage(200))
    let rewritten = try await c.refresh()
    #expect(rewritten.sessions[0].hasGap)
    #expect(rewritten.sessions[0].monitor.counter.baseline?.outputTokens == 200)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -9 * 86400)], ofItemAtPath: s.log.path)
    // Updating retention uses the stored last-observation time; refresh must notice source expiry.
    let expired = try await c.refresh()
    #expect(expired.sessions.isEmpty)
}

@Test func S215RegressionRemainsPartialAcrossRestart() async throws {
    let s = try Sandbox(); try s.write(meta + start("old") + usage(100))
    var c: LogCollector? = try s.collector(); _ = try await c?.refresh()
    try s.append(usage(50)); let partial = try await c?.refresh()
    #expect(partial?.sessions[0].monitor.measurement == .partial)
    c = nil
    let restored = try s.collector()
    let snapshot = try await restored.refresh()
    #expect(snapshot.sessions[0].monitor.measurement == .partial)
    #expect(snapshot.sessions[0].monitor.turns.isEmpty)
}

@Test func S216ReplacedDatabaseDoesNotPublishNewCheckpoint() async throws {
    let s = try Sandbox(); try s.write(meta + usage(10))
    let c = try s.collector(); _ = try await c.refresh()
    try FileManager.default.moveItem(at: s.metadata.appendingPathComponent("metadata.sqlite"), to: s.metadata.appendingPathComponent("old.sqlite"))
    try Data().write(to: s.metadata.appendingPathComponent("metadata.sqlite"))
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: s.metadata.appendingPathComponent("metadata.sqlite").path)
    try s.append(usage(20))
    do { _ = try await c.refresh(); Issue.record("Expected replaced database rejection") } catch {}
    #expect(await c.snapshot().sessions[0].monitor.counter.baseline?.outputTokens == 10)
}

@Test func S217InvalidNumericTypesAndUnknownRecords() async throws {
    let s = try Sandbox(); try s.write(meta + usage(100))
    let c = try s.collector(); _ = try await c.refresh()
    for value in ["true", "1.5", "-1", "9223372036854775808", "null"] {
        try s.append("{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"output_tokens\":\(value)}}}}\n")
    }
    try s.append("{\"type\":\"future_type\",\"payload\":{\"text\":\"PRIVATE_SENTINEL\"}}\n")
    let result = try await c.refresh()
    #expect(result.sessions[0].monitor.counter.baseline?.outputTokens == 100)
    #expect(result.diagnostics.filter { $0.error == .invalidRecord }.count == 5)
}

@Test func S218StartStopAreIdempotent() async throws {
    let s = try Sandbox(); try s.write(meta + usage(10))
    let c = try s.collector()
    await c.start(); await c.start()
    let deadline = ContinuousClock.now + .seconds(2)
    while await c.snapshot().sessions.isEmpty && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    await c.stop(); await c.stop()
    #expect(await c.snapshot().sessions.count == 1)
}

@Test func S219DuplicateSessionFilesCannotDoubleCount() async throws {
    let s = try Sandbox(); try s.write(meta + usage(100))
    try Data((meta + usage(100)).utf8).write(to: s.home.appendingPathComponent("sessions/copy.jsonl"))
    let c = try s.collector()
    let snapshot = try await c.refresh()
    #expect(snapshot.sessions.count == 1)
    #expect(snapshot.sessions[0].monitor.connectivity == .degraded)
    #expect(snapshot.sessions[0].hasGap)
    #expect(snapshot.diagnostics.contains { $0.error == .ambiguousSource })
}

@Test func S220NewTurnAfterMissedCompletionMarksGap() async throws {
    let s = try Sandbox(); try s.write(meta + usage(100))
    let c = try s.collector(); _ = try await c.refresh()
    try s.append(start("one") + usage(150)); _ = try await c.refresh()
    try s.append(start("two") + usage(200))
    let result = try await c.refresh()
    #expect(result.sessions[0].monitor.activeTurnID == "two")
    #expect(result.sessions[0].hasGap)
    #expect(try result.sessions[0].monitor.reportedRate(at: 100) == nil)
}

@Test func S221PrivateMetadataHardlinkIsRejectedWithoutPublishing() async throws {
    let s = try Sandbox(); try s.write(meta + usage(10))
    let c = try s.collector(); _ = try await c.refresh()
    let database = s.metadata.appendingPathComponent("metadata.sqlite")
    let alias = s.root.appendingPathComponent("metadata-alias")
    try FileManager.default.linkItem(at: database, to: alias)
    let original = try Data(contentsOf: alias)
    try s.append(start("live") + usage(20))
    do { _ = try await c.refresh(); Issue.record("Expected private metadata hardlink rejection") } catch {}
    #expect(await c.snapshot().sessions[0].monitor.counter.baseline?.outputTokens == 10)
    #expect(try Data(contentsOf: alias) == original)
}

@Test func S222ReadOnlyHardlinkAliasesDoNotDoubleCount() async throws {
    let s = try Sandbox(); try s.write(meta + usage(10))
    try FileManager.default.linkItem(at: s.log, to: s.home.appendingPathComponent("sessions/alias.jsonl"))
    let c = try s.collector()
    let initial = try await c.refresh()
    #expect(initial.sessions.count == 1)
    #expect(initial.diagnostics.isEmpty)
    try s.append(start("live") + usage(30))
    let next = try await c.refresh()
    #expect(next.sessions.count == 1)
    #expect(next.diagnostics.isEmpty)
    #expect(try next.sessions[0].monitor.reportedRate(at: 100) == 2)
}

@Test func S224ReportedProcessDetailsPersistAndQuotaOnlyEventsUpdate() async throws {
    let s = try Sandbox()
    try s.write(meta.replacingOccurrences(of: "\"cwd\"", with: "\"source\":\"cli\",\"cwd\"") + """
    {"type":"turn_context","payload":{"turn_id":"t","model":"gpt-6.1-sol","effort":"high","service_tier":"ultrafast"}}
    {"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":500,"output_tokens":100},"last_token_usage":{"total_tokens":600},"model_context_window":1000},"rate_limits":{"primary":{"used_percent":21.0,"window_minutes":10080,"resets_at":1800000000},"secondary":null}}}

    """)
    var c: LogCollector? = try s.collector()
    let first = try #require(try await c?.refresh().sessions.first)
    #expect(first.model == "gpt-6.1-sol")
    #expect(first.usageDetails?.reasoningEffort == "high")
    #expect(first.usageDetails?.serviceTier == .ultrafast)
    #expect(first.usageDetails?.contextTokens == 600)
    #expect(first.usageDetails?.contextWindow == 1000)
    #expect(first.usageDetails?.limits?.first?.remainingPercent == 79)
    #expect(first.usageDetails?.limits?.first?.windowMinutes == 10080)
    #expect(first.monitor.counter.baseline?.inputTokens == 500)
    #expect(first.monitor.counter.baseline?.outputTokens == 100)
    try s.append("{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":null,\"rate_limits\":{\"primary\":{\"used_percent\":25.5,\"window_minutes\":300}}}}\n")
    let updated = try #require(try await c?.refresh().sessions.first)
    #expect(updated.usageDetails?.limits?.first?.remainingPercent == 74.5)
    #expect(updated.usageDetails?.contextTokens == 600)
    #expect(updated.monitor.counter.baseline?.outputTokens == 100)
    c = nil
    let restored = try s.collector()
    let result = try await restored.refresh()
    #expect(result.sessions[0].usageDetails?.reasoningEffort == "high")
    #expect(result.sessions[0].usageDetails?.limits?.first?.remainingPercent == 74.5)
}

@Test func S225MalformedProcessDetailsStayUnavailableWithoutInventingUsage() async throws {
    let s = try Sandbox()
    try s.write(meta + """
    {"type":"turn_context","payload":{"turn_id":"t","effort":true}}
    {"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"output_tokens":10},"last_token_usage":{"total_tokens":true},"model_context_window":-1},"rate_limits":{"primary":{"used_percent":true},"secondary":{"used_percent":101}}}}

    """)
    let c = try s.collector()
    let snapshot = try await c.refresh()
    let details = try #require(snapshot.sessions.first?.usageDetails)
    #expect(details.reasoningEffort == nil)
    #expect(details.serviceTier == nil)
    #expect(details.contextTokens == nil)
    #expect(details.contextWindow == nil)
    #expect(details.limits?.isEmpty == true)
    #expect(snapshot.sessions[0].monitor.counter.baseline?.outputTokens == 10)
}

@Test func S226LegacyCheckpointBackfillsDetailsWithoutReplayingUsageOrActivity() async throws {
    let s = try Sandbox()
    try s.write(meta + """
    {"type":"turn_context","payload":{"turn_id":"t","model":"gpt-6.1-sol","effort":"high"}}
    {"type":"event_msg","payload":{"type":"task_started","turn_id":"t"}}
    {"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"output_tokens":100},"last_token_usage":{"total_tokens":300},"model_context_window":1000}}}

    """)
    var c: LogCollector? = try s.collector(); _ = try await c?.refresh(); c = nil
    var database: OpaquePointer?
    #expect(sqlite3_open(s.metadata.appendingPathComponent("metadata.sqlite").path, &database) == SQLITE_OK)
    defer { sqlite3_close(database) }
    var query: OpaquePointer?
    #expect(sqlite3_prepare_v2(database, "SELECT state FROM files", -1, &query, nil) == SQLITE_OK)
    #expect(sqlite3_step(query) == SQLITE_ROW)
    let bytes = try #require(sqlite3_column_blob(query, 0))
    var legacy = try #require(JSONSerialization.jsonObject(with: Data(bytes: bytes, count: Int(sqlite3_column_bytes(query, 0)))) as? [String: Any])
    sqlite3_finalize(query)
    legacy.removeValue(forKey: "usageDetails")
    let hex = try JSONSerialization.data(withJSONObject: legacy).map { String(format: "%02x", $0) }.joined()
    #expect(sqlite3_exec(database, "UPDATE files SET state=X'\(hex)'", nil, nil, nil) == SQLITE_OK)
    sqlite3_close(database); database = nil
    let restored = try s.collector()
    let snapshot = try await restored.refresh()
    #expect(snapshot.sessions[0].usageDetails?.reasoningEffort == "high")
    #expect(snapshot.sessions[0].usageDetails?.contextTokens == 300)
    #expect(snapshot.sessions[0].monitor.counter.baseline?.outputTokens == 100)
    #expect(snapshot.sessions[0].monitor.activity == .unknown)
    #expect(try snapshot.sessions[0].monitor.reportedRate(at: 100) == nil)
}

@Test func S227VerifiedRunningTurnResumesWithoutHistoricalThroughput() async throws {
    let s = try Sandbox(); try s.write(meta + start("old") + usage(100) + usage(150))
    let c = try s.collector(); let initial = try await c.refresh()
    #expect(initial.sessions[0].monitor.activity == .unknown)
    let bound = try await c.bindRunningSessions([initial.sessions[0].id])
    #expect(bound.sessions[0].monitor.activity == .working)
    #expect(try bound.sessions[0].monitor.reportedRate(at: 100) == nil)
    try s.append(usage(200)); _ = try await c.refresh()
    try s.append(usage(230)); let measured = try await c.refresh()
    #expect(try measured.sessions[0].monitor.reportedRate(at: 100) == 3)
    #expect(try measured.sessions[0].monitor.workAverageRate(at: 110) == nil)
    #expect(measured.sessions[0].monitor.workAverageIsPartial)
    #expect(measured.sessions[0].monitor.turns["old"]?.average == nil)
    let repeatBinding = try await c.bindRunningSessions([initial.sessions[0].id])
    #expect(try repeatBinding.sessions[0].monitor.reportedRate(at: 100) == 3)
}

@Test func S228OnlyVerifiedRunningCompletedSessionRestoresIdle() async throws {
    let s = try Sandbox(); try s.write(meta + start("old") + usage(100) + complete("old"))
    let c = try s.collector(); let initial = try await c.refresh()
    let unbound = try await c.bindRunningSessions([])
    #expect(unbound.sessions[0].monitor.activity == .unknown)
    let bound = try await c.bindRunningSessions([initial.sessions[0].id])
    #expect(bound.sessions[0].monitor.activity == .idle)
    #expect(try bound.sessions[0].monitor.reportedRate(at: 100) == nil)
}

@Test func S230LateCompletionDoesNotRestoreIdleForANewerRunningTurn() async throws {
    let s = try Sandbox(); try s.write(meta + usage(100))
    let c = try s.collector(); _ = try await c.refresh()
    try s.append(start("first") + usage(150) + complete("first")); _ = try await c.refresh()
    try s.append(start("second") + usage(200)); _ = try await c.refresh()
    try s.append(complete("first")); let late = try await c.refresh()
    #expect(late.sessions[0].monitor.activeTurnID == "second")
    try await c.markGap()
    let resumed = try await c.bindRunningSessions([late.sessions[0].id])
    #expect(resumed.sessions[0].monitor.activeTurnID == "second")
    #expect(resumed.sessions[0].monitor.activity == .working)
    #expect(try resumed.sessions[0].monitor.reportedRate(at: 100) == nil)
}

@Test func S231NewTurnContextDoesNotInheritPriorIdleState() async throws {
    let s = try Sandbox()
    try s.write(meta + start("old") + usage(100) + complete("old") + "{\"type\":\"turn_context\",\"payload\":{\"turn_id\":\"new\"}}\n")
    let c = try s.collector(); let initial = try await c.refresh()
    let bound = try await c.bindRunningSessions([initial.sessions[0].id])
    #expect(bound.sessions[0].monitor.activity == .unknown)
    #expect(try bound.sessions[0].monitor.reportedRate(at: 100) == nil)
}

@Test func S232OversizedRolloutRecoversAcrossCheckpointWithoutCatchUp() async throws {
    let s = try Sandbox(); try s.write(meta + usage(10))
    var c: LogCollector? = try s.collector(); _ = try await c?.refresh()
    try s.append(start("live") + "{\"type\":\"compacted\",\"payload\":\"" + String(repeating: "x", count: 1_200_000))
    let skipped = try #require(await c?.refresh())
    #expect(skipped.diagnostics.contains { $0.error == .oversizedRecord })
    c = nil
    let resumed = try s.collector()
    try s.append("\"}\n" + usage(9000))
    let baseline = try await resumed.refresh()
    let recovered = try #require(baseline.sessions.first)
    #expect(recovered.monitor.counter.baseline?.outputTokens == 9000)
    #expect(try recovered.monitor.reportedRate(at: 100) == nil)
    try s.append(start("next") + usage(9030))
    let current = try await resumed.refresh()
    #expect(current.sessions[0].monitor.connectivity == .connected)
    #expect(current.sessions[0].monitor.activity == .working)
    #expect(try current.sessions[0].monitor.reportedRate(at: 100) == 3)
    #expect(current.diagnostics.isEmpty)
}


@Test func S233RequestEstimateExcludesOverlappingToolWaitsUsingLogTimes() async throws {
    let s = try Sandbox(); try s.write(meta + usage(100))
    let c = try s.collector(); _ = try await c.refresh()
    func dated(_ record: String, _ seconds: Int) -> String {
        let timestamp = String(format: "2026-10-17T00:00:%02d.000Z", seconds)
        return record.replacingOccurrences(of: "{", with: "{\"timestamp\":\"" + timestamp + "\",", range: record.startIndex..<record.index(after: record.startIndex))
    }
    func tool(_ id: String, _ output: Bool, _ seconds: Int) -> String {
        dated("{\"type\":\"response_item\",\"payload\":{\"type\":\"" + (output ? "function_call_output" : "function_call") + "\",\"call_id\":\"" + id + "\"}}\n", seconds)
    }
    try s.append(dated(start("live"), 0) + dated(start("live"), 1) + tool("a", false, 2) + tool("a", true, 8) + dated(usage(200), 10))
    let first = try await c.refresh()
    #expect(try first.sessions[0].monitor.workAverageRate(at: 100) == 25)
    #expect(try first.sessions[0].monitor.workAverageRate(at: 200) == 25)
    try s.append(tool("b", false, 11) + tool("c", false, 12) + tool("b", true, 18) + tool("c", true, 19) + dated(usage(240), 20))
    let parallel = try await c.refresh()
    #expect(try parallel.sessions[0].monitor.workAverageRate(at: 100) == 20)
    try s.append(dated(complete("live"), 21))
    let idle = try await c.refresh()
    #expect(idle.sessions[0].monitor.activity == .idle)
    #expect(try idle.sessions[0].monitor.workAverageRate(at: 100) == 20)
    try s.append(dated(usage(280), 40))
    let late = try await c.refresh()
    #expect(try late.sessions[0].monitor.workAverageRate(at: 100) == 40)
}

private func dated(_ record: String, _ seconds: Int) -> String {
    let timestamp = String(format: "2026-10-17T00:00:%02d.000Z", seconds)
    return record.replacingOccurrences(of: "{", with: "{\"timestamp\":\"" + timestamp + "\",", range: record.startIndex..<record.index(after: record.startIndex))
}

/// Writes a Codex tracing log whose only response headers for `session-a` arrived at `second`.
private func writeHeaderLog(_ s: Sandbox, second: Int) throws {
    let epoch = Int(ISO8601DateFormatter().date(from: String(format: "2026-10-17T00:00:%02dZ", second))!.timeIntervalSince1970)
    let body = "session_loop{thread_id=session-a}:try_run_sampling_request{turn_id=live}: version=HTTP/1.1"
    let insert = "INSERT INTO logs(ts, ts_nanos, level, target, feedback_log_body, thread_id) VALUES (\(epoch), 0, 'DEBUG', 'codex_http_client::client', '\(body)', "
    let sql = "CREATE TABLE logs (id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL, ts_nanos INTEGER NOT NULL, level TEXT, target TEXT NOT NULL, feedback_log_body TEXT, thread_id TEXT); "
        + insert + "'session-a'); " + insert + "'other-thread');"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [s.home.appendingPathComponent("logs_2.sqlite").path, sql]
    try process.run(); process.waitUntilExit()
}

@Test func S233bResponseHeadersStartTheGenerationInterval() async throws {
    let s = try Sandbox(); try s.write(meta + usage(100))
    let c = try s.collector(); _ = try await c.refresh()
    try writeHeaderLog(s, second: 6)
    // 100 tokens over 10 s of log time, but the stream only started at second 6.
    try s.append(dated(start("live"), 0) + dated(usage(200), 10))
    let snapshot = try await c.refresh()
    #expect(try snapshot.sessions[0].monitor.workAverageRate(at: 100) == 25)
}

@Test func S233eNoGenerationTimeLeftMeansNoRate() async throws {
    let s = try Sandbox(); try s.write(meta + usage(100))
    let c = try s.collector(); _ = try await c.refresh()
    try writeHeaderLog(s, second: 2)
    func tool(_ output: Bool, _ seconds: Int) -> String {
        dated("{\"type\":\"response_item\",\"payload\":{\"type\":\"" + (output ? "function_call_output" : "function_call") + "\",\"call_id\":\"a\"}}\n", seconds)
    }
    // Headers at 2 s, but a tool ran from 0 to 10 s: nothing is left to divide by.
    try s.append(dated(start("live"), 0) + tool(false, 0) + tool(true, 10) + dated(usage(200), 10))
    let snapshot = try await c.refresh()
    #expect(try snapshot.sessions[0].monitor.workAverageRate(at: 100) == nil)
}

@Test func S233fLogTimeGoingBackwardsLeavesTheLastRateAlone() async throws {
    let s = try Sandbox(); try s.write(meta + usage(100))
    let c = try s.collector(); _ = try await c.refresh()
    try writeHeaderLog(s, second: 6)
    try s.append(dated(start("live"), 0) + dated(usage(200), 10))
    #expect(try await c.refresh().sessions[0].monitor.workAverageRate(at: 100) == 25)
    // A report stamped before the previous one cannot be timed, so it must not produce a new rate.
    try s.append(dated(usage(300), 9))
    #expect(try await c.refresh().sessions[0].monitor.workAverageRate(at: 100) == 25)
}

@Test func S233cHeaderWaitAndToolTimeAreExcludedTogether() throws {
    var timing = RequestTiming(at: 0)
    _ = timing.tool("a", running: true, at: 4)
    _ = timing.tool("a", running: false, at: 8)
    // Headers at 2 s, tool 4-8 s, finished at 10 s: 8 s from the headers minus 4 s of tool time.
    #expect(timing.sample(at: 10, streamStart: 2) == 4)
    // A tool that began before the headers only counts from where it overlaps the response.
    var clipped = RequestTiming(at: 0)
    _ = clipped.tool("b", running: true, at: 1)
    _ = clipped.tool("b", running: false, at: 5)
    #expect(clipped.sample(at: 10, streamStart: 3) == 5)
    var pending = RequestTiming(at: 0)
    _ = pending.tool("c", running: true, at: 6)
    #expect(pending.sample(at: 10, streamStart: 2) == 4)
}

@Test func S233dCheckpointsWithSummedExclusionStillDecode() throws {
    let legacy = Data(#"{"baseline":10,"lastTime":12,"tools":[],"excluded":3,"endedAt":null}"#.utf8)
    var timing = try JSONDecoder().decode(RequestTiming.self, from: legacy)
    #expect(timing.sample(at: 20) == 7)
    let round = try JSONDecoder().decode(RequestTiming.self, from: JSONEncoder().encode(timing))
    #expect(round.baselineTime == 20)
}

@Test func S234MissingTimingNeverFallsBackToWholeTurnDuration() async throws {
    let s = try Sandbox(); try s.write(meta + usage(100))
    let c = try s.collector(); _ = try await c.refresh()
    try s.append(start("live") + usage(200))
    let snapshot = try await c.refresh()
    #expect(try snapshot.sessions[0].monitor.workAverageRate(at: 200) == nil)
}


@Test func S235TimingRejectsBackwardsAndUnmatchedToolBoundaries() {
    var timing = RequestTiming(at: 10)
    #expect(!timing.accepts(9))
    #expect(timing.tool("unknown", running: false, at: 11) == false)
    #expect(timing.tool("old", running: true, at: 9) == false)
    #expect(timing.sample(at: 9) == nil)
    #expect(timing.tool("tool", running: true, at: 12) == true)
    #expect(timing.tool("tool", running: true, at: 13) == false)
    #expect(timing.sample(at: 14) == 2)
    #expect(timing.sample(at: 15) == nil)
    #expect(timing.tool("tool", running: false, at: 16) == true)
    #expect(timing.sample(at: 18) == 2)
}

@Test func S237ChartHistoryPersistsAcrossCollectorRestartAndClearsWithMetadata() async throws {
    let s = try Sandbox(); try s.write(meta + usage(10))
    let original = try Data(contentsOf: s.log)
    let payload = Data("synthetic-chart-checkpoint".utf8)
    var first: LogCollector? = try s.collector()
    #expect(try await first?.loadChartHistory() == nil)
    try await first?.saveChartHistory(payload)
    first = nil
    let restored = try s.collector()
    #expect(try await restored.loadChartHistory() == payload)
    _ = try await restored.refresh()
    #expect(try await restored.loadChartHistory() == payload)
    try await restored.clearMetadata()
    #expect(try await restored.loadChartHistory() == nil)
    #expect(try Data(contentsOf: s.log) == original)
}

@Test func S238LargeRolloutStillIdentifiesSessionWithoutInventingThroughput() async throws {
    let s = try Sandbox()
    try s.write(meta + usage(100))
    let handle = try FileHandle(forWritingTo: s.log)
    try handle.truncate(atOffset: 300 * 1024 * 1024)
    try handle.close()
    let collector = try s.collector()
    let snapshot = try await collector.refresh()
    #expect(snapshot.sessions.count == 1)
    #expect(snapshot.sessions.first?.cwd == "/project")
    #expect(snapshot.sessions.first?.monitor.key.threadID == "session-a")
    #expect(snapshot.sessions.first?.monitor.activity == .unknown)
    if let session = snapshot.sessions.first {
        #expect(try session.monitor.workAverageRate(at: 100) == nil)
    }
    let size = try FileManager.default.attributesOfItem(atPath: s.log.path)[.size] as? NSNumber
    #expect(size?.int64Value == Int64(314_572_800))
}

@Test func S239LargeRolloutCheckpointReloadsAfterRestart() async throws {
    let s = try Sandbox(); try s.write(meta + usage(100))
    let handle = try FileHandle(forWritingTo: s.log)
    try handle.truncate(atOffset: 300 * 1024 * 1024)
    try handle.close()
    var collector: LogCollector? = try s.collector()
    _ = try await collector?.refresh()
    try await collector?.saveChartHistory(Data("retained-chart".utf8))
    collector = nil
    var restored: LogCollector? = try s.collector()
    let snapshot = try #require(try await restored?.refresh())
    #expect(snapshot.sessions.first?.cwd == "/project")
    #expect(try await restored?.loadChartHistory() == Data("retained-chart".utf8))
    restored = nil
    let scope = SHA256.hash(data: Data(s.home.resolvingSymlinksInPath().standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
    var store: MetadataStore? = try MetadataStore(directoryURL: s.metadata, sourceScope: scope)
    var states = try #require(try store?.load())
    let key = try #require(states.keys.first)
    states[key]?.offset = 300 * 1024 * 1024
    try store?.save(states, retention: RetentionPolicy(days: 7, maximumSessions: 1000))
    store = nil
    let finalStore = try MetadataStore(directoryURL: s.metadata, sourceScope: scope)
    #expect(try finalStore.load()[key]?.offset == Int64(314_572_800))
}

@Test func S251StatesOfTheRemovedManagedSourceAreDroppedOnStart() async throws {
    let s = try Sandbox(); try s.write(meta + usage(10))
    let scope = SHA256.hash(data: Data(s.home.resolvingSymlinksInPath().standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
    var store: MetadataStore? = try MetadataStore(directoryURL: s.metadata, sourceScope: scope)
    try store?.save(["direct:fixture": FileState(path: "sessions/run/direct.jsonl", historicalUntil: 10, updated: 1)], retention: RetentionPolicy(days: 7, maximumSessions: 1000))
    store = nil
    var collector: LogCollector? = try s.collector()
    #expect(try await collector?.refresh().sessions.count == 1)
    collector = nil
    let check = try MetadataStore(directoryURL: s.metadata, sourceScope: scope)
    #expect(try check.load()["direct:fixture"] == nil)
}

@Test func S241SubagentParentMetadataPersistsAndLegacyCheckpointRecovers() async throws {
    let s = try Sandbox()
    try s.write(#"{"type":"session_meta","payload":{"id":"child","cwd":"/project","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent","depth":1}}}}}"# + "\n" + usage(100))
    var collector: LogCollector? = try s.collector()
    let first = try #require(try await collector?.refresh())
    #expect(first.sessions.first?.parentThreadID == "parent")
    #expect(first.sessions.first?.observedCLIRoot == false)
    collector = nil
    let scope = SHA256.hash(data: Data(s.home.resolvingSymlinksInPath().standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
    var store: MetadataStore? = try MetadataStore(directoryURL: s.metadata, sourceScope: scope)
    var states = try #require(try store?.load())
    #expect(states.values.first?.parentThreadID == "parent")
    for id in states.keys { states[id]?.parentThreadID = nil }
    try store?.save(states, retention: RetentionPolicy(days: 7, maximumSessions: 1000))
    store = nil
    collector = try s.collector()
    let recovered = try #require(try await collector?.refresh())
    #expect(recovered.sessions.first?.parentThreadID == "parent")
}

@Test func S242SubagentParentRequiresExplicitNonSelfMetadata() async throws {
    let s = try Sandbox()
    try s.write(#"{"type":"session_meta","payload":{"id":"child","cwd":"/project","source":{"subagent":{"thread_spawn":{"parent_thread_id":"child"}}}}}"# + "\n")
    let c = try s.collector()
    #expect(try await c.refresh().sessions.first?.parentThreadID == nil)
}

@Test func S240CodexWeeklyQuotaComesFromNewestRolloutAndNeedsLogin() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("quota-" + UUID().uuidString)
    let day = home.appendingPathComponent("sessions/2026/10/18")
    try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let line = #"{"payload":{"rate_limits":{"primary":{"used_percent":25,"window_minutes":10080,"resets_at":4102444800}}}}"#
    try ("{}\n" + line + "\n{\"x\":1}\n").write(to: day.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)
    #expect(QuotaReader.codexWindows(home: home).isEmpty)   // no auth.json: not logged in
    try "{}".write(to: home.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
    #expect(QuotaReader.codexWindows(home: home).first?.remainingPercent == 75)
    #expect(QuotaReader.codexWindows(home: home, now: Date(timeIntervalSince1970: 4102444801)).isEmpty)   // window already reset
}
