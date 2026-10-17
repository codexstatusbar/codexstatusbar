public struct ThreadKey: Hashable, Sendable {
    public let homeID: String
    public let runID: String?
    public let threadID: String
    public init(homeID: String, runID: String?, threadID: String) {
        self.homeID = homeID
        self.runID = runID
        self.threadID = threadID
    }
}

public struct ProcessIdentity: Hashable, Sendable {
    public let pid: Int32
    public let osStartTime: String
    public init(pid: Int32, osStartTime: String) {
        self.pid = pid
        self.osStartTime = osStartTime
    }
}

public enum ServiceTier: String, Codable, Sendable {
    case automatic = "auto", standard = "default", flex, scale, priority, fast, ultrafast
    public var displayName: String {
        switch self {
        case .fast, .priority: "Fast"
        case .ultrafast: "Ultrafast"
        case .automatic: "Auto"
        case .standard: "Standard"
        case .flex: "Flex"
        case .scale: "Scale"
        }
    }
}

public enum Connectivity: String, Sendable { case connected, degraded, disconnected, unknown }
public enum Activity: String, Sendable { case idle, working, generating, toolRunning, approvalWait, unknown }
public enum Measurement: String, Sendable { case warmingUp, estimated, reported, partial, unavailable }
public enum TurnOutcome: String, Sendable { case completed, interrupted, failed }

public struct TurnRecord: Sendable {
    public fileprivate(set) var startedAt: Double?
    public fileprivate(set) var endedAt: Double?
    public fileprivate(set) var outcome: TurnOutcome?
    public fileprivate(set) var outputTokens = 0
    public fileprivate(set) var isComplete: Bool
    public var average: Double? {
        guard isComplete, let startedAt, let endedAt, endedAt > startedAt else { return nil }
        return Double(outputTokens) / (endedAt - startedAt)
    }
}

public struct ThreadMonitor: Sendable {
    public let key: ThreadKey
    public private(set) var counter: UsageCounter
    public private(set) var connectivity: Connectivity = .unknown
    public private(set) var activeTurnID: String?
    public private(set) var turns: [String: TurnRecord] = [:]
    public private(set) var toolIDs: Set<String> = []
    public private(set) var approvalIDs: Set<String> = []
    private var observedIdle = false
    private var generating = false
    private var hasCurrentReport = false
    private var lastTime: Double = 0
    private var needsBaseline = false
    private var samples: [(time: Double, tokens: Int)] = []

    public init(key: ThreadKey, source: UsageSource, epoch: String, verifiedEmptyThread: Bool = false) {
        self.key = key
        counter = UsageCounter(source: source, epoch: epoch, verifiedEmptyThread: verifiedEmptyThread)
    }

    /// Restores usage only; activity, turn history and rate samples remain unknown/empty.
    public init(key: ThreadKey, counter: UsageCounter) {
        self.key = key
        self.counter = counter
    }

    public var activity: Activity {
        guard activeTurnID != nil else { return observedIdle ? .idle : .unknown }
        if !approvalIDs.isEmpty { return .approvalWait }
        if !toolIDs.isEmpty { return .toolRunning }
        return generating ? .generating : .working
    }

    public var measurement: Measurement {
        if counter.isPartial { return .partial }
        guard connectivity == .connected, !needsBaseline, counter.baseline != nil else { return .unavailable }
        return activeTurnID != nil && !hasCurrentReport ? .warmingUp : .reported
    }

    private func validateTime(_ time: Double) throws {
        guard time.isFinite, time >= lastTime else { throw CoreError.invalidTime }
    }

    private mutating func advance(_ time: Double) throws {
        try validateTime(time)
        lastTime = time
        samples.removeAll { $0.time <= time - 10 }
    }

    public mutating func startTurn(_ id: String, at time: Double) throws {
        try validateTime(time)
        guard turns[id] == nil, activeTurnID == nil else { throw CoreError.invalidTransition }
        try advance(time)
        activeTurnID = id
        observedIdle = false
        generating = false
        hasCurrentReport = false
        samples.removeAll()
        turns[id] = TurnRecord(startedAt: time, isComplete: counter.baseline != nil && !counter.isPartial && !needsBaseline)
    }

