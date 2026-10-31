import Foundation
import CodexHubCore

struct ControlArgument {
    let name: String
    let type: String
    var required = false
    var choices: [String] = []
    let summary: String

    var json: [String: Any] {
        var result: [String: Any] = ["name": name, "type": type, "required": required, "summary": summary]
        if !choices.isEmpty { result["choices"] = type == "integer" ? choices.compactMap { Int($0) } as [Any] : choices as [Any] }
        return result
    }
}

struct ControlCommand {
    /// `read` changes nothing, `action` changes the app, `destructive` deletes or ends something.
    let name: String
    let kind: String
    let summary: String
    var args: [ControlArgument] = []
    let returns: String
}

/// What an agent needs to use the app with nothing but the app: the socket reply to `commands`, `--help` and the bundled
/// AGENTS.md all come from here, and the choices come from the types the commands accept, so they cannot drift apart.
enum ControlCatalog {
    static let socketDisplayPath = "~/Library/Application Support/CodexHub/control.sock"
    static var socketPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CodexHub/control.sock").path
    }
    static let executable = "Tokloom.app/Contents/MacOS/CodexHubApp"
    static let retentionChoices = [1, 7, 30, 90]

    private static func names<Value: RawRepresentable & CaseIterable>(_: Value.Type) -> [String] where Value.RawValue == String {
        Value.allCases.map(\.rawValue)
    }

    static let settings: [ControlArgument] = [
        .init(name: "language", type: "string", choices: names(AppLanguage.self), summary: "Display language; system follows macOS."),
        .init(name: "rateUnit", type: "string", choices: names(RateUnit.self), summary: "Speed unit on screen. Socket rates stay tokens per second."),
        .init(name: "menuSpeed", type: "string", choices: names(MenuSpeed.self), summary: "Speed shown in the menu bar."),
        .init(name: "menuUsage", type: "string", choices: names(MenuUsage.self), summary: "Providers whose remaining usage the menu bar shows."),
        .init(name: "menuWindows", type: "string", choices: names(MenuWindows.self), summary: "Usage windows the menu bar shows."),
        .init(name: "menuShowsReset", type: "boolean", summary: "Show the time until a usage window resets in the menu bar."),
        .init(name: "hideIdle", type: "boolean", summary: "Hide idle sessions from the list."),
        .init(name: "hideUnattached", type: "boolean", summary: "Hide processes that could not be matched to a session."),
        .init(name: "startAtLogin", type: "boolean", summary: "Start Tokloom at login. macOS may ask for approval."),
        .init(name: "retentionDays", type: "integer", choices: retentionChoices.map(String.init), summary: "Days of Tokloom metadata to keep; shorter values delete older metadata.")
    ]

    static let commands: [ControlCommand] = [
        .init(name: "commands", kind: "read", summary: "Describe the protocol, every command and every returned field.", returns: "This description."),
        .init(name: "state", kind: "read", summary: "Everything the app shows, except chart points. Start here.", returns: "The object described by stateFields."),
        .init(name: "sessions", kind: "read", summary: "Every session, including subagents and sessions hidden from the list.", returns: "An array of sessionFields objects."),
        .init(name: "session", kind: "read", summary: "One session.",
              args: [.init(name: "id", type: "string", required: true, summary: "The id field of a session.")], returns: "A sessionFields object."),
        .init(name: "history", kind: "read", summary: "Observed output of the last hour. Without arguments: every session.",
              args: [.init(name: "id", type: "string", summary: "Limit to one session and its subagents."),
                     .init(name: "provider", type: "string", choices: names(SessionProvider.self), summary: "Limit to one provider.")],
              returns: "An array of {time, outputTokens} per second, oldest first."),
        .init(name: "settings", kind: "read", summary: "Current settings.", returns: "An object with every setting, plus the read-only loginStatus."),
        .init(name: "settings.set", kind: "action", summary: "Change settings. Each argument is a setting; if one is invalid, nothing changes.",
              args: settings, returns: "The settings after the change."),
        .init(name: "home.set", kind: "action", summary: "Switch to another Codex home and restart collection from it. Waits for the result.",
              args: [.init(name: "path", type: "string", required: true, summary: "An existing directory.")], returns: "state."),
        .init(name: "refresh", kind: "action", summary: "Check the connection now. Waits for the result; a failed check is ok=true with the reason in state.error.", returns: "state."),
        .init(name: "metadata.clear", kind: "destructive", summary: "Delete Tokloom's collected metadata and charts. Original Codex and Claude logs are kept. Waits for the result.",
              args: [.init(name: "confirm", type: "boolean", required: true, summary: "Must be true.")], returns: "state."),
        .init(name: "popover.open", kind: "action", summary: "Open the popover from the menu bar icon. macOS closes it when it loses focus; check popoverOpen.", returns: "state."),
        .init(name: "popover.close", kind: "action", summary: "Close the popover.", returns: "state."),
        .init(name: "page.show", kind: "action", summary: "Choose the popover's page, which works and is kept while it is closed; this does not open it. Pass page, or id for a session's detail page.",
              args: [.init(name: "page", type: "string", choices: ["overview", "preferences"], summary: "A top-level page."),
                     .init(name: "id", type: "string", summary: "The id field of a session.")], returns: "state."),
        .init(name: "quit", kind: "destructive", summary: "Quit Tokloom, which ends this socket. Codex and Claude sessions keep running.", returns: "{quitting: true}.")
    ]

    static let errorCodes: [String: String] = [
        "invalid_request": "The line is not a JSON object with a command, or args is not an object.",
        "unknown_command": "No such command; see commands.",
        "invalid_argument": "An argument is missing or has a bad value; the message lists what is accepted. Nothing changed.",
        "confirmation_required": "The command needs confirm=true.",
        "unavailable": "The app is still starting or this action does not apply yet. Check state and retry.",
        "busy": "Another operation is running (state.busy). Retry when it ends.",
        "timeout": "The operation took over 30 seconds and is still running. Watch state.busy.",
        "not_found": "No session has this id.",
        "ambiguous": "Several sessions share this id, which can happen across homes.",
        "failed": "The operation ran and failed; the message says why.",
        "internal": "An unexpected error."
    ]

    static let stateFields: [String: String] = [
        "app": "Display name.", "version": "App version.", "pid": "Process id of the app.",
        "summary": "Headline value of the app, localized.", "menuTitle": "Plain text of the menu bar.",
        "activitySummary": "Count of working sessions, localized.", "processBreakdown": "Active, idle and unknown counts, localized.",
        "coverage": "How many eligible runs have a measured rate, localized.", "freshness": "Last check, localized.",
        "tokensPerSecond": "Combined measured output rate; null when nothing is measured.", "isPartial": "Some eligible runs are missing from the combined rate.",
        "eligibleRuns": "Runs that should have a rate.", "measuredRuns": "Runs that have one.",
        "providers": "Per provider: {provider, tokensPerSecond}.",
        "busy": "An operation is running; other operations are refused.", "checkingConnection": "A connection check is running.",
        "canManageMetadata": "metadata.clear and retentionDays can run.",
        "error": "Why measuring failed, or null.", "historyError": "Why charts could not be loaded or saved, or null.",
        "notice": "Message of the last operation that left one, which may be older than the last command, or null.", "diagnostics": "Collection warnings.",
        "refreshedAt": "Unix seconds of the last successful refresh, or null.",
        "codexHome": "Codex home being read.", "claudeHome": "Claude home being read.",
        "configuredServiceTier": "Codex service tier from its config, or null.",
        "quotas": "Account usage windows: {provider, windowMinutes, isWeekly, scope, usedPercent, remainingPercent, resetsAt, text}.",
        "credits": "Credits per provider: {provider, unlimited, remaining, currency, text}.",
        "settings": "Same as the settings command.", "sessions": "Same as the sessions command.",
        "unattachedProcesses": "Running processes matched to no session: {pid, osStartTime}.",
        "hiddenUnattachedProcesses": "unattachedProcesses are hidden on screen.",
        "page": "overview, preferences, or {detail: session id}.", "popoverOpen": "The popover is open."
    ]

    static let sessionFields: [String: String] = [
        "id": "Pass this to session, history and page.show.", "homeID": "Hash of the home it belongs to.", "runID": "Run id, or null.",
        "provider": "codex or claude.", "title": "Name on screen.", "cwd": "Working directory, or null.", "model": "Model, or null.",
        "status": "Status on screen, localized.", "activity": "idle, working, generating, toolRunning, approvalWait or unknown.",
        "connectivity": "connected, degraded, disconnected or unknown.", "measurement": "warmingUp, estimated, reported, partial or unavailable.",
        "listed": "The row appears on the session list.", "parentID": "Session that started this subagent, or null.",
        "subagentIDs": "Listed subagents of this session.", "lastObserved": "Unix seconds of the last log activity, or null.",
        "process": "{pid, osStartTime} of the owner, or null.",
        "tokensPerSecond": "Own measured rate, or null.", "familyTokensPerSecond": "Own rate plus listed subagents, or null.",
        "usage": "Cumulative tokens of this session, or null.", "familyUsage": "The same with subagents where the provider reports them, or null.",
        "reasoningEffort": "Reasoning effort, or null.", "serviceTier": "Service tier, or null.",
        "contextTokens": "Tokens in context, or null.", "contextWindow": "Context size, or null.",
        "limits": "Limits the session reported: {name, usedPercent, remainingPercent, windowMinutes, resetsAt}."
    ]

    static let conventions = [
        "All times are Unix seconds and all rates are tokens per second, whatever rateUnit shows on screen.",
        "A value that is unknown is null, never zero: 0 means measured as zero.",
        "Text fields follow the language setting; use the unlocalized fields (activity, connectivity, measurement) in logic.",
        "Ask before running a destructive command unless the user asked for it."
    ]

    static var description: [String: Any] {
        ["protocol": ["transport": "Unix stream socket", "socket": socketPath, "access": "current user only",
                      "framing": "One JSON object per line, one reply per line, in order; a connection carries many requests and closes after 30 idle seconds.",
                      "request": #"{"id": optional, returned as sent, "command": string, "args": optional object}"#,
                      "success": #"{"id": ..., "ok": true, "result": ...}"#,
                      "failure": #"{"id": ..., "ok": false, "error": {"code": string, "message": string}}"#,
                      "limits": "Requests up to 64 KB, 8 connections at a time."],
         "conventions": conventions, "errorCodes": errorCodes, "stateFields": stateFields, "sessionFields": sessionFields,
         "commands": commands.map { ["name": $0.name, "kind": $0.kind, "summary": $0.summary, "args": $0.args.map(\.json), "returns": $0.returns] }]
    }

    static var markdown: String {
        var lines = ["# Tokloom control", "",
                     "Tokloom is a macOS menu bar app that shows the speed, usage limits and sessions of Codex and Claude Code.",
                     "While it runs, everything it shows and everything its screens can do is available to programs and agents.", "",
                     "## Use it from the command line", "",
                     "    \(executable) control <command> ['<json args>']", "",
                     "The reply is printed as one line of JSON. Exit status: 0 ok, 1 the app refused or failed, 2 bad usage, 3 Tokloom is not running (`open -a Tokloom`).", "",
                     "    \(executable) control state",
                     #"    \#(executable) control settings.set '{"hideIdle":true}'"#, "",
                     "Run `control commands` for this reference as JSON.", "",
                     "## Or use the socket", "",
                     "Connect to the Unix socket `\(socketDisplayPath)`, send one JSON object per line and read one reply per line:", "",
                     #"    {"id":1,"command":"settings.set","args":{"hideIdle":true}}"#,
                     #"    {"id":1,"ok":true,"result":{...}}"#,
                     #"    {"id":1,"ok":false,"error":{"code":"busy","message":"..."}}"#, "",
                     "A connection carries many requests and closes after 30 idle seconds. Only the current user can connect.", "",
                     "## Conventions", ""]
        lines += conventions.map { "- " + $0 }
        lines += ["", "## Commands", ""]
        for command in commands {
            lines += ["### `\(command.name)` (\(command.kind))", "", command.summary, ""]
            lines += command.args.map { argument in
                let choices = argument.choices.isEmpty ? "" : " One of: " + argument.choices.joined(separator: ", ") + "."
                return "- `\(argument.name)` (\(argument.type)\(argument.required ? ", required" : "")): \(argument.summary)\(choices)"
            }
            lines += (command.args.isEmpty ? [] : [""]) + ["Returns: \(command.returns)", ""]
        }
        func table(_ title: String, _ fields: [String: String]) -> [String] {
            ["## \(title)", ""] + fields.sorted { $0.key < $1.key }.map { "- `\($0.key)`: \($0.value)" } + [""]
        }
        lines += table("stateFields", stateFields) + table("sessionFields", sessionFields) + table("Error codes", errorCodes)
        return lines.joined(separator: "\n")
    }
}

