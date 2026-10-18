import Foundation

/// Weekly usage window of one provider account, as the provider itself reports it.
public struct ProviderQuota: Equatable, Sendable {
    public let provider: SessionProvider
    public let usedPercent: Double
    public let resetsAt: Date?

    public init(provider: SessionProvider, usedPercent: Double, resetsAt: Date?) {
        self.provider = provider
        self.usedPercent = min(max(usedPercent.isFinite ? usedPercent : 0, 0), 100)
        self.resetsAt = resetsAt
    }

    public var remainingPercent: Double { 100 - usedPercent }

    /// A window that already reset says nothing about the current week.
    public func isCurrent(at now: Date) -> Bool { resetsAt.map { $0 > now } ?? true }
}

public enum QuotaParser {
    static let weeklyMinutes = 10_080

    /// Codex rollout `token_count` line: `payload.rate_limits.{primary,secondary}`; the weekly one has a 10080 minute window.
    public static func codexWeekly(rolloutLine line: String) -> ProviderQuota? {
        guard line.contains("\"rate_limits\""), let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = (root["payload"] as? [String: Any])?["rate_limits"] as? [String: Any] else { return nil }
        for key in ["primary", "secondary"] {
            guard let window = limits[key] as? [String: Any],
                  (window["window_minutes"] as? NSNumber)?.intValue == weeklyMinutes,
                  let used = (window["used_percent"] as? NSNumber)?.doubleValue else { continue }
            let reset = (window["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return ProviderQuota(provider: .codex, usedPercent: used, resetsAt: reset)
        }
        return nil
    }

    /// Claude `/api/oauth/usage` body: `seven_day.{utilization,resets_at}` with an ISO-8601 reset time.
    public static func claudeWeekly(usageJSON data: Data) -> ProviderQuota? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let window = root["seven_day"] as? [String: Any],
              let used = (window["utilization"] as? NSNumber)?.doubleValue else { return nil }
        var reset: Date?
        if let text = window["resets_at"] as? String {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            reset = fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
        } else if let seconds = (window["resets_at"] as? NSNumber)?.doubleValue {
            reset = Date(timeIntervalSince1970: seconds)
        }
        return ProviderQuota(provider: .claude, usedPercent: used, resetsAt: reset)
    }
}
