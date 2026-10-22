import Foundation

/// One usage window (session or weekly) of a provider account, as the provider itself reports it.
public struct ProviderQuota: Equatable, Sendable {
    public let provider: SessionProvider
    public let windowMinutes: Int
    public let usedPercent: Double
    public let resetsAt: Date?

    public init(provider: SessionProvider, windowMinutes: Int = QuotaParser.weeklyMinutes, usedPercent: Double, resetsAt: Date?) {
        self.provider = provider
        self.windowMinutes = windowMinutes
        self.usedPercent = min(max(usedPercent.isFinite ? usedPercent : 0, 0), 100)
        self.resetsAt = resetsAt
    }

    public var isWeekly: Bool { windowMinutes >= QuotaParser.weeklyMinutes }
    public var remainingPercent: Double { 100 - usedPercent }

    /// A window that already reset says nothing about the current week.
    public func isCurrent(at now: Date) -> Bool { resetsAt.map { $0 > now } ?? true }
}

/// What the plan spends once its windows are used up: Codex credits, or Claude's usage credits (extra usage).
public struct ProviderCredits: Equatable, Sendable {
    public enum Unit: Equatable, Sendable { case credits, currency(String) }
    public let provider: SessionProvider
    public let unit: Unit
    /// What is left; nil only for unlimited credits.
    public let remaining: Double?
    public let unlimited: Bool

    public init(provider: SessionProvider, unit: Unit, remaining: Double?, unlimited: Bool = false) {
        self.provider = provider
        self.unit = unit
        self.remaining = remaining.flatMap { $0.isFinite ? max(0, $0) : nil }
        self.unlimited = unlimited
    }
}

public enum QuotaParser {
    public static let weeklyMinutes = 10_080

    /// Codex rollout `token_count` line: every window in `payload.rate_limits.{primary,secondary}`, e.g. 300 and 10080 minutes.
    public static func codexWindows(rolloutLine line: String) -> [ProviderQuota] {
        guard line.contains("\"rate_limits\""), let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = (root["payload"] as? [String: Any])?["rate_limits"] as? [String: Any] else { return [] }
        return ["primary", "secondary"].compactMap { key in
            guard let window = limits[key] as? [String: Any],
                  let minutes = (window["window_minutes"] as? NSNumber)?.intValue, minutes > 0,
                  let used = (window["used_percent"] as? NSNumber)?.doubleValue else { return nil }
            let reset = (window["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return ProviderQuota(provider: .codex, windowMinutes: minutes, usedPercent: used, resetsAt: reset)
        }
    }

    /// Claude `/api/oauth/usage` body: `five_hour` and `seven_day`, each `{utilization, resets_at}` with an ISO-8601 reset time.
    public static func claudeWindows(usageJSON data: Data) -> [ProviderQuota] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return [("five_hour", 300), ("seven_day", weeklyMinutes)].compactMap { key, minutes in
            guard let window = root[key] as? [String: Any],
                  let used = (window["utilization"] as? NSNumber)?.doubleValue else { return nil }
            var reset: Date?
            if let text = window["resets_at"] as? String {
                let fractional = ISO8601DateFormatter()
                fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                reset = fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
            } else if let seconds = (window["resets_at"] as? NSNumber)?.doubleValue {
                reset = Date(timeIntervalSince1970: seconds)
            }
            return ProviderQuota(provider: .claude, windowMinutes: minutes, usedPercent: used, resetsAt: reset)
        }
    }

    /// Codex rollout line: `payload.rate_limits.credits` is `{has_credits, unlimited, balance}` with the balance as a string.
    public static func codexCredits(rolloutLine line: String) -> ProviderCredits? {
        guard line.contains("\"rate_limits\""), let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = (root["payload"] as? [String: Any])?["rate_limits"] as? [String: Any],
              let credits = limits["credits"] as? [String: Any], credits["has_credits"] as? Bool == true else { return nil }
        if credits["unlimited"] as? Bool == true { return ProviderCredits(provider: .codex, unit: .credits, remaining: nil, unlimited: true) }
        let balance: Double?
        if let text = credits["balance"] as? String { balance = Double(text) }
        else if let number = credits["balance"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { balance = number.doubleValue }
        else { balance = nil }
        guard let balance, balance.isFinite, balance >= 0 else { return nil }
        return ProviderCredits(provider: .codex, unit: .credits, remaining: balance)
    }

    /// Claude usage response: `spend` (a prepaid balance, or a cap minus what was used) or, in older responses, `extra_usage`.
    /// Credits that are not enabled, or that have neither a cap nor a balance, are nothing to show.
    public static func claudeCredits(usageJSON data: Data) -> ProviderCredits? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let spend = root["spend"] as? [String: Any], spend["enabled"] as? Bool == true {
            let used = money(spend["used"]), limit = money(spend["limit"]) ?? money((spend["cap"] as? [String: Any])?["money"])
            let currency = currencyCode(spend["used"]) ?? currencyCode(spend["limit"]) ?? currencyCode((spend["cap"] as? [String: Any])?["money"]) ?? currencyCode(spend["balance"]) ?? "USD"
            if let balance = money(spend["balance"]) { return ProviderCredits(provider: .claude, unit: .currency(currency), remaining: balance) }
            if let limit { return ProviderCredits(provider: .claude, unit: .currency(currency), remaining: limit - (used ?? 0)) }
        }
        if let extra = root["extra_usage"] as? [String: Any], extra["is_enabled"] as? Bool == true,
           let limit = (extra["monthly_limit"] as? NSNumber)?.doubleValue {
            let scale = pow(10, Double((extra["decimal_places"] as? NSNumber)?.intValue ?? 2))
            let used = (extra["used_credits"] as? NSNumber)?.doubleValue ?? 0
            let currency = (extra["currency"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? "USD"
            return ProviderCredits(provider: .claude, unit: .currency(currency), remaining: (limit - used) / scale)
        }
        return nil
    }

    /// Money in minor units plus an exponent (`{amount_minor: 200000, exponent: 2}` is 2000), or a plain number.
    private static func money(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.doubleValue.isFinite ? number.doubleValue : nil }
        guard let object = value as? [String: Any], let minor = (object["amount_minor"] as? NSNumber)?.doubleValue, minor.isFinite else { return nil }
        let exponent = (object["exponent"] as? NSNumber)?.intValue ?? 2
        guard (0...6).contains(exponent) else { return nil }
        return minor / pow(10, Double(exponent))
    }

    private static func currencyCode(_ value: Any?) -> String? {
        ((value as? [String: Any])?["currency"] as? String).flatMap { $0.isEmpty || $0.utf8.count > 8 ? nil : $0 }
    }
}
