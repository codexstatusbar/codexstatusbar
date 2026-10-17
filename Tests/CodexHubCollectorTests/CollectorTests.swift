import Foundation
import Testing
import CodexHubCollector
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

@Test func S223PrivateManagedSourceHardlinkRemainsRejected() async throws {
    let s = try Sandbox(); try s.write(meta + usage(10))
    let managed = s.root.appendingPathComponent("managed")
    let run = managed.appendingPathComponent("sessions/" + UUID().uuidString)
    try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let source = s.root.appendingPathComponent("private-source")
    try Data("not a managed record\n".utf8).write(to: source)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path)
    try FileManager.default.linkItem(at: source, to: run.appendingPathComponent(UUID().uuidString + ".jsonl"))
    let c = try LogCollector(codexHome: s.home, metadataDirectory: s.metadata, managedRunsDirectory: managed)
    let snapshot = try await c.refresh()
    #expect(snapshot.sessions.count == 1)
    #expect(snapshot.diagnostics.contains { $0.error == .unsafePath })
    #expect(!snapshot.diagnostics.contains { $0.error == .invalidRecord })
    #expect(try String(contentsOf: source, encoding: .utf8) == "not a managed record\n")
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
    #expect(try measured.sessions[0].monitor.workAverageRate(at: 110) == 3)
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

@Test func S229FreshHookRecoversVerifiedRunningTurnWhenStartIsUnavailable() async throws {
    let s = try Sandbox()
    try s.write(meta.replacingOccurrences(of: "\"cwd\"", with: "\"source\":\"cli\",\"cwd\"") + "{\"type\":\"turn_context\",\"payload\":{\"turn_id\":\"old\"}}\n" + usage(100))
    let hooks = s.root.appendingPathComponent("hooks")
    let installation = UUID().uuidString
    let directory = hooks.appendingPathComponent(installation)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let events = directory.appendingPathComponent("events.jsonl")
    try Data().write(to: events)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: events.path)
    let wall = Date().timeIntervalSince1970
    let c = try LogCollector(codexHome: s.home, metadataDirectory: s.metadata, hooksDirectory: hooks, monotonic: { 100 }, wallTime: { wall })
    let initial = try await c.refresh()
    let hash = SHA256.hash(data: Data(s.home.resolvingSymlinksInPath().standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
    func appendHook(_ tool: String) throws {
        let event: [String: Any] = ["hub_schema_version":1,"hub_source":"hook","codex_home_id":hash,"installation_id":installation,"session_id":"session-a","turn_id":"old","hook_event_name":"PreToolUse","tool_use_id":tool,"timestamp":ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: wall)),"received_monotonic_ns":"100000000000"]
        let handle = try FileHandle(forWritingTo: events)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: JSONSerialization.data(withJSONObject: event) + Data([10]))
    }
    try appendHook("unbound-tool")
    let unbound = try await c.refresh()
    #expect(unbound.sessions[0].monitor.activity == .unknown)
    _ = try await c.bindRunningSessions([initial.sessions[0].id])
    try appendHook("tool-1")
    let recovered = try await c.refresh()
    #expect(recovered.sessions[0].monitor.activity == .working)
    #expect(try recovered.sessions[0].monitor.reportedRate(at: 100) == nil)
    try appendHook("tool-2")
    let tool = try await c.refresh()
    #expect(tool.sessions[0].activity == .toolRunning)
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
