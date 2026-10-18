import Foundation

/// Log-time interval accounting; overlapping tool waits are excluded once.
struct RequestTiming: Codable, Sendable {
    private var baseline: Double
    private var lastTime: Double
    private var tools: Set<String> = []
    private var toolStart: Double?
    /// Completed tool spans since the last sample, kept so a later start boundary can clip them.
    private var spans: [[Double]] = []
    private var endedAt: Double?

    init(at time: Double) { baseline = time; lastTime = time }

    private enum CodingKeys: String, CodingKey { case baseline, lastTime, tools, toolStart, spans, excluded, endedAt }

    // Checkpoints written before spans existed stored one summed `excluded` value; keep them readable.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        baseline = try c.decode(Double.self, forKey: .baseline)
        lastTime = try c.decode(Double.self, forKey: .lastTime)
        tools = try c.decodeIfPresent(Set<String>.self, forKey: .tools) ?? []
        toolStart = try c.decodeIfPresent(Double.self, forKey: .toolStart)
        endedAt = try c.decodeIfPresent(Double.self, forKey: .endedAt)
        spans = try c.decodeIfPresent([[Double]].self, forKey: .spans) ?? []
        if let legacy = try c.decodeIfPresent(Double.self, forKey: .excluded), legacy > 0, spans.isEmpty {
            spans = [[baseline, baseline + legacy]]
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(baseline, forKey: .baseline)
        try c.encode(lastTime, forKey: .lastTime)
        try c.encode(tools, forKey: .tools)
        try c.encodeIfPresent(toolStart, forKey: .toolStart)
        try c.encodeIfPresent(endedAt, forKey: .endedAt)
        try c.encode(spans, forKey: .spans)
    }

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
                if spans.count < 256 { spans.append([start, time]) }
                toolStart = nil
            }
        }
        return true
    }

    mutating func finish(at time: Double) {
        if time.isFinite, time >= lastTime { endedAt = time }
    }

    /// Generation time since the previous sample. `streamStart` moves the beginning forward to when the
    /// response began; tool time is then removed only where it overlaps what is left.
    mutating func sample(at time: Double, streamStart: Double? = nil) -> Double? {
        guard accepts(time) else { return nil }
        let end = min(time, endedAt ?? time)
        let begin = min(max(baseline, streamStart ?? baseline), end)
        var excluded = spans.reduce(0.0) { $0 + max(0, min($1[1], end) - max($1[0], begin)) }
        if let start = toolStart { excluded += max(0, end - max(start, begin)) }
        let duration = end - begin - excluded
        baseline = end
        lastTime = time
        spans.removeAll()
        if !tools.isEmpty { toolStart = time }
        return duration.isFinite && duration > 0 ? duration : nil
    }
}
