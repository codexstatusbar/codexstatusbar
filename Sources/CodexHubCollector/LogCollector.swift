import Foundation
import Darwin
import CryptoKit
import CodexHubCore

public struct RetentionPolicy: Sendable, Equatable {
    public let days: Int
    public let maximumSessions: Int
    public init(days: Int = 7, maximumSessions: Int = 1000) throws {
        guard (1...365).contains(days), (1...10_000).contains(maximumSessions) else { throw CollectorError.invalidSettings }
        self.days = days
        self.maximumSessions = maximumSessions
    }
}

public struct SessionUsageDetails: Codable, Sendable {
    public var reasoningEffort: String?
    public var serviceTier: ServiceTier?
    public var contextTokens: Int?
    public var contextWindow: Int?
    public var limits: [UsageLimit]?
}

public struct UsageLimit: Codable, Sendable {
    public let name: String
    public let usedPercent: Double
    public let windowMinutes: Int?
    public let resetsAt: Double?
    public var remainingPercent: Double { 100 - usedPercent }
}

public struct SessionSnapshot: Sendable {
    public let id: String
    public let cwd: String?
    public let model: String?
    public let monitor: ThreadMonitor
    public let lastObserved: Double
    public let hasGap: Bool
    public let sourceReconciliationPending: Bool
    public let activity: Activity
    public var measurement: CodexHubCore.Measurement { sourceReconciliationPending ? .partial : monitor.measurement }
    /// Exact CLI root provenance only; descendant coverage and PID ownership are not proven.
    public let observedCLIRoot: Bool
    public let parentThreadID: String?
    public let usageDetails: SessionUsageDetails?
    public var provider: SessionProvider = .codex
    /// Set only by providers that prove process ownership themselves.
    public var process: ProcessIdentity?
}

public struct CollectorDiagnostic: Sendable, Equatable {
    public let fileIdentity: String?
    public let error: CollectorError
    public var message: String { error.message }
}

public struct CollectorSnapshot: Sendable {
    public let sessions: [SessionSnapshot]
    public let diagnostics: [CollectorDiagnostic]
    public let observedAt: Double
}

struct FileState: Codable, Sendable {
    var path: String
    var isAuthority: Bool?
    var reconciliationPeer: String?
    // Persisted session_meta source == cli proof, used for the root subtotal.
    var cliSource: Bool?
    var parentThreadID: String?
    var offset: Int64 = 0
    var historicalUntil: Int64
    var discardingOversizedLine: Bool?
    var boundaryHash = ""
    var epoch = UUID().uuidString
    var threadID: String?
    var turnID: String?
    var lastTurnState: String?
    var requestTiming: RequestTiming?
    var cwd: String?
    var model: String?
    var usageDetails: SessionUsageDetails?
    var counts: [String: Int]?
    var updated: Double
    var hasGap = false
    var partial = false
    var lastKnownReasoningOutputTokens: Int?
    var lastKnownTotalTokens: Int?
}

