import Foundation
import CoreFoundation

/// Raw Codex 0.163.0 server telemetry. TBT aggregation semantics are not a decode-rate contract.
public struct ServerTiming: Codable, Sendable {
    public let threadID: String
    public let turnID: String
    public let inferenceMilliseconds: Double?
    public let firstTokenMilliseconds: Double?
    public let betweenTokenMilliseconds: Double?
    public let responseID: String?
    public let sampledTokens: Int?
    public let outputDeltaCount: Int?
    public let outputDeltaMeanMilliseconds: Double?
    public let engineCalls: Int?
    public let coverage: String?

    public var isValid: Bool {
        let times = [inferenceMilliseconds, firstTokenMilliseconds, betweenTokenMilliseconds, outputDeltaMeanMilliseconds].compactMap { $0 }
        let counts = [sampledTokens, outputDeltaCount, engineCalls].compactMap { $0 }
        return (!times.isEmpty || !counts.isEmpty) && times.allSatisfy { $0.isFinite && $0 >= 0 } && counts.allSatisfy { $0 >= 0 }
    }

    public static func parse(logLine: String) -> ServerTiming? {
        guard logLine.utf8.count <= 65_536,
              logLine.contains("codex_api::responses_websocket_timing"),
              !logLine.contains("warmup=true"),
              let payloadRange = logLine.range(of: "payload=") else { return nil }
        func identity(_ name: String) -> String? {
            let pattern = "(?:^|\\s)" + name + "=(?:\"([A-Za-z0-9_-]{1,128})\"|([A-Za-z0-9_-]{1,128}))(?:\\s|$)"
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: logLine, range: NSRange(logLine.startIndex..., in: logLine)) else { return nil }
            for index in [1, 2] {
                if let range = Range(match.range(at: index), in: logLine) { return String(logLine[range]) }
            }
            return nil
        }
        guard let thread = identity("thread_id"), let turn = identity("turn_id") else { return nil }
        let suffix = logLine[payloadRange.upperBound...]
        let json: Data
        if suffix.first == "\"" {
            var escaped = false
            var end: String.Index?
            for i in suffix.indices.dropFirst() {
                if escaped { escaped = false; continue }
                if suffix[i] == "\\" { escaped = true; continue }
                if suffix[i] == "\"" { end = suffix.index(after: i); break }
            }
            guard let end, let decoded = try? JSONSerialization.jsonObject(with: Data(suffix[..<end].utf8), options: .fragmentsAllowed) as? String else { return nil }
            json = Data(decoded.utf8)
        } else {
            guard suffix.first == "{", let end = suffix.lastIndex(of: "}") else { return nil }
            json = Data(suffix[...end].utf8)
        }
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              object["type"] as? String == "responsesapi.websocket_timing",
              let metrics = object["timing_metrics"] as? [String: Any] else { return nil }
        func number(_ key: String) -> Double? {
            guard let value = metrics[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite, value.doubleValue >= 0 else { return nil }
            return value.doubleValue
        }
        func count(_ key: String) -> Int? {
            guard let value = metrics[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  let integer = Int(value.stringValue), integer >= 0 else { return nil }
            return integer
        }
        func identifier(_ value: Any?) -> String? {
            guard let value = value as? String, !value.isEmpty, value.utf8.count <= 128,
                  value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
            return value
        }
        let inference = number("engine_service_total_ms")
        let first = number("engine_service_ttft_total_ms")
        let between = number("engine_service_tbt_across_engine_calls_ms")
        let result = ServerTiming(threadID: thread, turnID: turn, inferenceMilliseconds: inference,
                                  firstTokenMilliseconds: first, betweenTokenMilliseconds: between,
                                  responseID: identifier(metrics["response_id"]),
                                  sampledTokens: count("num_sampled_tokens_total"),
                                  outputDeltaCount: count("websocket_output_text_delta_count"),
                                  outputDeltaMeanMilliseconds: number("websocket_output_text_delta_tbt_ms"),
                                  engineCalls: count("num_engine_calls"),
                                  coverage: identifier((metrics["critical_path"] as? [String: Any])?["coverage"]))
        return result.isValid ? result : nil
    }
}
