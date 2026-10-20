import Foundation
import Darwin
import CodexHubCore

/// Read-only Claude Code collector. Live processes come from `sessions/<pid>.json`; usage comes from the
/// session transcript's per-message `usage`. Rates use the same tool-excluded interval as Codex: the time
/// from the last user/tool_result entry to the last block of the message.
public actor ClaudeCollector {
    private struct Counts {
        var input = 0, output = 0, cacheRead = 0, cacheWrite = 0
        var reasoning: Int?

        init() {}
        init(_ usage: [String: Any]) {
            input = Self.count(usage["input_tokens"]) ?? 0
            output = Self.count(usage["output_tokens"]) ?? 0
            cacheRead = Self.count(usage["cache_read_input_tokens"]) ?? 0
            cacheWrite = Self.count(usage["cache_creation_input_tokens"]) ?? 0
            reasoning = (usage["output_tokens_details"] as? [String: Any]).flatMap { Self.count($0["thinking_tokens"]) }
        }
        static func count(_ value: Any?) -> Int? {
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue.isFinite, n.doubleValue >= 0, n.doubleValue <= 1e12 else { return nil }
            return Int(n.doubleValue)
        }
        /// Streamed blocks repeat one message's usage; never let a later block lower it.
        mutating func raise(to other: Counts) {
            input = max(input, other.input); output = max(output, other.output)
            cacheRead = max(cacheRead, other.cacheRead); cacheWrite = max(cacheWrite, other.cacheWrite)
            if let value = other.reasoning { reasoning = max(reasoning ?? 0, value) }
        }
        mutating func add(_ other: Counts) {
            input += other.input; output += other.output
            cacheRead += other.cacheRead; cacheWrite += other.cacheWrite
            if let value = other.reasoning { reasoning = (reasoning ?? 0) + value }
        }
        /// Claude's `input_tokens` excludes cache; Codex's includes it, so present the same meaning.
        func tokenUsage() throws -> TokenUsage {
            try TokenUsage(outputTokens: output, reasoningOutputTokens: reasoning,
                           inputTokens: input + cacheRead + cacheWrite,
                           cachedInputTokens: cacheRead, cacheWriteInputTokens: cacheWrite)
        }
    }

    private struct Message {
        var counts = Counts()
        var start: Double?
        var last: Double
        var stop: String?
        var lastBlock: String?
        var done = false
    }

    private struct Completion {
        let usage: TokenUsage
        let seconds: Double?
        let historical: Bool
    }

    private final class Tracked {
        let id: String
        let path: String
        var fileID: String
        let process: ProcessIdentity
        let root: Bool
        /// The session this subagent belongs to; nil for a session's own transcript.
        let parent: String?
        var monitor: ThreadMonitor
        let epoch: String
        var offset: Int64 = 0
        var carry = Data()
        var skipping = false
        var totals = Counts()
        var messages: [String: Message] = [:]
        var order: [String] = []
        var lastUser: Double?
        var pendingTools: Set<String> = []
        var endedTools: Set<String> = []
        var completions: [Completion] = []
        var historicalPass = true
        var loaded = false
        var hasGap = false
        var turns = 0
        var cwd: String?
        var model: String?
        var effort: String?
        var tier: ServiceTier?
        /// Input of the latest request (input + cache reads + cache writes), like Claude Code's own context gauge.
        var contextTokens: Int?
        var updated: Double

        init(id: String, path: String, fileID: String, process: ProcessIdentity, root: Bool, parent: String? = nil, epoch: String, monitor: ThreadMonitor, updated: Double) {
            self.epoch = epoch; self.id = id; self.path = path; self.fileID = fileID; self.process = process
            self.root = root; self.parent = parent; self.monitor = monitor; self.updated = updated
        }
    }

    private let home: URL
    private let homeID: String
    private let processStart: @Sendable (Int32) -> (identity: ProcessIdentity, seconds: Double)?
    private let iso = ISO8601DateFormatter()
    private var tracked: [String: Tracked] = [:]
    private var lastFrame = 0.0
    private let maximumHistory: Int64 = 64 * 1_048_576
    private let maximumLine = 16 * 1_048_576
    private let remembered = 64
    private let maximumSubagents = 64
    /// Windows from Claude Code's model catalog, reloaded when its newest file changes.
    private var catalog: (path: String, modified: Double, windows: [String: Int]) = ("", 0, [:])
    /// A finished subagent untouched for this long no longer belongs on a live session's list.
    private let subagentWindow = 1_800.0

    public init(claudeHome: URL,
                processStart: @escaping @Sendable (Int32) -> (identity: ProcessIdentity, seconds: Double)? = ClaudeCollector.liveProcessStart) {
        home = claudeHome.standardizedFileURL
        homeID = "claude:" + home.path
        self.processStart = processStart
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    public static func defaultHome() -> URL {
        if let path = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }

    /// `time` is the caller's monotonic frame time so every provider shares one clock.
    @discardableResult
    public func refresh(at time: Double, wall: Double = Date().timeIntervalSince1970) -> CollectorSnapshot {
        let now = max(time, lastFrame)
        refreshCatalog()
        let gap = lastFrame > 0 && now - lastFrame > 5
        lastFrame = now
        var diagnostics: [CollectorDiagnostic] = []
        guard let directory = try? SafeDirectory(home) else {
            tracked.removeAll()
            return CollectorSnapshot(sessions: [], diagnostics: [], observedAt: now)
        }
        var live: Set<String> = []
        var snapshots: [SessionSnapshot] = []
        for name in sessionFiles() {
            guard let entry = liveEntry(directory, name: name, wall: wall) else { continue }
            live.insert(entry.sessionID)
            let watched = tracked[entry.sessionID]?.loaded == true
            do {
                guard let session = try track(directory, entry: entry, now: now, wall: wall, gap: gap) else { continue }
                snapshots.append(snapshot(session))
                for sub in trackSubagents(directory, parent: session, entry: entry, now: now, wall: wall, gap: gap, parentWatched: watched) {
                    live.insert(sub.id)
                    snapshots.append(snapshot(sub))
                }
            } catch {
                tracked.removeValue(forKey: entry.sessionID)
                diagnostics.append(CollectorDiagnostic(fileIdentity: nil, error: (error as? CollectorError) ?? .invalidRecord))
            }
        }
        tracked = tracked.filter { live.contains($0.key) }
        return CollectorSnapshot(sessions: snapshots.sorted { $0.id < $1.id }, diagnostics: diagnostics, observedAt: now)
    }

    private struct Entry {
        let sessionID: String
        let cwd: String?
        let status: String?
        let process: ProcessIdentity
        let root: Bool
    }

    private func sessionFiles() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent("sessions").path)) ?? []
        return names.filter { $0.hasSuffix(".json") && Int32($0.dropLast(5)) != nil }.sorted().prefix(256).map { $0 }
    }

    /// A pid file only counts while that exact process (pid + start time) is still alive.
    private func liveEntry(_ directory: SafeDirectory, name: String, wall: Double) -> Entry? {
        guard let fd = try? directory.openFile("sessions/" + name) else { return nil }
        defer { close(fd) }
        guard let data = readChunk(fd, at: 0, limit: 65_536), !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = (object["pid"] as? NSNumber).map({ Int32(truncatingIfNeeded: $0.intValue) }),
              name == "\(pid).json",
              let session = object["sessionId"] as? String, UUID(uuidString: session) != nil,
              object["kind"] as? String == "interactive",
              let started = (object["procStart"] as? String).flatMap(Self.parseProcStart),
              let process = processStart(pid), abs(process.seconds - started) <= 2 else { return nil }
        return Entry(sessionID: session, cwd: object["cwd"] as? String, status: object["status"] as? String,
                     process: process.identity, root: object["entrypoint"] as? String == "cli")
    }

    private func track(_ directory: SafeDirectory, entry: Entry, now: Double, wall: Double, gap: Bool) throws -> Tracked? {
        var session = tracked[entry.sessionID]
        let path = try session?.path ?? locate(directory, sessionID: entry.sessionID, cwd: entry.cwd)
        guard let path else { return nil }
        let fd = try directory.openFile(path)
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw CollectorError.inaccessibleSource }
        let fileID = "\(info.st_dev):\(info.st_ino)"
        let size = Int64(info.st_size)
        if let current = session, current.fileID != fileID || size < current.offset || current.process != entry.process {
            session = nil
        }
        let t: Tracked
        if let session { t = session } else {
            let epoch = UUID().uuidString
            var monitor = ThreadMonitor(key: ThreadKey(homeID: homeID, runID: nil, threadID: entry.sessionID),
                                        source: .rolloutLog, epoch: epoch)
            try monitor.setConnectivity(.connected, at: now)
            t = Tracked(id: entry.sessionID, path: path, fileID: fileID, process: entry.process, root: entry.root,
                        epoch: epoch, monitor: monitor, updated: wall)
            t.cwd = entry.cwd
            if size > maximumHistory { t.offset = size; t.hasGap = true }
            tracked[entry.sessionID] = t
        }
        t.historicalPass = !t.loaded || gap
        if gap { t.hasGap = true; try t.monitor.markGap(at: now) }
        let before = t.offset
        pump(t, fd: fd, size: size)
        if t.offset != before { t.updated = wall }
        try apply(t, status: entry.status, now: now)
        return t
    }

    /// Claude names each project directory after the working directory; fall back to a bounded scan.
    private func locate(_ directory: SafeDirectory, sessionID: String, cwd: String?) throws -> String? {
        var candidates: [String] = []
        if let cwd { candidates.append(String(cwd.unicodeScalars.map { $0.isASCII && (CharacterSet.alphanumerics.contains($0)) ? Character($0) : "-" })) }
        let all = (try? FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent("projects").path)) ?? []
        candidates += all.sorted().prefix(2_000).filter { !candidates.contains($0) && !$0.contains("/") }
        for slug in candidates {
            let relative = "projects/\(slug)/\(sessionID).jsonl"
            if let fd = try? directory.openFile(relative) { close(fd); return relative }
        }
        return nil
    }

    private func readChunk(_ fd: Int32, at offset: Int64, limit: Int) -> Data? {
        var buffer = [UInt8](repeating: 0, count: limit)
        let count = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, limit, off_t(offset)) }
        return count >= 0 ? Data(buffer[..<count]) : nil
    }

    private func pump(_ t: Tracked, fd: Int32, size: Int64) {
        var passes = 0
        while t.offset < size, passes < (t.historicalPass ? 512 : 8) {
            passes += 1
            guard let data = readChunk(fd, at: t.offset, limit: 1_048_576), !data.isEmpty else { break }
            t.offset += Int64(data.count)
            var start = data.startIndex
            while let newline = data[start...].firstIndex(of: 0x0A) {
                if t.skipping { t.skipping = false } else {
                    t.carry.append(data[start..<newline])
                    handle(t.carry, t)
                }
                t.carry.removeAll(keepingCapacity: true)
                start = data.index(after: newline)
            }
            if !t.skipping {
                t.carry.append(data[start...])
                if t.carry.count > maximumLine { t.carry.removeAll(); t.skipping = true; t.hasGap = true }
            }
        }
    }

    private static let assistantMarker = Data("\"type\":\"assistant\"".utf8)
    private static let userMarker = Data("\"type\":\"user\"".utf8)

    private func handle(_ line: Data, _ t: Tracked) {
        guard line.range(of: Self.assistantMarker) != nil || line.range(of: Self.userMarker) != nil,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String, type == "assistant" || type == "user",
              t.parent != nil || object["isSidechain"] as? Bool != true,
              let stamp = object["timestamp"] as? String, let time = iso.date(from: stamp)?.timeIntervalSince1970 else { return }
        if let cwd = object["cwd"] as? String, !cwd.isEmpty { t.cwd = cwd }
        let message = object["message"] as? [String: Any]
        let blocks = message?["content"] as? [[String: Any]] ?? []
        if type == "user" {
            t.lastUser = time
            for block in blocks where block["type"] as? String == "tool_result" {
                if let id = block["tool_use_id"] as? String, t.pendingTools.remove(id) != nil { t.endedTools.insert(id) }
            }
            return
        }
        guard let message, let id = message["id"] as? String, !id.isEmpty, id.utf8.count <= 128 else { return }
        if t.messages[id] == nil {
            // A new message id means every earlier one has finished streaming.
            for earlier in t.order where t.messages[earlier]?.done == false { complete(earlier, t) }
            t.messages[id] = Message(start: t.lastUser, last: time)
            t.order.append(id)
        }
        guard var current = t.messages[id], !current.done else { return }
        current.last = max(current.last, time)
        let usage = message["usage"] as? [String: Any]
        if let usage { current.counts.raise(to: Counts(usage)) }
        current.stop = (message["stop_reason"] as? String) ?? current.stop
        if let kind = blocks.last?["type"] as? String { current.lastBlock = kind }
        for block in blocks where block["type"] as? String == "tool_use" {
            if let tool = block["id"] as? String, t.pendingTools.count < 256 { t.pendingTools.insert(tool) }
        }
        if let model = message["model"] as? String, !model.hasPrefix("<") { t.model = model }
        if let effort = object["effort"] as? String { t.effort = effort }
        if let tier = usage?["service_tier"] as? String { t.tier = ServiceTier(rawValue: tier == "standard" ? "default" : tier) }
        t.messages[id] = current
        t.contextTokens = current.counts.input + current.counts.cacheRead + current.counts.cacheWrite
        // stop_reason is final on every block, so the last block is the one that ends the message.
        if let stop = current.stop, stop == "tool_use" ? current.lastBlock == "tool_use" : current.lastBlock == "text" {
            complete(id, t)
        }
    }

    private func complete(_ id: String, _ t: Tracked) {
        guard var message = t.messages[id], !message.done else { return }
        message.done = true
        t.messages[id] = message
        t.totals.add(message.counts)
        guard let usage = try? t.totals.tokenUsage() else { return }
        var seconds: Double?
        if let start = message.start, message.last > start, message.last - start < 3_600 { seconds = message.last - start }
        t.completions.append(Completion(usage: usage, seconds: seconds, historical: t.historicalPass))
        while t.order.count > remembered, let oldest = t.order.first, t.messages[oldest]?.done == true {
            t.order.removeFirst(); t.messages.removeValue(forKey: oldest)
        }
    }

    private func apply(_ t: Tracked, status: String?, now: Double) throws {
        let idle = status == "idle"
        if !t.loaded {
            for id in t.order where t.messages[id]?.done == false { complete(id, t) }
            t.completions.removeAll()
            let epoch = t.epoch
            try t.monitor.observeUsage(try t.totals.tokenUsage(), turnID: "history", source: .rolloutLog,
                                       epoch: epoch, at: now, historical: true)
            t.loaded = true
            if status == "busy" {
                t.turns += 1
                try t.monitor.startTurn("turn-\(t.turns)", at: now)
            } else if idle {
                t.turns += 1
                try t.monitor.startTurn("turn-\(t.turns)", at: now)
                try t.monitor.finishTurn("turn-\(t.turns)", outcome: .completed, at: now)
                t.pendingTools.removeAll()
            }
            t.endedTools.removeAll()
            syncTools(t, now: now)
            return
        }
        if idle { for id in t.order where t.messages[id]?.done == false { complete(id, t) } }
        if t.monitor.activeTurnID == nil, (status != nil && !idle) || !t.completions.isEmpty {
            t.turns += 1
            try t.monitor.startTurn("turn-\(t.turns)", at: now)
        }
        syncTools(t, now: now)
        let epoch = t.epoch
        for completion in t.completions {
            let turn = t.monitor.activeTurnID ?? "history"
            try t.monitor.observeUsage(completion.usage, turnID: turn, source: .rolloutLog, epoch: epoch, at: now,
                                       historical: completion.historical,
                                       rateInterval: .excludingTools(completion.seconds))
        }
        t.completions.removeAll()
        if idle, let turn = t.monitor.activeTurnID {
            try t.monitor.finishTurn(turn, outcome: .completed, at: now)
            t.pendingTools.removeAll()
        }
    }

    private func syncTools(_ t: Tracked, now: Double) {
        guard let turn = t.monitor.activeTurnID else { return }
        for id in t.pendingTools { try? t.monitor.setTool(id, running: true, turnID: turn, at: now) }
        for id in t.endedTools { try? t.monitor.setTool(id, running: false, turnID: turn, at: now) }
        t.endedTools.removeAll()
    }

    /// Claude Code writes each subagent's transcript next to the session's, as `<session>/subagents/agent-<id>.jsonl`
    /// with an `agent-<id>.meta.json` that says when it finished. Each one is its own session, linked to its parent
    /// like a Codex auxiliary session: its tokens and speed are not added to the parent's.
    private func trackSubagents(_ directory: SafeDirectory, parent: Tracked, entry: Entry, now: Double, wall: Double, gap: Bool, parentWatched: Bool) -> [Tracked] {
        let folder = String(parent.path.dropLast(".jsonl".count)) + "/subagents"
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent(folder).path)) ?? [])
            .filter { $0.hasPrefix("agent-") && $0.hasSuffix(".jsonl") && !$0.contains("/") }.sorted().prefix(maximumSubagents)
        return names.compactMap { name in
            let agent = String(name.dropFirst("agent-".count).dropLast(".jsonl".count))
            guard !agent.isEmpty else { return nil }
            return trackSubagent(directory, folder: folder, name: name, agent: agent, parent: parent, entry: entry, now: now, wall: wall, gap: gap, parentWatched: parentWatched)
        }
    }

    private func trackSubagent(_ directory: SafeDirectory, folder: String, name: String, agent: String, parent: Tracked,
                               entry: Entry, now: Double, wall: Double, gap: Bool, parentWatched: Bool) -> Tracked? {
        let key = parent.id + "/" + agent
        guard let fd = try? directory.openFile(folder + "/" + name) else { tracked.removeValue(forKey: key); return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { return nil }
        let modified = Double(info.st_mtimespec.tv_sec)
        let finished = subagentFinished(directory, folder: folder, name: name, modified: modified, wall: wall)
        if finished && modified < wall - subagentWindow { tracked.removeValue(forKey: key); return nil }
        let fileID = "\(info.st_dev):\(info.st_ino)", size = Int64(info.st_size)
        var session = tracked[key]
        if let current = session, current.fileID != fileID || size < current.offset { session = nil }
        let t: Tracked
        if let session { t = session } else {
            let epoch = UUID().uuidString
            var monitor = ThreadMonitor(key: ThreadKey(homeID: homeID, runID: nil, threadID: agent), source: .rolloutLog, epoch: epoch)
            guard (try? monitor.setConnectivity(.connected, at: now)) != nil else { return nil }
            t = Tracked(id: key, path: folder + "/" + name, fileID: fileID, process: entry.process, root: false, parent: entry.sessionID,
                        epoch: epoch, monitor: monitor, updated: wall)
            if size > maximumHistory { t.offset = size; t.hasGap = true }
            // A subagent that starts while its session is already being watched is live; one found at startup is history.
            if parentWatched && !gap {
                t.loaded = true
                // Like a loaded history, start from a zero baseline so its first message counts as new output.
                if let zero = try? t.totals.tokenUsage() {
                    try? t.monitor.observeUsage(zero, turnID: "history", source: .rolloutLog, epoch: epoch, at: now, historical: true)
                }
            }
            tracked[key] = t
        }
        t.historicalPass = !t.loaded || gap
        if gap { t.hasGap = true; try? t.monitor.markGap(at: now) }
        let before = t.offset
        pump(t, fd: fd, size: size)
        if t.offset != before { t.updated = wall }
        guard (try? apply(t, status: finished ? "idle" : "busy", now: now)) != nil else { tracked.removeValue(forKey: key); return nil }
        return t
    }

    /// The meta file says it outright; without one, a transcript that stopped growing counts as finished.
    private func subagentFinished(_ directory: SafeDirectory, folder: String, name: String, modified: Double, wall: Double) -> Bool {
        let meta = folder + "/" + String(name.dropLast(".jsonl".count)) + ".meta.json"
        if let fd = try? directory.openFile(meta) {
            defer { close(fd) }
            if let data = readChunk(fd, at: 0, limit: 16_384),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let finished = object["finished"] as? Bool { return finished }
        }
        return wall - modified > 120
    }

    private func snapshot(_ t: Tracked) -> SessionSnapshot {
        SessionSnapshot(id: "claude:" + t.id, cwd: t.cwd, model: t.model, monitor: t.monitor, lastObserved: t.updated,
                        hasGap: t.hasGap, sourceReconciliationPending: false, activity: t.monitor.activity,
                        observedCLIRoot: t.root, parentThreadID: t.parent,
                        usageDetails: SessionUsageDetails(reasoningEffort: t.effort, serviceTier: t.tier, contextTokens: t.contextTokens, contextWindow: contextWindow(t)),
                        provider: .claude, process: t.process)
    }

    private func refreshCatalog() {
        let directory = home.appendingPathComponent("cache/model-catalog")
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? [])
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> (URL, Double, Int)? in
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                      let modified = values.contentModificationDate?.timeIntervalSince1970, let size = values.fileSize else { return nil }
                return (url, modified, size)
            }
        guard let newest = files.max(by: { $0.1 < $1.1 }), newest.2 <= 4 * 1_048_576 else { catalog = ("", 0, [:]); return }
        if catalog.path == newest.0.path, catalog.modified == newest.1 { return }
        catalog = (newest.0.path, newest.1, (try? Data(contentsOf: newest.0)).map(ModelContext.windows(fromCatalog:)) ?? [:])
    }

    /// The window of the session's model, from the catalog or else the documented table; dropped when the observed context already exceeds it, since then the table is wrong.
    private func contextWindow(_ t: Tracked) -> Int? {
        guard let window = t.model.flatMap({ ModelContext.window(forClaudeModel: $0, catalog: catalog.windows) }) else { return nil }
        return (t.contextTokens ?? 0) <= window ? window : nil
    }

    /// `procStart` is written in UTC, e.g. "Sat Oct 17 18:18:23 2026".
    static func parseProcStart(_ text: String) -> Double? {
        var parts = tm()
        guard text.withCString({ strptime($0, "%a %b %e %H:%M:%S %Y", &parts) }) != nil else { return nil }
        return Double(timegm(&parts))
    }

    public static let liveProcessStart: @Sendable (Int32) -> (identity: ProcessIdentity, seconds: Double)? = { pid in
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_uid == getuid(), info.pbi_status != SZOMB else { return nil }
        let identity = ProcessIdentity(pid: pid, osStartTime: "\(info.pbi_start_tvsec).\(String(format: "%06llu", info.pbi_start_tvusec))")
        return (identity, Double(info.pbi_start_tvsec))
    }
}