/// `CodexHubApp --help` and `CodexHubApp control …` answer and exit without starting the app.
enum ControlCommandLine {
    /// The exit status, or nil when these arguments mean starting the app.
    static func run(_ arguments: [String]) -> Int32? {
        switch arguments.first {
        case "--help", "-h", "help":
            print(ControlCatalog.markdown)
            return 0
        case "control": return control(Array(arguments.dropFirst()))
        default: return nil
        }
    }

    private static func fail(_ message: String, _ status: Int32) -> Int32 {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        return status
    }

    private static func control(_ arguments: [String]) -> Int32 {
        guard let command = arguments.first, arguments.count <= 2 else {
            return fail("Usage: control <command> ['<json args>']. See --help.", 2)
        }
        var request: [String: Any] = ["command": command]
        if arguments.count == 2 {
            guard let args = (try? JSONSerialization.jsonObject(with: Data(arguments[1].utf8))) as? [String: Any] else {
                return fail("Arguments must be one JSON object.", 2)
            }
            request["args"] = args
        }
        do {
            let reply = try ControlClient.exchange(path: ControlCatalog.socketPath, line: JSONSerialization.data(withJSONObject: request))
            print(String(decoding: reply, as: UTF8.self))
            let ok = ((try? JSONSerialization.jsonObject(with: reply)) as? [String: Any])?["ok"] as? Bool
            return ok == true ? 0 : 1
        } catch {
            return fail("Tokloom is not running. Start it with: open -a Tokloom", 3)
        }
    }
}
