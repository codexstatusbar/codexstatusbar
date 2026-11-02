public struct ReportedFrame: Sendable {
    public private(set) var time: Double
    public let tokensPerSecond: Double?
    public let eligibleRuns: Int
    public let measuredRuns: Int
    public let isPartial: Bool

    /// Whether two frames report the same, whatever their times.
    public func reportsSame(as other: ReportedFrame) -> Bool {
        tokensPerSecond == other.tokensPerSecond && eligibleRuns == other.eligibleRuns
            && measuredRuns == other.measuredRuns && isPartial == other.isPartial
    }

    /// The same report at a later time, for a frame whose readings are known not to depend on it.
    public func moved(to later: Double) -> ReportedFrame {
        var frame = self
        frame.time = max(time, later)
        return frame
    }

    private struct RunKey: Hashable {
        let homeID: String
        let runID: String?
        let unassignedThreadID: String?
        init(_ key: ThreadKey) {
            homeID = key.homeID
            runID = key.runID
            unassignedThreadID = key.runID == nil ? key.threadID : nil
        }
    }

    /// The adapter must establish non-overlapping parent/child scope before including a thread.
    public init(monitors: [ThreadMonitor], verifiedIndependentThreads: Set<ThreadKey>, at time: Double) throws {
        guard time.isFinite, time >= 0 else { throw CoreError.invalidTime }
        guard Set(monitors.map(\.key)).count == monitors.count else { throw CoreError.invalidTransition }
        var eligible: Set<RunKey> = []
        var measured: Set<RunKey> = []
        var incomplete: Set<RunKey> = []
        var sum = 0.0
        var hasValue = false
        for monitor in monitors {
            let rate = try monitor.workAverageRate(at: time)
            guard monitor.activity != .idle || rate != nil else { continue }
            let run = RunKey(monitor.key)
            eligible.insert(run)
            if verifiedIndependentThreads.contains(monitor.key), let rate {
                sum += rate
                hasValue = true
                measured.insert(run)
            } else {
                incomplete.insert(run)
            }
        }
        self.time = time
        tokensPerSecond = hasValue && sum.isFinite ? sum : nil
        eligibleRuns = eligible.count
        measuredRuns = measured.subtracting(incomplete).count
        isPartial = !sum.isFinite || !incomplete.isEmpty || monitors.contains { $0.workAverageIsPartial }
    }
}
