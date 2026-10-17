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
    public let source: UsageSource
    public let processes: [ManagedProcessInfo]
    public let sourceReconciliationPending: Bool
    public let observationStopped: Bool
    public let activity: Activity
    public let hookCompletionCandidate: Bool
    public let liveRate: Double?
    public let liveMeasurement: CodexHubCore.Measurement
    public let liveUnavailableReason: String?
    public var measurement: CodexHubCore.Measurement { sourceReconciliationPending || observationStopped ? .partial : monitor.measurement }
    /// Exact CLI root provenance only; descendant coverage and PID ownership are not proven.
    public let observedCLIRoot: Bool
    public let usageDetails: SessionUsageDetails?
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
    var sourceName: String?
    var runID: String?
    var processes: [ManagedProcessInfo]?
    var isAuthority: Bool?
    var reconciliationPeer: String?
    var sourceDisconnected: Bool?
    var observationStopped: Bool?
    var managedValidated: Bool?
    // Persisted session_meta source == cli proof, shared by hooks and root subtotal.
    var hookIdentityEligible: Bool?
    var usageSource: UsageSource { sourceName == "direct-relay" ? .directRelay : .rolloutLog }
    var offset: Int64 = 0
    var historicalUntil: Int64
    var boundaryHash = ""
    var epoch = UUID().uuidString
    var threadID: String?
    var turnID: String?
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

private struct HookEvent {
    let streamID: String
    let sessionID: String
    let turnID: String?
    let toolID: String?
    let name: String
    let receivedAt: Double
}

private struct HookState {
    let streamID: String
    let turnID: String
    var receivedAt: Double
    var tools: Set<String> = []
    var completionCandidate = false
}

