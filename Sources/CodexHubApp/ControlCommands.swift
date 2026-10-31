import Foundation
import CodexHubCore
import CodexHubCollector

/// The commands behind the control socket: every value the app shows and everything its screens can do.
/// Actions go through the same model closures as the UI, so both follow one set of rules.
@MainActor final class ControlCommands {
    private struct Failure: Error {
        let code: String
        let message: String
        init(_ code: String, _ message: String) { self.code = code; self.message = message }
    }

    private let model: HubPresentation
    private let settleLimit: Duration

    init(model: HubPresentation, settleLimit: Duration = .seconds(30)) {
        self.model = model
        self.settleLimit = settleLimit
    }

    func reply(to line: Data) async -> Data {
        var envelope: [String: Any] = ["ok": false]
        do {
            guard let request = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                throw Failure("invalid_request", "A request is one JSON object per line.")
            }
            envelope["id"] = request["id"]
            guard let command = request["command"] as? String else { throw Failure("invalid_request", "command is required.") }
            guard request["args"] == nil || request["args"] is [String: Any] else { throw Failure("invalid_request", "args must be an object.") }
            envelope["result"] = try await run(command, request["args"] as? [String: Any] ?? [:])
            envelope["ok"] = true
        } catch let failure as Failure {
            envelope["error"] = ["code": failure.code, "message": failure.message]
        } catch {
            envelope["error"] = ["code": "internal", "message": String(describing: error)]
        }
        guard JSONSerialization.isValidJSONObject(envelope),
              let data = try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return Data(#"{"error":{"code":"internal","message":"The reply could not be encoded."},"ok":false}"#.utf8)
        }
        return data
    }

    private func run(_ command: String, _ args: [String: Any]) async throws -> Any {
        switch command {
        case "commands", "help": return ControlCatalog.description
        case "state": return state
        case "sessions": return model.sessions.map(json)
        case "session": return json(try session(args))
        case "history": return try history(args)
        case "settings": return settings
        case "settings.set": return try await setSettings(args)
        case "home.set": return try await setHome(args)
        case "refresh":
            try perform(model.refresh, "refresh")
            try await settled()
            return state
        case "metadata.clear": return try await clearMetadata(args)
        case "popover.open":
            try perform(model.open, "popover.open", whileBusy: true)
            return state
        case "popover.close":
            try perform(model.close, "popover.close", whileBusy: true)
            // Closing is animated.
            try await settled { [model] in model.popoverOpen?() ?? false }
            return state
        case "page.show":
            model.page = try page(args)
            return state
        case "quit":
            guard model.quit != nil else { throw Failure("unavailable", "quit is not available yet.") }
            // The reply leaves first.
            Task { @MainActor [model] in
                try? await Task.sleep(for: .milliseconds(200))
                model.quit?()
            }
            return ["quitting": true]
        default: throw Failure("unknown_command", "Unknown command \(command). Use commands to list them.")
        }
    }

    // MARK: Actions

    private func perform(_ action: (() -> Void)?, _ name: String, whileBusy: Bool = false) throws {
        guard let action else { throw Failure("unavailable", "\(name) is not available yet.") }
        guard whileBusy || !model.busy else { throw Failure("busy", "Another operation is running. Try again.") }
        action()
    }

    /// The model runs these operations in the background and reports them through `busy`.
    private func settled(while running: (() -> Bool)? = nil) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + settleLimit
        while running?() ?? model.busy {
            guard clock.now < deadline else { throw Failure("timeout", "The operation is still running.") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func setHome(_ args: [String: Any]) async throws -> Any {
        guard let path = args["path"] as? String, !path.isEmpty else { throw Failure("invalid_argument", "path is required.") }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Failure("invalid_argument", "path is not a directory.")
        }
        guard let connect = model.connectHome else { throw Failure("unavailable", "home.set is not available yet.") }
        try perform({ connect(URL(fileURLWithPath: path)) }, "home.set")
        try await settled()
        return state
    }

    private func clearMetadata(_ args: [String: Any]) async throws -> Any {
        // The screen asks before deleting; a request has to say so itself.
        guard args["confirm"].flatMap(Self.bool) == true else { throw Failure("confirmation_required", "Pass confirm=true to delete Tokloom metadata.") }
        guard model.canManageMetadata else { throw Failure("unavailable", "Metadata is not ready yet.") }
        try perform(model.clearMetadata, "metadata.clear")
        try await settled()
        guard model.notice == HubPresentation.metadataClearedNotice else { throw Failure("failed", model.notice ?? "Metadata could not be cleared.") }
        return state
    }

    private func setSettings(_ args: [String: Any]) async throws -> Any {
        guard !args.isEmpty else { throw Failure("invalid_argument", "Pass at least one setting.") }
        // Everything is checked first, so a bad value changes nothing.
        let changes = try args.sorted { $0.key < $1.key }.map { try change($0.key, to: $0.value) }
        let days = try args["retentionDays"].map { try retention($0) }
        if days != nil {
            guard model.updateRetention != nil, model.canManageMetadata else { throw Failure("unavailable", "Metadata is not ready yet.") }
            guard !model.busy else { throw Failure("busy", "Another operation is running. Try again.") }
        }
        if args["startAtLogin"] != nil, model.updateLogin == nil { throw Failure("unavailable", "startAtLogin is not available yet.") }
        changes.forEach { $0() }
        model.saveDisplayPreferences?()
        try await settled()
        if let days, model.retentionDays != days { throw Failure("failed", model.notice ?? "Metadata retention could not be updated.") }
        if let login = args["startAtLogin"].flatMap(Self.bool), model.startAtLogin != login {
            throw Failure("failed", model.notice ?? "Login item could not be changed.")
        }
        return settings
    }

    private func change(_ key: String, to value: Any) throws -> () -> Void {
        switch key {
        case "language":
            let language: AppLanguage = try option(value, key)
            return { [model] in model.language = language; model.saveLanguage?(language) }
        case "rateUnit":
            let unit: RateUnit = try option(value, key)
            return { [model] in model.updateRateUnit?(unit) }
        case "menuSpeed":
            let speed: MenuSpeed = try option(value, key)
            return { [model] in model.menuSpeed = speed }
        case "menuUsage":
            let usage: MenuUsage = try option(value, key)
            return { [model] in model.menuUsage = usage }
        case "menuWindows":
            let windows: MenuWindows = try option(value, key)
            return { [model] in model.menuWindows = windows }
        case "menuShowsReset":
            let shown = try flag(value, key)
            return { [model] in model.menuShowsReset = shown }
        case "hideIdle":
            let hidden = try flag(value, key)
            return { [model] in model.hideIdle = hidden }
        case "hideUnattached":
            let hidden = try flag(value, key)
            return { [model] in model.hideUnattached = hidden }
        case "startAtLogin":
            let enabled = try flag(value, key)
            return { [model] in model.updateLogin?(enabled) }
        case "retentionDays":
            let days = try retention(value)
            return { [model] in model.updateRetention?(days) }
        default:
            throw Failure("invalid_argument", "Unknown setting \(key).")
        }
    }

    private func option<Value: RawRepresentable & CaseIterable>(_ value: Any, _ key: String) throws -> Value where Value.RawValue == String {
        guard let text = value as? String, let option = Value(rawValue: text) else {
            throw Failure("invalid_argument", "\(key) must be one of: " + Value.allCases.map(\.rawValue).joined(separator: ", ") + ".")
        }
        return option
    }

    /// JSON booleans and numbers both arrive as NSNumber.
    private static func bool(_ value: Any) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private func flag(_ value: Any, _ key: String) throws -> Bool {
        guard let flag = Self.bool(value) else { throw Failure("invalid_argument", "\(key) must be true or false.") }
        return flag
    }

    private func retention(_ value: Any) throws -> Int {
        guard Self.bool(value) == nil, let days = value as? Int, ControlCatalog.retentionChoices.contains(days) else {
            throw Failure("invalid_argument", "retentionDays must be one of: " + ControlCatalog.retentionChoices.map(String.init).joined(separator: ", ") + ".")
        }
        return days
    }

    private func session(_ args: [String: Any]) throws -> SessionPresentation {
        guard let id = args["id"] as? String else { throw Failure("invalid_argument", "id is required.") }
        let matches = model.sessions.filter { $0.id.threadID == id || $0.providerThreadID == id }
        guard matches.count < 2 else { throw Failure("ambiguous", "Several sessions have this id.") }
        guard let match = matches.first else { throw Failure("not_found", "No session has this id.") }
        return match
    }

    private func page(_ args: [String: Any]) throws -> HubPage {
        if args["id"] != nil { return .detail(try session(args).id) }
        switch args["page"] as? String {
        case "overview": return .overview
        case "preferences": return .preferences
        default: throw Failure("invalid_argument", "page must be overview or preferences, or pass id.")
        }
    }

    // MARK: Queries

    private func history(_ args: [String: Any]) throws -> Any {
        let points: [UsageHistoryPoint]
        if args["id"] != nil {
            points = model.familyHistory(for: try session(args))
        } else if let name = args["provider"] {
            let provider: SessionProvider = try option(name, "provider")
            points = model.overviewUsageHistory(for: provider)
        } else {
            points = model.overviewUsageHistory
        }
        let perSecond = Dictionary(points.map { ($0.time, $0.outputTokens) }, uniquingKeysWith: +)
        return perSecond.sorted { $0.key < $1.key }.map { ["time": $0.key + model.chartWallClockOffset, "outputTokens": $0.value] as [String: Any] }
    }

    private var settings: [String: Any] {
        ["language": model.language.rawValue, "rateUnit": model.rateUnit.rawValue,
         "menuSpeed": model.menuSpeed.rawValue, "menuUsage": model.menuUsage.rawValue, "menuWindows": model.menuWindows.rawValue,
         "menuShowsReset": model.menuShowsReset, "hideIdle": model.hideIdle, "hideUnattached": model.hideUnattached,
         "startAtLogin": model.startAtLogin, "loginStatus": model.text(model.loginStatus), "retentionDays": model.retentionDays]
    }

    private var state: [String: Any] {
        let bundle = Bundle.main.infoDictionary
        return ["app": model.appName, "version": Self.value(bundle?["CFBundleShortVersionString"]), "pid": ProcessInfo.processInfo.processIdentifier,
                "summary": model.text(model.summary), "menuTitle": model.menuTitle,
                "activitySummary": model.activitySummary, "processBreakdown": model.processBreakdown,
                "coverage": model.coverage, "freshness": model.freshness,
                "tokensPerSecond": Self.number(model.error == nil ? model.aggregateRate : nil), "isPartial": model.frame?.isPartial ?? false,
                "eligibleRuns": model.frame?.eligibleRuns ?? 0, "measuredRuns": model.frame?.measuredRuns ?? 0,
                "providers": model.visibleProviders.map { ["provider": $0.rawValue, "tokensPerSecond": Self.number(model.providerRate($0))] },
                "busy": model.busy, "checkingConnection": model.checkingConnection, "canManageMetadata": model.canManageMetadata,
                "error": Self.value(model.error.map(model.text)), "historyError": Self.value(model.historyError.map(model.text)),
                "notice": Self.value(model.notice.map(model.text)), "diagnostics": model.diagnostics,
                "refreshedAt": Self.number(model.refreshedAt?.timeIntervalSince1970),
                "codexHome": model.codexHome, "claudeHome": model.claudeHome,
                "configuredServiceTier": Self.value(model.configuredServiceTier?.rawValue),
                "quotas": model.quotas.map(json), "credits": model.credits.map(json), "settings": settings,
                "sessions": model.sessions.map(json),
                "unattachedProcesses": model.unattachedProcesses.map(json), "hiddenUnattachedProcesses": model.hideUnattached,
                "page": pageName, "popoverOpen": model.popoverOpen?() ?? false]
    }

    private var pageName: Any {
        switch model.page {
        case .overview: "overview"
        case .preferences: "preferences"
        case .detail(let key): ["detail": key.threadID]
        }
    }

    private func json(_ session: SessionPresentation) -> [String: Any] {
        let parent = model.mainSession(for: session)
        let listed = parent.map { owner in
            model.visibleSessions.contains { $0.id == owner.id } && model.auxiliarySessions(for: owner).contains { $0.id == session.id }
        } ?? model.visibleSessions.contains { $0.id == session.id }
        let details = session.usageDetails
        return ["id": session.id.threadID, "homeID": session.id.homeID, "runID": Self.value(session.id.runID),
                "provider": session.provider.rawValue, "title": session.title, "cwd": Self.value(session.cwd), "model": Self.value(session.model),
                "status": model.status(for: session), "activity": session.activity.rawValue,
                "connectivity": session.monitor.connectivity.rawValue, "measurement": session.measurement.rawValue,
                "listed": listed, "parentID": Self.value(parent?.id.threadID ?? session.parentThreadID),
                "subagentIDs": model.subagents(of: session).map(\.id.threadID),
                "lastObserved": Self.number(session.lastObserved?.timeIntervalSince1970),
                "process": session.process.map(json) ?? NSNull(),
                "tokensPerSecond": Self.number(model.ownRateValue(for: session)),
                "familyTokensPerSecond": Self.number(model.rateValue(for: session)),
                "usage": Self.json(session.monitor.counter.baseline), "familyUsage": Self.json(model.familyUsage(of: session)),
                "reasoningEffort": Self.value(details?.reasoningEffort), "serviceTier": Self.value(details?.serviceTier?.rawValue),
                "contextTokens": Self.value(details?.contextTokens), "contextWindow": Self.value(details?.contextWindow),
                "limits": (details?.limits ?? []).map {
                    ["name": $0.name, "usedPercent": Self.number($0.usedPercent), "remainingPercent": Self.number($0.remainingPercent),
                     "windowMinutes": Self.value($0.windowMinutes), "resetsAt": Self.number($0.resetsAt)]
                }]
    }

    private func json(_ process: ProcessIdentity) -> [String: Any] {
        ["pid": process.pid, "osStartTime": process.osStartTime]
    }

    private func json(_ quota: ProviderQuota) -> [String: Any] {
        ["provider": quota.provider.rawValue, "windowMinutes": quota.windowMinutes, "isWeekly": quota.isWeekly, "scope": Self.value(quota.scope),
         "usedPercent": Self.number(quota.usedPercent), "remainingPercent": Self.number(quota.remainingPercent),
         "resetsAt": Self.number(quota.resetsAt?.timeIntervalSince1970), "text": model.quotaText(quota)]
    }

    private func json(_ credits: ProviderCredits) -> [String: Any] {
        let currency: String? = if case .currency(let code) = credits.unit { code } else { nil }
        return ["provider": credits.provider.rawValue, "unlimited": credits.unlimited, "remaining": Self.number(credits.remaining),
                "currency": Self.value(currency), "text": model.creditsValue(credits)]
    }

    private static func json(_ usage: TokenUsage?) -> Any {
        guard let usage else { return NSNull() }
        return ["outputTokens": usage.outputTokens, "reasoningOutputTokens": value(usage.reasoningOutputTokens),
                "inputTokens": usage.inputTokens, "cachedInputTokens": usage.cachedInputTokens,
                "cacheWriteInputTokens": usage.cacheWriteInputTokens, "totalTokens": value(usage.totalTokens)]
    }

    private static func value(_ value: Any?) -> Any { value ?? NSNull() }
    /// JSON has no infinity or NaN.
    private static func number(_ value: Double?) -> Any { value.flatMap { $0.isFinite ? $0 : nil } ?? NSNull() }
}
