import Foundation
import CodexHubCore

/// Reads each provider's weekly window. Codex writes it into its own session logs; Claude only
/// reports it through the usage endpoint that its logged-in OAuth token may call.
public enum QuotaReader {
    private static let tailBytes = 512 * 1024
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// Newest `rate_limits` found in the tail of the most recently written rollout files.
    public static func codexWeekly(home: URL, now: Date = Date()) -> ProviderQuota? {
        guard FileManager.default.fileExists(atPath: home.appendingPathComponent("auth.json").path),
              let walker = FileManager.default.enumerator(at: home.appendingPathComponent("sessions"),
                                                           includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        var files: [(URL, Date)] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            files.append((url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast))
        }
        for (url, _) in files.sorted(by: { $0.1 > $1.1 }).prefix(5) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            guard let size = try? handle.seekToEnd() else { continue }
            try? handle.seek(toOffset: size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0)
            let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
            for line in text.split(separator: "\n").reversed() {
                if let quota = QuotaParser.codexWeekly(rolloutLine: String(line)), quota.isCurrent(at: now) { return quota }
            }
        }
        return nil
    }

    /// nil when no Claude Code login exists in the keychain or the endpoint refuses the token.
    public static func claudeWeekly() async -> ProviderQuota? {
        guard let token = claudeToken() else { return nil }
        var request = URLRequest(url: usageURL, timeoutInterval: 10)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        guard let (body, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return QuotaParser.claudeWeekly(usageJSON: body)
    }

    /// The stored credential JSON is read through the system `security` tool and never kept or logged.
    private static func claudeToken() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        if let expires = (oauth["expiresAt"] as? NSNumber)?.doubleValue, expires / 1000 < Date().timeIntervalSince1970 { return nil }
        return token
    }
}