    public mutating func finishTurn(_ id: String, outcome: TurnOutcome, at time: Double) throws {
        try advance(time)
        if turns[id]?.outcome != nil { return }
        var record = turns[id] ?? TurnRecord(isComplete: false)
        record.endedAt = time
        record.outcome = outcome
        turns[id] = record
        if activeTurnID == id || activeTurnID == nil {
            activeTurnID = nil
            observedIdle = true
            generating = false
            toolIDs.removeAll()
            approvalIDs.removeAll()
            samples.removeAll()
        }
    }

    public mutating func setTool(_ id: String, running: Bool, turnID: String, at time: Double) throws {
        try advance(time)
        guard turnID == activeTurnID else { return }
        if running { toolIDs.insert(id) } else { toolIDs.remove(id) }
    }

    public mutating func setApproval(_ id: String, waiting: Bool, turnID: String, at time: Double) throws {
        try advance(time)
        guard turnID == activeTurnID else { return }
        if waiting { approvalIDs.insert(id) } else { approvalIDs.remove(id) }
    }

    /// Set only from an observed agent-output event, never inferred from usage or elapsed time.
    public mutating func setGenerating(_ value: Bool, turnID: String, at time: Double) throws {
        try advance(time)
        guard turnID == activeTurnID else { return }
        generating = value
    }

    public mutating func setConnectivity(_ value: Connectivity, at time: Double) throws {
        try advance(time)
        if value != .connected || (connectivity != .connected && counter.baseline != nil && !turns.isEmpty) {
            invalidateWindow()
        }
        connectivity = value
    }

    /// Call on sleep/resume or an observation gap before processing buffered events.
    public mutating func markGap(at time: Double) throws {
        try advance(time)
        invalidateWindow()
    }

    private mutating func invalidateWindow() {
        hasCurrentReport = false
        samples.removeAll()
        needsBaseline = true
        if let id = activeTurnID { turns[id]?.isComplete = false }
    }

    public mutating func reconcile(source: UsageSource, epoch: String, baseline: TokenUsage, at time: Double) throws {
        try advance(time)
        invalidateWindow()
        counter.reconcile(source: source, epoch: epoch, baseline: baseline)
        needsBaseline = false
    }

    @discardableResult
    public mutating func observeUsage(_ total: TokenUsage, turnID: String, source: UsageSource,
                                      epoch: String, at time: Double, historical: Bool = false) throws -> UsageObservation {
        try validateTime(time)
        var nextCounter = counter
        let result = nextCounter.observe(total, source: source, epoch: epoch)
        if case .delta(let delta) = result {
            let (_, overflow) = (turns[turnID]?.outputTokens ?? 0).addingReportingOverflow(delta)
            guard !overflow else { throw CoreError.invalidUsage }
        }
        try advance(time)
        counter = nextCounter
        switch result {
        case .baseline:
            needsBaseline = false
            if let id = activeTurnID { turns[id]?.isComplete = false }
        case .regression, .suspended:
            invalidateWindow()
        case .delta(let delta):
            var record = turns[turnID] ?? TurnRecord(isComplete: false)
            record.outputTokens += delta
            if historical || needsBaseline { record.isComplete = false }
            turns[turnID] = record
            if !historical && !needsBaseline && connectivity == .connected && activeTurnID == turnID {
                hasCurrentReport = true
                if delta > 0 { samples.append((time, delta)) }
            }
            needsBaseline = false
        case .secondarySource, .wrongEpoch: break
        }
        return result
    }

    /// Fixed PRD reported window; all rows must use the same injected frame time.
    public func reportedRate(at time: Double) throws -> Double? {
        try validateTime(time)
        guard activeTurnID != nil, measurement == .reported else { return nil }
        return samples.filter { $0.time > time - 10 && $0.time <= time }
            .reduce(0.0) { $0 + Double($1.tokens) } / 10
    }
}
