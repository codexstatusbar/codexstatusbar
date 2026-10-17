/// Numeric-only visible counts. All observations and reads use one collector frame clock.
public struct VisibleWindow: Sendable {
    private struct Item: Sendable {
        var count: Int
        var final: Bool
    }
    private var items: [String: Item] = [:]
    private var samples: [(time: Double, count: Int)] = []
    private var startedAt: Double?
    private var lastTime = 0.0
    private var total = 0
    public private(set) var unavailableReason: String? = "awaiting_item_start"
    public private(set) var isPartial = false

    public init() {}

    public mutating func invalidate(reason: String, partial: Bool = true) {
        items.removeAll(); samples.removeAll(); startedAt = nil; total = 0
        unavailableReason = reason
        isPartial = partial
    }

    public mutating func observe(itemID: String, count: Int, completeFromStart: Bool,
                                 final: Bool, textMismatch: Bool, at time: Double) throws {
        guard time.isFinite, time >= lastTime else { throw CoreError.invalidTime }
        guard count >= 0 else { throw CoreError.invalidUsage }
        lastTime = time
        guard completeFromStart else { invalidate(reason: "incomplete_item"); return }
        if let old = items[itemID], old.final {
            guard old.count == count && final else { invalidate(reason: "completed_item_changed"); return }
            return
        }
        if items[itemID] == nil {
            guard count == 0, !final else { invalidate(reason: "missed_item_start"); return }
            guard items.count < 4096 else { invalidate(reason: "item_bound"); return }
            if startedAt == nil {
                startedAt = time
                samples = [(time, 0)]
                unavailableReason = nil
                isPartial = false
            }
        }
        let (next, overflow) = total.subtractingReportingOverflow(items[itemID]?.count ?? 0)
        let (sum, sumOverflow) = next.addingReportingOverflow(count)
        guard !overflow, !sumOverflow else { throw CoreError.invalidUsage }
        total = sum
        items[itemID] = Item(count: count, final: final)
        // Replacing the item count preserves legitimate negative BPE corrections.
        if samples.count > 1, samples.last?.time == time { samples[samples.count - 1] = (time, total) }
        else { samples.append((time, total)) }
        while samples.count > 2 && samples[1].time < time - 5 { samples.removeFirst() }
        guard samples.count <= 4096 else { invalidate(reason: "sample_bound"); return }
        if textMismatch { invalidate(reason: "final_text_mismatch") }
    }

    public func measurement(at time: Double) -> Measurement {
        if isPartial { return .partial }
        guard let startedAt, time.isFinite, time >= lastTime else { return .unavailable }
        return time - startedAt < 5 ? .warmingUp : (rate(at: time) == nil ? .partial : .estimated)
    }

    public func rate(at time: Double) -> Double? {
        guard unavailableReason == nil, let startedAt, time.isFinite,
              time >= lastTime, time - startedAt >= 5 else { return nil }
        let baseline = samples.last(where: { $0.time <= time - 5 })?.count ?? samples.first?.count ?? 0
        let difference = total - baseline
        // A negative net interval is an invalid speed, not a discarded correction.
        guard difference >= 0 else { return nil }
        return Double(difference) / 5
    }
}