public actor LogCollector {
    private let source: SafeDirectory
    private let streamStarts: StreamStartLog
    private let homeHash: String
    private let homePath: String
    private let store: MetadataStore
    private let monotonic: @Sendable () -> Double
    private let wallTime: @Sendable () -> Double
    private var states: [String: FileState]
    private var monitors: [String: ThreadMonitor] = [:]
    private var runningSessionFiles: Set<String> = []
    private var policy: RetentionPolicy
    private var diagnostics: [CollectorDiagnostic] = []
    private var polling: Task<Void, Never>?
    private var lastFrame = 0.0
    private var recovering: Set<String>
    private let maximumRead = 1_048_576
    private let maximumLine = 262_144
    private let maximumFile: Int64 = 268_435_456

    public init(codexHome: URL, metadataDirectory: URL,
                monotonic: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
                wallTime: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }) throws {
        source = try SafeDirectory(codexHome)
        streamStarts = StreamStartLog(codexHome: codexHome)
        // Metadata must never live inside the selected read-only source tree.
        let home = codexHome.resolvingSymlinksInPath().standardizedFileURL.path
        let metadata = metadataDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        guard metadata != home, !metadata.hasPrefix(home + "/") else { throw CollectorError.unsafePath }
        let scope = SHA256.hash(data: Data(home.utf8)).map { String(format: "%02x", $0) }.joined()
        self.homePath = home
        self.homeHash = scope
        store = try MetadataStore(directoryURL: metadataDirectory, sourceScope: scope)
        // States of the removed managed-run source are dropped; they can no longer be refreshed.
        states = try store.load().filter { !$0.key.hasPrefix("direct:") }
        recovering = Set(states.keys)
        policy = try store.retention()
        self.monotonic = monotonic
        self.wallTime = wallTime
    }
    deinit { polling?.cancel() }

    public func start() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                _ = try? await self?.refresh()
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
    }
    public func stop() { polling?.cancel(); polling = nil }

    public func snapshot() -> CollectorSnapshot {
        let transcripts = Dictionary(grouping: states.filter { $0.value.threadID != nil }, by: { $0.value.threadID! })
        let roots = Set(transcripts.compactMap { thread, files -> String? in
            guard files.count == 1, let file = files.first,
                  file.value.cliSource == true,
                  monitors[file.key]?.connectivity == .connected else { return nil }
            return thread
        })
        let allSessions = states.compactMap { id, state -> SessionSnapshot? in
            guard state.isAuthority == true, let monitor = monitors[id] else { return nil }
            return SessionSnapshot(id: id, cwd: state.cwd, model: state.model,
                                   monitor: monitor, lastObserved: state.updated, hasGap: state.hasGap,
                                   sourceReconciliationPending: state.reconciliationPeer != nil,
                                   activity: monitor.activity,
                                   observedCLIRoot: roots.contains(monitor.key.threadID),
                                   parentThreadID: state.parentThreadID,
                                   usageDetails: state.usageDetails)
        }.sorted { $0.id < $1.id }
        let grouped = Dictionary(grouping: allSessions, by: { $0.monitor.key.threadID })
        let sessions = grouped.values.compactMap { group in
            group.sorted { $0.lastObserved == $1.lastObserved ? $0.id < $1.id : $0.lastObserved > $1.lastObserved }.first
        }.sorted { $0.id < $1.id }
        return CollectorSnapshot(sessions: sessions, diagnostics: diagnostics, observedAt: lastFrame)
    }

    /// The caller must prove a current process owns the exact transcript.
    public func bindRunningSessions(_ files: Set<String>) throws -> CollectorSnapshot {
        runningSessionFiles = files
        for (id, state) in states {
            guard state.isAuthority == true, state.reconciliationPeer == nil, var monitor = monitors[id],
                  files.contains(id), monitor.connectivity == .connected,
                  monitor.activity == .unknown, let turn = state.turnID else { continue }
            if state.lastTurnState == "active" {
                monitor = try resumedMonitor(monitor, turn: turn, at: lastFrame)
                states[id]?.hasGap = true
            } else if let raw = state.lastTurnState, let outcome = TurnOutcome(rawValue: raw) {
                try monitor.finishTurn(turn, outcome: outcome, at: lastFrame)
            } else { continue }
            monitors[id] = monitor
        }
        return snapshot()
    }

    @discardableResult
    public func refresh() throws -> CollectorSnapshot {
        let now = monotonic(), wall = wallTime()
        guard now.isFinite, now >= lastFrame, wall.isFinite else { throw CollectorError.invalidSettings }
        var nextStates = states
        var nextMonitors = monitors
        var nextDiagnostics: [CollectorDiagnostic] = []
        func diagnose(_ diagnostic: CollectorDiagnostic) {
            if nextDiagnostics.count < 100 { nextDiagnostics.append(diagnostic) }
        }
        var inputs: [String] = []
        do {
            let listing = try source.logPaths(subdirectory: "sessions")
            if listing.rejected { diagnose(CollectorDiagnostic(fileIdentity: nil, error: .unsafePath)) }
            inputs = listing.paths
        } catch {
            diagnose(CollectorDiagnostic(fileIdentity: nil, error: (error as? CollectorError) ?? .inaccessibleSource))
        }
        var seen: Set<String> = []
        for relative in inputs {
            var identity: String?
            do {
                let fd = try source.openFile(relative)
                defer { close(fd) }
                var info = stat()
                guard fstat(fd, &info) == 0 else { throw CollectorError.inaccessibleSource }
                let id = "\(info.st_dev):\(info.st_ino)"
                identity = id
                seen.insert(id)
                // Rollouts can grow indefinitely; maximumRead and maximumLine bound each pass.
                let modified = min(wall, Double(info.st_mtimespec.tv_sec))
                guard modified >= wall - Double(policy.days) * 86400 else {
                    nextStates.removeValue(forKey: id); nextMonitors.removeValue(forKey: id)
                    continue
                }
                let replacedIDs = nextStates.filter { $0.key != id && $0.value.path == relative }.map(\.key)
                for replaced in replacedIDs { nextStates.removeValue(forKey: replaced); nextMonitors.removeValue(forKey: replaced) }
                var state = nextStates[id] ?? FileState(path: relative, historicalUntil: info.st_size, updated: modified, hasGap: !replacedIDs.isEmpty)
                var monitor = nextMonitors[id]
                if recovering.contains(id) || monitor?.connectivity == .disconnected || (lastFrame > 0 && now - lastFrame > 5) {
                    state.historicalUntil = info.st_size
                    state.hasGap = true
                    state.requestTiming = nil
                    monitor = nil
                }
                let changedBoundary = try state.offset > 0 && (state.offset > info.st_size || boundary(fd, offset: state.offset) != state.boundaryHash)
                if changedBoundary {
                    state = FileState(path: relative, historicalUntil: info.st_size, updated: modified, hasGap: true)
                    monitor = nil
                }
                state.path = relative
                if state.offset > 0,
                   state.cliSource == nil || recovering.contains(id) {
                    // Old checkpoints contain usage, not root proof; never infer origin from a path.
                    var header = [UInt8](repeating: 0, count: min(maximumLine + 1, Int(info.st_size)))
                    let count = pread(fd, &header, header.count, 0)
                    guard count >= 0 else { throw CollectorError.inaccessibleSource }
                    state.cliSource = false
                    state.parentThreadID = nil
                    if let newline = header.prefix(count).firstIndex(of: 10), newline <= maximumLine,
                       let object = try? JSONSerialization.jsonObject(with: Data(header[..<newline])) as? [String: Any],
                       object["type"] as? String == "session_meta",
                       let payload = object["payload"] as? [String: Any],
                       let thread = identifier(payload["id"]), thread == state.threadID {
                        state.cliSource = payload["source"] as? String == "cli"
                        state.parentThreadID = parentThreadID(payload, thread: thread)
                    }
                }
                if state.offset > 0, state.usageDetails == nil || state.lastTurnState == nil {
                    // Recover bounded context/lifecycle markers; activity still requires an exact live-process binding.
                    if state.usageDetails == nil { state.usageDetails = SessionUsageDetails() }
                    if state.lastTurnState == nil { state.lastTurnState = "unknown" }
                    let start = max(0, state.offset - Int64(maximumRead))
                    var bytes = [UInt8](repeating: 0, count: Int(state.offset - start))
                    let count = pread(fd, &bytes, bytes.count, off_t(start))
                    guard count >= 0 else { throw CollectorError.inaccessibleSource }
                    let tail = Data(bytes.prefix(count))
                    var consumed = start == 0 ? 0 : (tail.firstIndex(of: 10).map { $0 + 1 } ?? tail.count)
                    var turn: String?
                    while consumed < tail.count, let newline = tail[consumed...].firstIndex(of: 10) {
                        if newline - consumed <= maximumLine,
                           let object = try? JSONSerialization.jsonObject(with: tail[consumed..<newline]) as? [String: Any],
                           let payload = object["payload"] as? [String: Any] {
                            if object["type"] as? String == "turn_context" {
                                turn = identifier(payload["turn_id"])
                                if let expected = state.turnID, turn == expected {
                                    state.model = metadataString(payload["model"]) ?? state.model
                                    consumeDetails("turn_context", payload: payload, state: &state)
                                }
                            } else if object["type"] as? String == "event_msg" {
                                if payload["type"] as? String == "token_count", let expected = state.turnID, turn == expected {
                                    consumeDetails("token_count", payload: payload, state: &state)
                                }
                                if let expected = state.turnID, identifier(payload["turn_id"]) == expected {
                                    if payload["type"] as? String == "task_started" { state.lastTurnState = "active" }
                                    if ["task_complete", "turn_aborted"].contains(payload["type"] as? String ?? "") {
                                        state.lastTurnState = recordedOutcome(payload).rawValue
                                    }
                                }
                            }
                        }
                        consumed = newline + 1
                    }
                }
                if monitor == nil, let thread = state.threadID {
                    monitor = try restoredMonitor(thread: thread, state: state, at: now)
                }
                if monitor?.connectivity != .connected { try monitor?.setConnectivity(.connected, at: now) }
                if info.st_size - state.offset > maximumRead {
                    state.historicalUntil = info.st_size
                }
                let size = min(maximumRead, Int(max(0, info.st_size - state.offset)))
                var bytes = [UInt8](repeating: 0, count: size)
                let readCount = pread(fd, &bytes, size, off_t(state.offset))
                guard readCount >= 0 else { throw CollectorError.inaccessibleSource }
                let data = Data(bytes.prefix(readCount))
                var consumed = 0
                while let newline = data[consumed...].firstIndex(of: 10) {
                    if state.discardingOversizedLine == true || newline - consumed > maximumLine {
                        state.discardingOversizedLine = false
                        state.hasGap = true
                        state.requestTiming = nil
                        try monitor?.markGap(at: now)
                        diagnose(CollectorDiagnostic(fileIdentity: id, error: .oversizedRecord))
                        consumed = newline + 1
                        continue
                    }
                    let historical = state.offset + Int64(consumed) < state.historicalUntil
                    do {
                        try consume(Data(data[consumed..<newline]), state: &state, monitor: &monitor, historical: historical, now: now)
                    } catch {
                        state.hasGap = true
                        state.requestTiming = nil
                        try monitor?.markGap(at: now)
                        diagnose(CollectorDiagnostic(fileIdentity: id, error: .invalidRecord))
                    }
                    consumed = newline + 1
                    if consumed == data.count { break }
                }
                if state.discardingOversizedLine == true || data.count - consumed > maximumLine {
                    // Persist bounded discard progress so a large transcript record cannot pin the cursor.
                    state.discardingOversizedLine = true
                    state.hasGap = true
                    state.requestTiming = nil
                    try monitor?.markGap(at: now)
                    diagnose(CollectorDiagnostic(fileIdentity: id, error: .oversizedRecord))
                    consumed = data.count
                }
                var after = stat()
                guard fstat(fd, &after) == 0, after.st_size >= info.st_size,
                      after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec && after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec || after.st_size > info.st_size else {
                    throw CollectorError.inaccessibleSource
                }
                state.offset += Int64(consumed)
                state.boundaryHash = try boundary(fd, offset: state.offset)
                if consumed > 0 { state.updated = modified }
                nextStates[id] = state
                if let monitor { nextMonitors[id] = monitor }
            } catch {
                diagnose(CollectorDiagnostic(fileIdentity: identity, error: (error as? CollectorError) ?? .inaccessibleSource))
                if let id = identity {
                    nextStates[id]?.cliSource = false
                    try? nextMonitors[id]?.setConnectivity(.degraded, at: now)
                }
            }
        }
        for id in nextMonitors.keys where !seen.contains(id) { try nextMonitors[id]?.setConnectivity(.disconnected, at: now) }
        for id in try selectAuthorities(states: &nextStates, monitors: &nextMonitors, at: now) {
            diagnose(CollectorDiagnostic(fileIdentity: id, error: .ambiguousSource))
        }
        nextStates = retained(nextStates, wall: wall, policy: policy)
        nextMonitors = nextMonitors.filter { nextStates[$0.key] != nil }
        do { try store.save(nextStates, retention: policy) } catch {
            diagnostics = [CollectorDiagnostic(fileIdentity: nil, error: .database)]
            throw error
        }
        states = nextStates
        monitors = nextMonitors
        recovering.removeAll()
        diagnostics = Array(nextDiagnostics.prefix(100))
        lastFrame = now
        return snapshot()
    }

    public func loadChartHistory() throws -> Data? { try store.loadChartHistory() }
    public func saveChartHistory(_ data: Data) throws { try store.saveChartHistory(data) }

    public func clearMetadata() throws {
        try store.save([:], retention: policy, clearChartHistory: true)
        states.removeAll(); monitors.removeAll(); recovering.removeAll(); diagnostics = []
    }

    public func updateRetention(_ policy: RetentionPolicy) throws {
        let wall = wallTime()
        guard wall.isFinite else { throw CollectorError.invalidSettings }
        let kept = retained(states, wall: wall, policy: policy)
        try store.save(kept, retention: policy)
        diagnostics = []
        self.policy = policy
        states = kept
        monitors = monitors.filter { kept[$0.key] != nil }
    }

    public func markGap() throws {
        let now = monotonic()
        guard now.isFinite, now >= lastFrame else { throw CollectorError.invalidSettings }
        var next = monitors
        var nextStates = states
        for id in next.keys {
            nextStates[id]?.hasGap = true
            nextStates[id]?.requestTiming = nil
            if let state = nextStates[id], let thread = state.threadID {
                next[id] = try restoredMonitor(thread: thread, state: state, at: now)
                try next[id]?.markGap(at: now)
            }
        }
        try store.save(nextStates, retention: policy)
        states = nextStates; monitors = next; lastFrame = now
        recovering = Set(states.keys)
    }

    private func selectAuthorities(states next: inout [String: FileState], monitors current: inout [String: ThreadMonitor], at now: Double) throws -> [String] {
        var ambiguous: [String] = []
        let groups = Dictionary(grouping: current.keys, by: { current[$0]!.key.threadID })
        for ids in groups.values {
            let thread = current[ids[0]]!.key.threadID
            let previous = states.first { $0.value.threadID == thread && $0.value.isAuthority == true }?.key
                ?? states.first { $0.value.threadID == thread && $0.value.isAuthority == nil }?.key
            let selected = ids.sorted { a, b in
                let aAvailable = current[a]?.connectivity == .connected
                let bAvailable = current[b]?.connectivity == .connected
                if aAvailable != bAvailable { return aAvailable }
                if a == previous || b == previous { return a == previous }
                return (next[a]?.updated ?? 0) == (next[b]?.updated ?? 0) ? a < b : (next[a]?.updated ?? 0) > (next[b]?.updated ?? 0)
            }[0]
            for id in ids { next[id]?.isAuthority = id == selected }
            if let previous, previous != selected {
                next[selected]?.reconciliationPeer = previous
                next[selected]?.hasGap = true
                try current[selected]?.markGap(at: now)
            }
            if let peer = next[selected]?.reconciliationPeer {
                let selectedCounter = current[selected]?.counter
                let peerCounter = current[peer]?.counter ?? monitors[peer]?.counter
                if let baseline = selectedCounter?.baseline, baseline == peerCounter?.baseline,
                   selectedCounter?.isPartial == false, peerCounter?.isPartial == false,
                   selectedCounter?.lastKnownReasoningOutputTokens == peerCounter?.lastKnownReasoningOutputTokens,
                   selectedCounter?.lastKnownTotalTokens == peerCounter?.lastKnownTotalTokens {
                    next[selected]?.reconciliationPeer = nil
                }
                try current[selected]?.markGap(at: now)
            }
            let sameSource = ids.filter { current[$0]?.connectivity == .connected }
            if sameSource.count > 1 {
                ambiguous.append(selected)
                next[selected]?.hasGap = true
                next[selected]?.reconciliationPeer = sameSource.first { $0 != selected }
                try current[selected]?.setConnectivity(.degraded, at: now)
            }
        }
        return ambiguous
    }

    private func retained(_ states: [String: FileState], wall: Double, policy: RetentionPolicy) -> [String: FileState] {
        let ordered = states.filter { $0.value.updated >= wall - Double(policy.days) * 86400 }
            .sorted { $0.value.updated == $1.value.updated ? $0.key < $1.key : $0.value.updated > $1.value.updated }
        return Dictionary(uniqueKeysWithValues: ordered.prefix(policy.maximumSessions).map { ($0.key, $0.value) })
    }

    private func boundary(_ fd: Int32, offset: Int64) throws -> String {
        let size = Int(min(offset, 128))
        guard size > 0 else { return "" }
        var bytes = [UInt8](repeating: 0, count: size)
        guard pread(fd, &bytes, size, off_t(offset - Int64(size))) == size else { throw CollectorError.inaccessibleSource }
        return SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    private func restoredMonitor(thread: String, state: FileState, at now: Double) throws -> ThreadMonitor {
        let key = ThreadKey(homeID: homePath, runID: nil, threadID: thread)
        let counter: UsageCounter
        if let counts = state.counts {
            counter = try UsageCounter(source: .rolloutLog, epoch: state.epoch, baseline: usage(counts),
                                       lastKnownReasoningOutputTokens: state.lastKnownReasoningOutputTokens,
                                       lastKnownTotalTokens: state.lastKnownTotalTokens, isPartial: state.partial)
        } else {
            counter = UsageCounter(source: .rolloutLog, epoch: state.epoch)
        }
        var monitor = ThreadMonitor(key: key, counter: counter)
        try monitor.setConnectivity(.connected, at: now)
        return monitor
    }

    private func recordTime(_ object: [String: Any]) -> Double? {
        guard let value = object["timestamp"] as? String, value.utf8.count <= 64 else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = parser.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        return date.map { $0.timeIntervalSince1970 }
    }

    private func consume(_ data: Data, state: inout FileState, monitor: inout ThreadMonitor?, historical: Bool, now: Double) throws {
        guard !data.isEmpty else { return }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String, let payload = object["payload"] as? [String: Any] else { throw CollectorError.invalidRecord }
        if type == "session_meta" {
            state.cliSource = false
            guard let id = identifier(payload["id"]) else { throw CollectorError.invalidRecord }
            guard state.threadID == nil || state.threadID == id else { throw CollectorError.invalidRecord }
            state.threadID = id
            state.cliSource = payload["source"] as? String == "cli"
            state.parentThreadID = parentThreadID(payload, thread: id)
            state.cwd = metadataString(payload["cwd"])
            if monitor == nil { monitor = try restoredMonitor(thread: id, state: state, at: now) }
            return
        }
        if type == "turn_context" {
            if let turn = identifier(payload["turn_id"]) {
                if state.turnID != turn { state.lastTurnState = "unknown" }
                state.turnID = turn
            }
            state.cwd = metadataString(payload["cwd"]) ?? state.cwd
            state.model = metadataString(payload["model"]) ?? state.model
            consumeDetails("turn_context", payload: payload, state: &state)
            return
        }
        if type == "response_item", !historical {
            let kind = payload["type"] as? String
            let starts = kind == "function_call" || kind == "custom_tool_call"
            let ends = kind == "function_call_output" || kind == "custom_tool_call_output"
            if starts || ends {
                guard let call = identifier(payload["call_id"]), let time = recordTime(object),
                      state.requestTiming?.tool(call, running: starts, at: time) == true else {
                    state.requestTiming = nil
                    return
                }
            }
            return
        }
        guard type == "event_msg", let event = payload["type"] as? String else { return }
        guard monitor != nil else { throw CollectorError.invalidRecord }
        switch event {
        case "task_started":
            guard let turn = identifier(payload["turn_id"]) else { throw CollectorError.invalidRecord }
            state.turnID = turn
            state.lastTurnState = "active"
            if !historical && monitor?.activeTurnID != turn {
                if monitor?.activeTurnID != nil, let thread = state.threadID {
                    state.hasGap = true
                    monitor = try restoredMonitor(thread: thread, state: state, at: now)
                    state.requestTiming = nil
                    try monitor?.markGap(at: now)
                }
                try monitor?.startTurn(turn, at: now)
                state.requestTiming = recordTime(object).map { RequestTiming(at: $0) }
            }
        case "task_complete", "turn_aborted":
            guard let turn = identifier(payload["turn_id"]) ?? state.turnID else { throw CollectorError.invalidRecord }
            let outcome = recordedOutcome(payload)
            if state.turnID == nil || state.turnID == turn {
                state.turnID = turn
                state.lastTurnState = outcome.rawValue
            }
            if !historical {
                if state.turnID == turn, let time = recordTime(object) { state.requestTiming?.finish(at: time) }
                try monitor?.finishTurn(turn, outcome: outcome, at: now)
            }
        case "token_count":
            consumeDetails("token_count", payload: payload, state: &state)
            guard let info = payload["info"] as? [String: Any] else { return }
            guard let raw = info["total_token_usage"] as? [String: Any] else { throw CollectorError.invalidRecord }
            var counts: [String: Int] = [:]
            for key in ["output_tokens", "reasoning_output_tokens", "input_tokens", "cached_input_tokens", "cache_write_input_tokens", "total_tokens"] {
                if let value = raw[key] {
                    guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                          n.doubleValue.isFinite, n.doubleValue >= 0,
                          let integer = Int(n.stringValue) else { throw CollectorError.invalidRecord }
                    counts[key] = integer
                }
            }
            let total = try usage(counts)
            if let turn = state.turnID {
                var duration: Double?
                if !historical, total.outputTokens != monitor?.counter.baseline?.outputTokens {
                    if let time = recordTime(object) {
                        let reversed = state.requestTiming?.accepts(time) == false
                        if reversed { state.requestTiming = nil }
                        let earliest = state.requestTiming?.baselineTime ?? time - 600
                        // Generation starts at the response headers; time before them is request latency.
                        let start = state.threadID.flatMap { streamStarts.streamStart(thread: $0, earliest: earliest, latest: time) }
                        if state.requestTiming != nil {
                            duration = state.requestTiming?.sample(at: time, streamStart: start)
                        } else if !reversed, let start, time > start {
                            // Only the very first report has no earlier timing; a reversed clock cannot be trusted.
                            duration = time - start
                        }
                        if state.requestTiming == nil { state.requestTiming = RequestTiming(at: time) }
                    } else { state.requestTiming = nil }
                }
                try monitor?.observeUsage(total, turnID: turn, source: .rolloutLog, epoch: state.epoch, at: now, historical: historical, rateInterval: .excludingTools(duration))
            } else {
                if let current = monitor {
                    var counter = current.counter
                    _ = counter.observe(total, source: .rolloutLog, epoch: state.epoch)
                    monitor = ThreadMonitor(key: current.key, counter: counter)
                    try monitor?.setConnectivity(.connected, at: now)
                }
            }
            state.partial = monitor?.counter.isPartial ?? false
            state.lastKnownReasoningOutputTokens = monitor?.counter.lastKnownReasoningOutputTokens
            state.lastKnownTotalTokens = monitor?.counter.lastKnownTotalTokens
            if !state.partial { state.counts = counts }
        default: break
        }
    }

    private func usage(_ counts: [String: Int]) throws -> TokenUsage {
        guard let output = counts["output_tokens"] else { throw CollectorError.invalidRecord }
        return try TokenUsage(outputTokens: output, reasoningOutputTokens: counts["reasoning_output_tokens"],
                              inputTokens: counts["input_tokens"] ?? 0, cachedInputTokens: counts["cached_input_tokens"] ?? 0,
                              cacheWriteInputTokens: counts["cache_write_input_tokens"] ?? 0, totalTokens: counts["total_tokens"])
    }
    private func resumedMonitor(_ monitor: ThreadMonitor, turn: String, at time: Double) throws -> ThreadMonitor {
        var resumed = ThreadMonitor(key: monitor.key, counter: monitor.counter)
        try resumed.setConnectivity(.connected, at: time)
        try resumed.startTurn(turn, at: time)
        try resumed.markGap(at: time)
        return resumed
    }

    private func recordedOutcome(_ payload: [String: Any]) -> TurnOutcome {
        let status = payload["status"] as? String
        return status == "failed" ? .failed : (status == "interrupted" || payload["type"] as? String == "turn_aborted" ? .interrupted : .completed)
    }

    private func consumeDetails(_ type: String, payload: [String: Any], state: inout FileState) {
        if state.usageDetails == nil { state.usageDetails = SessionUsageDetails() }
        if type == "turn_context" {
            state.usageDetails?.reasoningEffort = identifier(payload["effort"]).flatMap { $0.utf8.count <= 32 ? $0 : nil }
            state.usageDetails?.serviceTier = (payload["service_tier"] as? String).flatMap(ServiceTier.init(rawValue:))
            return
        }
        if let rawLimits = payload["rate_limits"] as? [String: Any] {
            state.usageDetails?.limits = ["primary", "secondary"].compactMap { name in
                guard let raw = rawLimits[name] as? [String: Any],
                      let used = finiteNumber(raw["used_percent"]), (0...100).contains(used) else { return nil }
                let minutes = integer(raw["window_minutes"]).flatMap { $0 > 0 && $0 <= Int.max ? Int($0) : nil }
                let reset = integer(raw["resets_at"]).flatMap { (0...253_402_300_799).contains($0) ? Double($0) : nil }
                return UsageLimit(name: name, usedPercent: used, windowMinutes: minutes, resetsAt: reset)
            }
        }
        guard let info = payload["info"] as? [String: Any] else { return }
        state.usageDetails?.contextWindow = integer(info["model_context_window"]).flatMap { $0 > 0 && $0 <= Int.max ? Int($0) : nil }
        let last = info["last_token_usage"] as? [String: Any]
        state.usageDetails?.contextTokens = integer(last?["total_tokens"]).flatMap { $0 >= 0 && $0 <= Int.max ? Int($0) : nil }
    }

    private func finiteNumber(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    private func integer(_ value: Any?) -> Int64? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        return Int64(value.stringValue)
    }

    private func parentThreadID(_ payload: [String: Any], thread: String) -> String? {
        guard let source = payload["source"] as? [String: Any],
              let subagent = source["subagent"] as? [String: Any],
              let spawn = subagent["thread_spawn"] as? [String: Any],
              let parent = identifier(spawn["parent_thread_id"]), parent != thread else { return nil }
        return parent
    }

    private func identifier(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty, value.utf8.count <= 256,
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,46,58,95].contains($0) }) else { return nil }
        return value
    }
    private func metadataString(_ value: Any?) -> String? {
        guard let value = value as? String, value.utf8.count <= 2048, !value.unicodeScalars.contains(where: { $0.value < 32 }) else { return nil }
        return value
    }
}
