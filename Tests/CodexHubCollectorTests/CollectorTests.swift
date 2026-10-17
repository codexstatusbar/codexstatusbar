import Foundation
import Testing
import CodexHubCollector

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

@Test func S209SymlinksAndHardlinksAreRejected() async throws {
    let s = try Sandbox(); try s.write(meta + usage(10))
    let outside = s.root.appendingPathComponent("outside.jsonl")
    try Data((meta + usage(999)).utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(at: s.home.appendingPathComponent("sessions/link.jsonl"), withDestinationURL: outside)
    try FileManager.default.linkItem(at: outside, to: s.home.appendingPathComponent("sessions/hard.jsonl"))
    let c = try s.collector()
    let result = try await c.refresh()
    #expect(result.sessions.count == 1)
    #expect(result.diagnostics.contains { $0.error == .unsafePath })
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
    do { _ = try await c.refresh(); Issue.record("Expected missing root") } catch {}
    #expect(await c.snapshot().sessions[0].monitor.connectivity == .disconnected)
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
    #expect(!snapshot.diagnostics.isEmpty)
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