public actor LogCollector {
    private let source: SafeDirectory
    private let managedRunsDirectory: URL?
    private let hooksDirectory: URL?
    private let homeHash: String
    private let homePath: String
    private let store: MetadataStore
    private let monotonic: @Sendable () -> Double
    private let wallTime: @Sendable () -> Double
    private var states: [String: FileState]
    private var monitors: [String: ThreadMonitor] = [:]
    private var visibleWindows: [String: VisibleWindow] = [:]
    private var hookStates: [String: HookState] = [:]
    private var policy: RetentionPolicy
    private var diagnostics: [CollectorDiagnostic] = []
    private var polling: Task<Void, Never>?
    private var lastFrame = 0.0
    private var recovering: Set<String>
    private let maximumRead = 1_048_576
    private let maximumLine = 262_144
    private let maximumFile: Int64 = 268_435_456

    public init(codexHome: URL, metadataDirectory: URL, managedRunsDirectory: URL? = nil, hooksDirectory: URL? = nil,
                monotonic: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
                wallTime: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }) throws {
        source = try SafeDirectory(codexHome)
        // Metadata must never live inside the selected read-only source tree.
        let home = codexHome.resolvingSymlinksInPath().standardizedFileURL.path
        let metadata = metadataDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        guard metadata != home, !metadata.hasPrefix(home + "/") else { throw CollectorError.unsafePath }
        let scope = SHA256.hash(data: Data(home.utf8)).map { String(format: "%02x", $0) }.joined()
        self.homePath = home
        self.homeHash = scope
        self.managedRunsDirectory = managedRunsDirectory
        self.hooksDirectory = hooksDirectory
        store = try MetadataStore(directoryURL: metadataDirectory, sourceScope: scope)
        states = try store.load()
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
        let transcripts = Dictionary(grouping: states.filter {
            $0.value.sourceName == "rollout-log" && $0.value.threadID != nil
        }, by: { $0.value.threadID! })
        let roots = Set(transcripts.compactMap { thread, files -> String? in
            guard files.count == 1, let file = files.first,
                  file.value.hookIdentityEligible == true,
                  monitors[file.key]?.connectivity == .connected else { return nil }
            return thread
        })
        let allSessions = states.compactMap { id, state -> SessionSnapshot? in
            guard state.isAuthority == true, let monitor = monitors[id] else { return nil }
            let hook = hookStates[id]
            let hookEligible = state.usageSource == .rolloutLog && monitor.connectivity == .connected &&
                monitor.activeTurnID != nil && hook?.turnID == monitor.activeTurnID &&
                lastFrame - (hook?.receivedAt ?? -.infinity) <= 10 && state.reconciliationPeer == nil
            let activity = hookEligible && monitor.activity == .working && !(hook?.tools.isEmpty ?? true) ? Activity.toolRunning : monitor.activity
            let live = visibleWindows[id] ?? VisibleWindow()
            let liveBlocked = state.usageSource != .directRelay || monitor.activeTurnID == nil ||
                monitor.connectivity != .connected || state.reconciliationPeer != nil || state.observationStopped == true
            let reason = state.usageSource != .directRelay ? "direct_source_required" :
                (monitor.activeTurnID == nil ? "no_active_turn" :
                    (liveBlocked ? "source_unavailable" : live.unavailableReason))
            let context = state.usageSource == .rolloutLog ? state : transcripts[monitor.key.threadID].flatMap { files in
                files.count == 1 && files.first?.value.turnID == state.turnID ? files.first?.value : nil
            }
            return SessionSnapshot(id: id, cwd: state.cwd, model: context?.model ?? state.model,
                                   monitor: monitor, lastObserved: state.updated, hasGap: state.hasGap,
                                   source: state.usageSource, processes: state.processes ?? [],
                                   sourceReconciliationPending: state.reconciliationPeer != nil,
                                   observationStopped: state.observationStopped == true,
                                   activity: activity, hookCompletionCandidate: hookEligible && hook?.completionCandidate == true,
                                   liveRate: liveBlocked ? nil : live.rate(at: lastFrame),
                                   liveMeasurement: liveBlocked ? .unavailable : live.measurement(at: lastFrame),
                                   liveUnavailableReason: reason ?? (live.measurement(at: lastFrame) == .partial ? "invalid_window" : nil),
                                   observedCLIRoot: roots.contains(monitor.key.threadID) &&
                                       (state.usageSource == .rolloutLog || state.managedValidated == true),
                                   usageDetails: context?.usageDetails)
        }.sorted { $0.id < $1.id }
        let grouped = Dictionary(grouping: allSessions, by: { $0.monitor.key.threadID })
        let sessions = grouped.values.compactMap { group in
            group.sorted { $0.lastObserved == $1.lastObserved ? $0.id < $1.id : $0.lastObserved > $1.lastObserved }.first
        }.sorted { $0.id < $1.id }
        return CollectorSnapshot(sessions: sessions, diagnostics: diagnostics, observedAt: lastFrame)
    }

    @discardableResult
    public func refresh() throws -> CollectorSnapshot {
        let now = monotonic(), wall = wallTime()
        guard now.isFinite, now >= lastFrame, wall.isFinite else { throw CollectorError.invalidSettings }
        var nextStates = states
        var nextMonitors = monitors
        var nextVisible = visibleWindows
        var pendingHooks: [HookEvent] = []
        var invalidHookStreams: Set<String> = []
        var nextDiagnostics: [CollectorDiagnostic] = []
        func diagnose(_ diagnostic: CollectorDiagnostic) {
            if nextDiagnostics.count < 100 { nextDiagnostics.append(diagnostic) }
        }
        var roots: [(directory: SafeDirectory, managed: Bool, hook: Bool)] = [(source, false, false)]
        if let url = managedRunsDirectory {
            var info = stat()
            if lstat(url.path, &info) == 0 {
                do { roots.append((try SafeDirectory(url, requirePrivate: true), true, false)) }
                catch { diagnose(CollectorDiagnostic(fileIdentity: nil, error: .unsafePath)) }
            } else if errno != ENOENT { diagnose(CollectorDiagnostic(fileIdentity: nil, error: .unsafePath)) }
        }
        if let url = hooksDirectory {
            var info = stat()
            if lstat(url.path, &info) == 0 {
                do { roots.append((try SafeDirectory(url, requirePrivate: true), false, true)) }
                catch { diagnose(CollectorDiagnostic(fileIdentity: nil, error: .unsafePath)) }
            } else if errno != ENOENT { diagnose(CollectorDiagnostic(fileIdentity: nil, error: .unsafePath)) }
        }
        var inputs: [(directory: SafeDirectory, managed: Bool, hook: Bool, path: String)] = []
        for root in roots {
            do {
                let listing = try root.directory.logPaths(subdirectory: root.hook ? "" : "sessions")
                if listing.rejected { diagnose(CollectorDiagnostic(fileIdentity: nil, error: .unsafePath)) }
                inputs += listing.paths.map { (root.directory, root.managed, root.hook, $0) }
            } catch {
                var sessions = stat()
                let missing = fstatat(root.directory.fd, "sessions", &sessions, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT
                if !root.managed || !missing { diagnose(CollectorDiagnostic(fileIdentity: nil, error: (error as? CollectorError) ?? .inaccessibleSource)) }
            }
        }
        var seen: Set<String> = []
        for input in inputs {
            let relative = input.path
            var identity: String?
            do {
                let components = relative.split(separator: "/")
                if input.managed {
                    if components.last == "run-events.jsonl" { continue }
                    guard components.count == 3, UUID(uuidString: String(components[1])) != nil,
                          UUID(uuidString: String(components[2].dropLast(6))) != nil else { throw CollectorError.invalidRecord }
                }
                if input.hook {
                    guard components.count == 2, UUID(uuidString: String(components[0])) != nil,
                          components[1] == "events.jsonl" else { throw CollectorError.invalidRecord }
                }
                let fd = try input.directory.openFile(relative)
                defer { close(fd) }
                var info = stat()
                guard fstat(fd, &info) == 0 else { throw CollectorError.inaccessibleSource }
                let id = "\(input.hook ? "hook:" : (input.managed ? "direct:" : ""))\(info.st_dev):\(info.st_ino)"
                identity = id
                seen.insert(id)
                guard info.st_size <= (input.hook ? 4_194_304 : maximumFile) else { throw CollectorError.oversizedRecord }
                let modified = min(wall, Double(info.st_mtimespec.tv_sec))
                guard modified >= wall - Double(policy.days) * 86400 else {
                    if input.managed, nextStates[id]?.managedValidated != true { diagnose(CollectorDiagnostic(fileIdentity: id, error: .cleanupDeferred)) }
                    nextStates.removeValue(forKey: id); nextMonitors.removeValue(forKey: id)
                    continue
                }
                let replacedIDs = nextStates.filter { $0.key != id && $0.value.path == relative && ($0.value.usageSource == .directRelay) == input.managed && ($0.value.sourceName == "hook") == input.hook }.map(\.key)
                for replaced in replacedIDs { nextStates.removeValue(forKey: replaced); nextMonitors.removeValue(forKey: replaced) }
                var state = nextStates[id] ?? FileState(path: relative, historicalUntil: info.st_size, updated: modified, hasGap: !replacedIDs.isEmpty)
                var monitor = nextMonitors[id]
                var visible = nextVisible[id] ?? VisibleWindow()
                var fileHooks: [HookEvent] = []
                if recovering.contains(id) || monitor?.connectivity == .disconnected || (lastFrame > 0 && now - lastFrame > 5) {
                    state.historicalUntil = info.st_size
                    state.hasGap = true
                    monitor = nil
                    visible.invalidate(reason: "observation_gap")
                }
                let changedBoundary = try state.offset > 0 && (state.offset > info.st_size || boundary(fd, offset: state.offset) != state.boundaryHash)
                if changedBoundary {
                    if input.hook { invalidHookStreams.insert(id) }
                    state = FileState(path: relative, historicalUntil: info.st_size, updated: modified, hasGap: true)
                    monitor = nil
                    visible.invalidate(reason: "observation_gap")
                }
                state.path = relative
                state.sourceName = input.hook ? "hook" : (input.managed ? "direct-relay" : "rollout-log")
                if input.managed { state.runID = state.runID ?? String(components[1]) }
                if !input.managed && !input.hook, state.offset > 0,
                   state.hookIdentityEligible == nil || recovering.contains(id) {
                    // Old checkpoints contain usage, not root proof; never infer origin from a path.
                    var header = [UInt8](repeating: 0, count: min(maximumLine + 1, Int(info.st_size)))
                    let count = pread(fd, &header, header.count, 0)
                    guard count >= 0 else { throw CollectorError.inaccessibleSource }
                    state.hookIdentityEligible = false
                    if let newline = header.prefix(count).firstIndex(of: 10), newline <= maximumLine,
                       let object = try? JSONSerialization.jsonObject(with: Data(header[..<newline])) as? [String: Any],
                       object["type"] as? String == "session_meta",
                       let payload = object["payload"] as? [String: Any],
                       let thread = identifier(payload["id"]), thread == state.threadID {
                        state.hookIdentityEligible = payload["source"] as? String == "cli"
                    }
                }
                if !input.managed && !input.hook, state.usageDetails == nil, state.offset > 0 {
                    // Upgrade old checkpoints using bounded display metadata only; never replay activity/counters.
                    state.usageDetails = SessionUsageDetails()
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
                            } else if object["type"] as? String == "event_msg", payload["type"] as? String == "token_count",
                                      let expected = state.turnID, turn == expected {
                                consumeDetails("token_count", payload: payload, state: &state)
                            }
                        }
                        consumed = newline + 1
                    }
                }
                if monitor == nil, let thread = state.threadID {
                    monitor = try restoredMonitor(thread: thread, state: state, at: now)
                }
                if state.sourceDisconnected != true && state.observationStopped != true && monitor?.connectivity != .connected { try monitor?.setConnectivity(.connected, at: now) }
                if info.st_size - state.offset > maximumRead {
                    state.historicalUntil = info.st_size
                    visible.invalidate(reason: "buffered_records")
                }
                let size = min(maximumRead, Int(max(0, info.st_size - state.offset)))
                var bytes = [UInt8](repeating: 0, count: size)
                let readCount = pread(fd, &bytes, size, off_t(state.offset))
                guard readCount >= 0 else { throw CollectorError.inaccessibleSource }
                let data = Data(bytes.prefix(readCount))
                var consumed = 0
                while let newline = data[consumed...].firstIndex(of: 10) {
                    guard newline - consumed <= maximumLine else { throw CollectorError.oversizedRecord }
                    let historical = state.offset + Int64(consumed) < state.historicalUntil
                    do {
                        if input.hook {
                            if let event = try hookEvent(Data(data[consumed..<newline]), installation: String(components[0]),
                                                         streamID: id, historical: historical, now: now, wall: wall) {
                                guard fileHooks.count < 4096 else { throw CollectorError.oversizedRecord }
                                fileHooks.append(event)
                            }
                        } else {
                            try consume(Data(data[consumed..<newline]), state: &state, monitor: &monitor, visible: &visible, historical: historical, now: now)
                        }
                    } catch {
                        if input.managed { state.managedValidated = false }
                        if input.hook { invalidHookStreams.insert(id) }
                        state.hasGap = true
                        visible.invalidate(reason: "invalid_record")
                        try monitor?.markGap(at: now)
                        diagnose(CollectorDiagnostic(fileIdentity: id, error: .invalidRecord))
                    }
                    consumed = newline + 1
                    if consumed == data.count { break }
                }
                guard data.count - consumed <= maximumLine else { throw CollectorError.oversizedRecord }
                var after = stat()
                guard fstat(fd, &after) == 0, after.st_size >= info.st_size,
                      after.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec && after.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec || after.st_size > info.st_size else {
                    throw CollectorError.inaccessibleSource
                }
                state.offset += Int64(consumed)
                state.boundaryHash = try boundary(fd, offset: state.offset)
                if consumed > 0 { state.updated = modified }
                if input.managed, state.sourceDisconnected != true, state.observationStopped != true {
                    let connection = state.processes?.first(where: { $0.role == .relay })?.connectivity ?? .unknown
                    if connection != .connected { try monitor?.setConnectivity(connection, at: now) }
                }
                if monitor?.connectivity != .connected { visible.invalidate(reason: "source_unavailable") }
                if input.hook {
                    guard pendingHooks.count + fileHooks.count <= 4096 else { throw CollectorError.oversizedRecord }
                    pendingHooks += fileHooks
                } else { nextVisible[id] = visible }
                nextStates[id] = state
                if let monitor { nextMonitors[id] = monitor }
            } catch {
                diagnose(CollectorDiagnostic(fileIdentity: identity, error: (error as? CollectorError) ?? .inaccessibleSource))
                if let id = identity {
                    if input.hook { invalidHookStreams.insert(id) }
                    if !input.managed && !input.hook { nextStates[id]?.hookIdentityEligible = false }
                    try? nextMonitors[id]?.setConnectivity(.degraded, at: now)
                    nextVisible[id]?.invalidate(reason: "source_unavailable")
                }
            }
        }
        for id in nextMonitors.keys where !seen.contains(id) { try nextMonitors[id]?.setConnectivity(.disconnected, at: now) }
        for id in try selectAuthorities(states: &nextStates, monitors: &nextMonitors, at: now) {
            diagnose(CollectorDiagnostic(fileIdentity: id, error: .ambiguousSource))
        }
        for id in nextVisible.keys {
            if nextMonitors[id]?.connectivity != .connected || nextStates[id]?.isAuthority != true ||
                nextStates[id]?.reconciliationPeer != nil ||
                (states[id]?.isAuthority == false && nextStates[id]?.isAuthority == true) {
                nextVisible[id]?.invalidate(reason: "source_changed")
            }
        }
        let nextHooks = reconcileHooks(pendingHooks, states: nextStates, monitors: nextMonitors,
                                       seen: seen, invalidStreams: invalidHookStreams, now: now)
        let beforeRetention = states.merging(nextStates) { _, new in new }
        nextStates = retained(nextStates, wall: wall, policy: policy)
        nextMonitors = nextMonitors.filter { nextStates[$0.key] != nil }
        do { try store.save(nextStates, retention: policy) } catch {
            diagnostics = [CollectorDiagnostic(fileIdentity: nil, error: .database)]
            throw error
        }
        nextDiagnostics += cleanupManaged(beforeRetention.filter { nextStates[$0.key] == nil }, reportUntracked: false)
        states = nextStates
        monitors = nextMonitors
        visibleWindows = nextVisible.filter { nextStates[$0.key] != nil }
        hookStates = nextHooks.filter { nextStates[$0.key] != nil }
        recovering.removeAll()
        diagnostics = Array(nextDiagnostics.prefix(100))
        lastFrame = now
        return snapshot()
    }

    public func clearMetadata() throws {
        try store.save([:], retention: policy)
        let cleanup = cleanupManaged(states, reportUntracked: true)
        states.removeAll(); monitors.removeAll(); visibleWindows.removeAll(); hookStates.removeAll(); recovering.removeAll(); diagnostics = cleanup
    }

    public func updateRetention(_ policy: RetentionPolicy) throws {
        let wall = wallTime()
        guard wall.isFinite else { throw CollectorError.invalidSettings }
        let kept = retained(states, wall: wall, policy: policy)
        try store.save(kept, retention: policy)
        diagnostics = cleanupManaged(states.filter { kept[$0.key] == nil }, reportUntracked: false)
        self.policy = policy
        states = kept
        monitors = monitors.filter { kept[$0.key] != nil }
        visibleWindows = visibleWindows.filter { kept[$0.key] != nil }
        hookStates = hookStates.filter { kept[$0.key] != nil && kept[$0.value.streamID] != nil }
    }

    public func markGap() throws {
        let now = monotonic()
        guard now.isFinite, now >= lastFrame else { throw CollectorError.invalidSettings }
        var next = monitors
        var nextStates = states
        for id in next.keys {
            nextStates[id]?.hasGap = true
            if let state = nextStates[id], let thread = state.threadID {
                next[id] = try restoredMonitor(thread: thread, state: state, at: now)
                try next[id]?.markGap(at: now)
            }
        }
        try store.save(nextStates, retention: policy)
        states = nextStates; monitors = next; lastFrame = now
        recovering = Set(states.keys)
        visibleWindows.removeAll()
        hookStates.removeAll()
    }

    private func cleanupManaged(_ candidates: [String: FileState], reportUntracked: Bool) -> [CollectorDiagnostic] {
        let managed = candidates.filter { $0.value.usageSource == .directRelay }
        guard let url = managedRunsDirectory, reportUntracked || !managed.isEmpty else { return [] }
        var rootInfo = stat()
        if lstat(url.path, &rootInfo) != 0 && errno == ENOENT { return [] }
        var result: [CollectorDiagnostic] = []
        do {
            let root = try SafeDirectory(url, requirePrivate: true)
            var removed: Set<String> = []
            for (id, state) in managed {
                do {
                    guard state.managedValidated == true, state.threadID != nil,
                          state.processes?.first(where: { $0.role == .relay })?.connectivity == .disconnected else { throw CollectorError.cleanupDeferred }
                    let fd = try root.openFile(state.path)
                    defer { close(fd) }
                    var info = stat()
                    guard fstat(fd, &info) == 0, id == "direct:\(info.st_dev):\(info.st_ino)",
                          info.st_size == state.offset, state.offset > 0,
                          try boundary(fd, offset: state.offset) == state.boundaryHash else { throw CollectorError.cleanupDeferred }
                    var bytes = [UInt8](repeating: 0, count: min(maximumLine + 1, Int(info.st_size)))
                    let count = pread(fd, &bytes, bytes.count, 0)
                    guard count > 0, let newline = bytes.prefix(count).firstIndex(of: 10) else { throw CollectorError.cleanupDeferred }
                    var checked = state
                    checked.threadID = nil; checked.processes = nil; checked.managedValidated = nil
                    var monitor: ThreadMonitor?
                    var visible = VisibleWindow()
                    try consume(Data(bytes[..<newline]), state: &checked, monitor: &monitor, visible: &visible, historical: true, now: lastFrame)
                    guard checked.threadID == state.threadID, checked.managedValidated == true, checked.processes == state.processes, checked.processes?.first(where: { $0.role == .relay })?.connectivity == .disconnected else { throw CollectorError.cleanupDeferred }
                    try root.removeManagedFile(state.path, matching: fd)
                    removed.insert(state.path)
                } catch {
                    if result.count < 100 { result.append(CollectorDiagnostic(fileIdentity: id, error: .cleanupDeferred)) }
                }
            }
            let remaining = try root.logPaths()
            if remaining.rejected || remaining.paths.contains(where: { path in
                reportUntracked || removed.contains(where: { $0.split(separator: "/").dropLast() == path.split(separator: "/").dropLast() })
            }) {
                if result.count < 100 { result.append(CollectorDiagnostic(fileIdentity: nil, error: .cleanupDeferred)) }
            }
        } catch { result.append(CollectorDiagnostic(fileIdentity: nil, error: .cleanupDeferred)) }
        return Array(result.prefix(100))
    }

    private func selectAuthorities(states next: inout [String: FileState], monitors current: inout [String: ThreadMonitor], at now: Double) throws -> [String] {
        var ambiguous: [String] = []
        let groups = Dictionary(grouping: current.keys, by: { current[$0]!.key.threadID })
        for ids in groups.values {
            let thread = current[ids[0]]!.key.threadID
            let previous = states.first { $0.value.threadID == thread && $0.value.isAuthority == true }?.key
                ?? states.first { $0.value.threadID == thread && $0.value.isAuthority == nil && $0.value.usageSource == .rolloutLog }?.key
            let selected = ids.sorted { a, b in
                let aAvailable = current[a]?.connectivity == .connected && next[a]?.observationStopped != true
                let bAvailable = current[b]?.connectivity == .connected && next[b]?.observationStopped != true
                if aAvailable != bAvailable { return aAvailable }
                let aDirect = next[a]?.usageSource == .directRelay
                let bDirect = next[b]?.usageSource == .directRelay
                if aDirect != bDirect { return aDirect }
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
            let sameSource = ids.filter { next[$0]?.usageSource == next[selected]?.usageSource && current[$0]?.connectivity == .connected }
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
        let key = ThreadKey(homeID: homePath, runID: state.runID, threadID: thread)
        let counter: UsageCounter
        if let counts = state.counts {
            counter = try UsageCounter(source: state.usageSource, epoch: state.epoch, baseline: usage(counts),
                                       lastKnownReasoningOutputTokens: state.lastKnownReasoningOutputTokens,
                                       lastKnownTotalTokens: state.lastKnownTotalTokens, isPartial: state.partial)
        } else {
            counter = UsageCounter(source: state.usageSource, epoch: state.epoch)
        }
        var monitor = ThreadMonitor(key: key, counter: counter)
        try monitor.setConnectivity(state.sourceDisconnected == true ? .disconnected : (state.observationStopped == true ? .degraded : .connected), at: now)
        return monitor
    }

    private func consume(_ data: Data, state: inout FileState, monitor: inout ThreadMonitor?, visible: inout VisibleWindow, historical: Bool, now: Double) throws {
        guard !data.isEmpty else { return }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String, let payload = object["payload"] as? [String: Any] else { throw CollectorError.invalidRecord }
        if state.usageSource == .directRelay {
            guard integer(object["hub_schema_version"]) == 1,
                  object["hub_source"] as? String == "direct-relay",
                  object["codex_home_id"] as? String == homeHash,
                  let run = object["run_id"] as? String, let runUUID = UUID(uuidString: run),
                  let expectedRun = state.runID, UUID(uuidString: expectedRun) == runUUID,
                  let thread = identifier(object["thread_id"]),
                  state.threadID == nil || state.threadID == thread,
                  let timestamp = object["timestamp"] as? String, timestamp.utf8.count <= 64,
                  ISO8601DateFormatter().date(from: timestamp) != nil,
                  let monotonic = object["received_monotonic_ns"] as? String,
                  !monotonic.isEmpty, monotonic.utf8.allSatisfy({ (48...57).contains($0) }), UInt64(monotonic) != nil,
                  type == "session_meta" || type == "event_msg" else { throw CollectorError.invalidRecord }
            if type == "session_meta" { guard payload["id"] as? String == thread else { throw CollectorError.invalidRecord } }
            state.runID = run
        }
        if type == "session_meta" {
            if state.usageSource == .rolloutLog { state.hookIdentityEligible = false }
            guard let id = identifier(payload["id"]) else { throw CollectorError.invalidRecord }
            guard state.threadID == nil || state.threadID == id else { throw CollectorError.invalidRecord }
            if state.usageSource == .directRelay {
                state.processes = try processMetadata(payload["processes"])
                if state.managedValidated == nil { state.managedValidated = true }
            }
            state.threadID = id
            if state.usageSource == .rolloutLog { state.hookIdentityEligible = payload["source"] as? String == "cli" }
            state.cwd = metadataString(payload["cwd"])
            if monitor == nil { monitor = try restoredMonitor(thread: id, state: state, at: now) }
            return
        }
        if type == "turn_context" {
            if let turn = identifier(payload["turn_id"]) { state.turnID = turn }
            state.cwd = metadataString(payload["cwd"]) ?? state.cwd
            state.model = metadataString(payload["model"]) ?? state.model
            consumeDetails("turn_context", payload: payload, state: &state)
            return
        }
        guard type == "event_msg", let event = payload["type"] as? String else { return }
        guard monitor != nil else { throw CollectorError.invalidRecord }
        if state.usageSource == .directRelay {
            if event == "measurement_gap" {
                guard let reason = payload["reason"] as? String,
                      ["observer_queue_overflow", "frame_bound", "upgrade_bound", "unsupported_upgrade", "unsupported_frame", "unsupported_message", "invalid_json", "invalid_identifier", "invalid_usage", "metadata_bound", "thread_bound", "metadata_unavailable", "connection_closed"].contains(reason) else { throw CollectorError.invalidRecord }
                visible.invalidate(reason: "observation_gap")
                state.observationStopped = true
                state.hasGap = true
                if let thread = state.threadID {
                    monitor = try restoredMonitor(thread: thread, state: state, at: now)
                    try monitor?.setConnectivity(.degraded, at: now)
                }
                return
            }
            if event == "hub_connection" {
                guard payload["state"] as? String == "disconnected" else { throw CollectorError.invalidRecord }
                visible.invalidate(reason: "source_disconnected")
                state.sourceDisconnected = true
                try monitor?.setConnectivity(.disconnected, at: now)
                return
            }
            guard state.observationStopped != true, state.sourceDisconnected != true else { throw CollectorError.invalidRecord }
            if event == "visible_count" || event == "visible_unavailable" {
                guard let turn = identifier(payload["turn_id"]), let item = identifier(payload["item_id"]) else { throw CollectorError.invalidRecord }
                guard !historical, monitor?.activeTurnID == turn else { return }
                guard let received = object["received_monotonic_ns"] as? String, let ns = UInt64(received),
                      Double(ns) / 1_000_000_000 <= now, now - Double(ns) / 1_000_000_000 <= 2 else {
                    visible.invalidate(reason: "buffered_records")
                    return
                }
                if event == "visible_unavailable" {
                    guard let reason = payload["reason"] as? String,
                          ["model_changed", "turn_boundary", "duplicate_start", "missing_turn_start", "unsupported_mapping", "message_bound", "nonempty_start", "missing_item_start", "tokenizer_unavailable", "work_bound"].contains(reason) else { throw CollectorError.invalidRecord }
                    visible.invalidate(reason: reason)
                    return
                }
                guard let count = integer(payload["count"]), count >= 0, count <= Int.max,
                      let complete = boolean(payload["complete_from_start"]), let final = boolean(payload["final"]),
                      boolean(payload["corrected"]) != nil, let mismatch = boolean(payload["text_mismatch"]),
                      let model = identifier(payload["model"]),
                      ["o1", "o3", "o4-mini", "gpt-5", "gpt-4.1", "gpt-4o"].contains(model),
                      payload["encoding"] as? String == "o200k_base" else { throw CollectorError.invalidRecord }
                state.model = model
                try visible.observe(itemID: item, count: Int(count), completeFromStart: complete,
                                    final: final, textMismatch: mismatch, at: now)
                if count > 0 { try monitor?.setGenerating(true, turnID: turn, at: now) }
                return
            }
            if event == "hub_tool_started" || event == "hub_tool_completed" {
                guard let turn = identifier(payload["turn_id"]), let item = identifier(payload["item_id"]),
                      let kind = payload["tool_kind"] as? String,
                      ["commandExecution", "fileChange", "mcpToolCall", "dynamicToolCall", "collabAgentToolCall", "webSearch", "imageGeneration"].contains(kind) else { throw CollectorError.invalidRecord }
                if !historical { try monitor?.setTool(item, running: event == "hub_tool_started", turnID: turn, at: now) }
                return
            }
            if event == "hub_approval_requested" || event == "hub_approval_resolved" {
                let request = try requestKey(payload["request_id"])
                if event == "hub_approval_requested" {
                    guard let turn = identifier(payload["turn_id"]) else { throw CollectorError.invalidRecord }
                    if !historical { try monitor?.setApproval(request, waiting: true, turnID: turn, at: now) }
                } else if !historical, let current = monitor, current.approvalIDs.contains(request), let turn = current.activeTurnID {
                    try monitor?.setApproval(request, waiting: false, turnID: turn, at: now)
                }
                return
            }
            if let status = payload["status"] {
                guard let status = status as? String, ["inProgress", "completed", "interrupted", "failed"].contains(status) else { throw CollectorError.invalidRecord }
            }
            guard ["task_started", "task_complete", "token_count"].contains(event), identifier(payload["turn_id"]) != nil else { throw CollectorError.invalidRecord }
        }
        switch event {
        case "task_started":
            guard let turn = identifier(payload["turn_id"]) else { throw CollectorError.invalidRecord }
            state.turnID = turn
            if !historical && monitor?.activeTurnID != turn {
                if monitor?.activeTurnID != nil, let thread = state.threadID {
                    state.hasGap = true
                    monitor = try restoredMonitor(thread: thread, state: state, at: now)
                    try monitor?.markGap(at: now)
                }
                visible = VisibleWindow()
                try monitor?.startTurn(turn, at: now)
            }
        case "task_complete", "turn_aborted":
            guard let turn = identifier(payload["turn_id"]) ?? state.turnID else { throw CollectorError.invalidRecord }
            state.turnID = turn
            let status = payload["status"] as? String
            let outcome: TurnOutcome = status == "failed" ? .failed : (status == "interrupted" || event == "turn_aborted" ? .interrupted : .completed)
            if !historical {
                try monitor?.finishTurn(turn, outcome: outcome, at: now)
                if monitor?.activeTurnID == nil { visible.invalidate(reason: "no_active_turn", partial: false) }
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
            if state.usageSource == .directRelay {
                guard ["input_tokens", "cached_input_tokens", "output_tokens", "reasoning_output_tokens", "total_tokens"].allSatisfy({ counts[$0] != nil }) else { throw CollectorError.invalidRecord }
            }
            let total = try usage(counts)
            if let turn = state.usageSource == .directRelay ? identifier(payload["turn_id"]) : state.turnID {
                try monitor?.observeUsage(total, turnID: turn, source: state.usageSource, epoch: state.epoch, at: now, historical: historical)
            } else {
                if let current = monitor {
                    var counter = current.counter
                    _ = counter.observe(total, source: state.usageSource, epoch: state.epoch)
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

    private func hookEvent(_ data: Data, installation: String, streamID: String,
                           historical: Bool, now: Double, wall: Double) throws -> HookEvent? {
        guard !data.isEmpty else { return nil }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              integer(object["hub_schema_version"]) == 1, object["hub_source"] as? String == "hook",
              object["codex_home_id"] as? String == homeHash,
              let installed = object["installation_id"] as? String,
              UUID(uuidString: installed) == UUID(uuidString: installation),
              let session = hookIdentifier(object["session_id"]),
              let name = object["hook_event_name"] as? String,
              ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "Interrupt", "SessionEnd"].contains(name),
              let timestamp = object["timestamp"] as? String, timestamp.utf8.count <= 64,
              let date = ISO8601DateFormatter().date(from: timestamp),
              let rawTime = object["received_monotonic_ns"] as? String, rawTime.utf8.count <= 20,
              !rawTime.isEmpty, rawTime.utf8.allSatisfy({ (48...57).contains($0) }),
              let nanoseconds = UInt64(rawTime) else { throw CollectorError.invalidRecord }
        let turn = hookIdentifier(object["turn_id"])
        let tool = hookIdentifier(object["tool_use_id"])
        guard name == "SessionStart" || name == "SessionEnd" || turn != nil,
              (name != "PreToolUse" && name != "PostToolUse") || tool != nil else { throw CollectorError.invalidRecord }
        let received = Double(nanoseconds) / 1_000_000_000
        guard !historical, received <= now, now - received <= 2,
              abs(wall - date.timeIntervalSince1970) <= 2 else { return nil }
        return HookEvent(streamID: streamID, sessionID: session, turnID: turn, toolID: tool,
                         name: name, receivedAt: received)
    }

    private func hookIdentifier(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty, value.utf8.count <= 128,
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        return value
    }

    private func reconcileHooks(_ events: [HookEvent], states next: [String: FileState],
                                monitors current: [String: ThreadMonitor], seen: Set<String>,
                                invalidStreams: Set<String>, now: Double) -> [String: HookState] {
        func eligible(_ id: String) -> Bool {
            guard let state = next[id], let monitor = current[id],
                  state.usageSource == .rolloutLog, state.isAuthority == true,
                  state.hookIdentityEligible == true, state.reconciliationPeer == nil,
                  monitor.connectivity == .connected, let turn = monitor.activeTurnID,
                  monitors[id]?.activeTurnID == turn, states[id]?.isAuthority == true,
                  states[id]?.epoch == state.epoch, !recovering.contains(id), now - lastFrame <= 5 else { return false }
            return true
        }
        var result = hookStates.filter { id, hook in
            eligible(id) && hook.turnID == current[id]?.activeTurnID && now - hook.receivedAt <= 10 &&
                seen.contains(hook.streamID) && !invalidStreams.contains(hook.streamID)
        }
        var conflicts: Set<String> = []
        for event in events.sorted(by: { $0.receivedAt < $1.receivedAt }) {
            guard !invalidStreams.contains(event.streamID), event.name != "SessionStart" else { continue }
            // A unique verified CLI transcript plus the actual active turn is the mapping proof.
            let matches = next.filter { $0.value.sourceName == "rollout-log" && $0.value.threadID == event.sessionID }
            guard matches.count == 1, let id = matches.first?.key, eligible(id), !conflicts.contains(id),
                  let turn = current[id]?.activeTurnID,
                  event.turnID == turn || (event.name == "SessionEnd" && event.turnID == nil),
                  event.receivedAt >= (current[id]?.turns[turn]?.startedAt ?? .infinity) else { continue }
            if let previous = result[id], previous.streamID != event.streamID {
                result.removeValue(forKey: id)
                conflicts.insert(id)
                continue
            }
            var hook = result[id] ?? HookState(streamID: event.streamID, turnID: turn, receivedAt: event.receivedAt)
            guard event.receivedAt >= hook.receivedAt else { continue }
            hook.receivedAt = event.receivedAt
            switch event.name {
            case "PreToolUse":
                if let tool = event.toolID { hook.tools.insert(tool) }
                hook.completionCandidate = false
            case "PostToolUse":
                if let tool = event.toolID { hook.tools.remove(tool) }
                hook.completionCandidate = false
            case "UserPromptSubmit": hook.completionCandidate = false
            case "Stop", "Interrupt", "SessionEnd": hook.completionCandidate = true
            default: break
            }
            guard hook.tools.count <= 256 else {
                result.removeValue(forKey: id); conflicts.insert(id); continue
            }
            result[id] = hook
        }
        return result
    }

    private func usage(_ counts: [String: Int]) throws -> TokenUsage {
        guard let output = counts["output_tokens"] else { throw CollectorError.invalidRecord }
        return try TokenUsage(outputTokens: output, reasoningOutputTokens: counts["reasoning_output_tokens"],
                              inputTokens: counts["input_tokens"] ?? 0, cachedInputTokens: counts["cached_input_tokens"] ?? 0,
                              cacheWriteInputTokens: counts["cache_write_input_tokens"] ?? 0, totalTokens: counts["total_tokens"])
    }
    private func boolean(_ value: Any?) -> Bool? {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value.boolValue
    }

    private func consumeDetails(_ type: String, payload: [String: Any], state: inout FileState) {
        if state.usageDetails == nil { state.usageDetails = SessionUsageDetails() }
        if type == "turn_context" {
            state.usageDetails?.reasoningEffort = identifier(payload["effort"]).flatMap { $0.utf8.count <= 32 ? $0 : nil }
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

    private func requestKey(_ value: Any?) throws -> String {
        if let value = identifier(value) { return "string:" + value }
        if let value = integer(value) { return "integer:" + String(value) }
        throw CollectorError.invalidRecord
    }

    private func processMetadata(_ value: Any?) throws -> [ManagedProcessInfo] {
        guard let roles = value as? [String: Any] else { throw CollectorError.invalidRecord }
        return try [ManagedProcessInfo.Role.tui, .appServer, .relay].map { role in
            guard let fields = roles[role.rawValue] as? [String: Any],
                  let pid = integer(fields["pid"]), pid > 0, pid <= Int32.max,
                  let seconds = integer(fields["start_seconds"]), seconds >= 0,
                  let micros = integer(fields["start_microseconds"]), (0..<1_000_000).contains(micros) else { throw CollectorError.invalidRecord }
            return ManagedProcessInfo(role: role, pid: Int32(pid), startSeconds: UInt64(seconds), startMicroseconds: UInt64(micros))
        }
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
