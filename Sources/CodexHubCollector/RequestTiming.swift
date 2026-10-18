import Foundation

/// Log-time interval accounting; overlapping tool waits are excluded once.
struct RequestTiming: Codable, Sendable {
    private var baseline: Double
    private var lastTime: Double
    private var tools: Set<String> = []
    private var toolStart: Double?
    private var excluded = 0.0
    private var endedAt: Double?

    init(at time: Double) { baseline = time; lastTime = time }

    /// Log time at which the previous sample ended.
    var baselineTime: Double { baseline }

    func accepts(_ time: Double) -> Bool { time.isFinite && time >= lastTime }

    mutating func tool(_ id: String, running: Bool, at time: Double) -> Bool {
        guard accepts(time) else { return false }
        lastTime = time
        if running {
            guard !tools.contains(id), tools.count < 256 else { return false }
            if tools.isEmpty { toolStart = time }
            tools.insert(id)
        } else {
            guard tools.remove(id) != nil else { return false }
            if tools.isEmpty, let start = toolStart {
                excluded += time - start
                toolStart = nil
            }
        }
        return true
    }

    mutating func finish(at time: Double) {
        if time.isFinite, time >= lastTime { endedAt = time }
    }

    mutating func sample(at time: Double) -> Double? {
        guard accepts(time) else { return nil }
        let end = min(time, endedAt ?? time)
        let duration = end - baseline - excluded - (toolStart.map { end - $0 } ?? 0)
        baseline = end
        lastTime = time
        excluded = 0
        if !tools.isEmpty { toolStart = time }
        return duration.isFinite && duration > 0 ? duration : nil
    }
}
