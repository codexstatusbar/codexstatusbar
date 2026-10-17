public enum CoreError: Error, Equatable {
    case invalidUsage
    case invalidTime
    case invalidTransition
}

public enum UsageSource: String, Sendable {
    case directRelay, sharedServer, rolloutLog
}

public struct TokenUsage: Equatable, Sendable {
    public let outputTokens: Int
    public let reasoningOutputTokens: Int?
    public let inputTokens: Int
    public let cachedInputTokens: Int
    public let cacheWriteInputTokens: Int
    public let totalTokens: Int?

    public init(outputTokens: Int, reasoningOutputTokens: Int? = nil,
                inputTokens: Int = 0, cachedInputTokens: Int = 0,
                cacheWriteInputTokens: Int = 0, totalTokens: Int? = nil) throws {
        guard [outputTokens, reasoningOutputTokens ?? 0, inputTokens, cachedInputTokens,
               cacheWriteInputTokens, totalTokens ?? 0].allSatisfy({ $0 >= 0 }) else {
            throw CoreError.invalidUsage
        }
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheWriteInputTokens = cacheWriteInputTokens
        self.totalTokens = totalTokens
    }

    public var nonReasoningOutputTokens: Int? {
        guard let reasoningOutputTokens, reasoningOutputTokens <= outputTokens else { return nil }
        return outputTokens - reasoningOutputTokens
    }

    fileprivate func regresses(from previous: Self, lastReasoning: Int?, lastTotal: Int?) -> Bool {
        if outputTokens < previous.outputTokens || inputTokens < previous.inputTokens ||
            cachedInputTokens < previous.cachedInputTokens || cacheWriteInputTokens < previous.cacheWriteInputTokens {
            return true
        }
        if let current = reasoningOutputTokens, let old = lastReasoning, current < old { return true }
        if let current = totalTokens, let old = lastTotal, current < old { return true }
        return false
    }
}

public enum UsageObservation: Equatable, Sendable {
    case baseline, delta(Int), secondarySource, wrongEpoch, regression, suspended
}

public struct UsageCounter: Sendable {
    public private(set) var source: UsageSource
    public private(set) var epoch: String
    public private(set) var baseline: TokenUsage?
    public private(set) var isPartial = false
    public private(set) var lastKnownReasoningOutputTokens: Int?
    public private(set) var lastKnownTotalTokens: Int?

    public init(source: UsageSource, epoch: String, verifiedEmptyThread: Bool = false) {
        self.source = source
        self.epoch = epoch
        baseline = verifiedEmptyThread ? try? TokenUsage(outputTokens: 0) : nil
    }

    /// Restores a validated checkpoint without clearing a suspended counter.
    public init(source: UsageSource, epoch: String, baseline: TokenUsage?,
                lastKnownReasoningOutputTokens: Int?, lastKnownTotalTokens: Int?, isPartial: Bool) throws {
        guard (lastKnownReasoningOutputTokens ?? 0) >= 0, (lastKnownTotalTokens ?? 0) >= 0,
              baseline != nil || (lastKnownReasoningOutputTokens == nil && lastKnownTotalTokens == nil && !isPartial),
              baseline?.reasoningOutputTokens == nil || baseline?.reasoningOutputTokens == lastKnownReasoningOutputTokens,
              baseline?.totalTokens == nil || baseline?.totalTokens == lastKnownTotalTokens else {
            throw CoreError.invalidUsage
        }
        self.source = source
        self.epoch = epoch
        self.baseline = baseline
        self.lastKnownReasoningOutputTokens = lastKnownReasoningOutputTokens
        self.lastKnownTotalTokens = lastKnownTotalTokens
        self.isPartial = isPartial
    }

    public mutating func observe(_ total: TokenUsage, source: UsageSource, epoch: String) -> UsageObservation {
        guard source == self.source else { return .secondarySource }
        guard epoch == self.epoch else { return .wrongEpoch }
        guard !isPartial else { return .suspended }
        let result: UsageObservation
        if let previous = baseline {
            guard !total.regresses(from: previous, lastReasoning: lastKnownReasoningOutputTokens,
                                   lastTotal: lastKnownTotalTokens) else {
                isPartial = true
                return .regression
            }
            result = .delta(total.outputTokens - previous.outputTokens)
        } else {
            result = .baseline
        }
        baseline = total
        // Missing public fields must not erase same-epoch validation history.
        lastKnownReasoningOutputTokens = total.reasoningOutputTokens ?? lastKnownReasoningOutputTokens
        lastKnownTotalTokens = total.totalTokens ?? lastKnownTotalTokens
        return result
    }

    /// Adapter must verify identity and checkpoint continuity before changing authority or epoch.
    public mutating func reconcile(source: UsageSource, epoch: String, baseline: TokenUsage) {
        self.source = source
        self.epoch = epoch
        self.baseline = baseline
        lastKnownReasoningOutputTokens = baseline.reasoningOutputTokens
        lastKnownTotalTokens = baseline.totalTokens
        isPartial = false
    }
}
