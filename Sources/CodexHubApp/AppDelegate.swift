import AppKit
import CryptoKit
import Darwin
import CodexHubCore
import CodexHubCollector

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = HubPresentation()
    private var menu: NativeMenuController?
    private var collector: LogCollector?
    private var claudeCollector: ClaudeCollector?
    private var polling: Task<Void, Never>?
    private var quotaPolling: Task<Void, Never>?
    private var backgroundRefresh: Task<Void, Never>?
    private var generation = 0
    private var savedChartHistory: [ThreadKey: [UsageHistoryPoint]]?
    private var chartHomePath = ""
    private let defaults = UserDefaults.standard

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.language = AppLanguage.load(from: defaults)
        model.saveLanguage = { [weak self] language in
            guard let self else { return }
            language.save(to: defaults)
        }
        model.rateUnit = defaults.string(forKey: "rateUnit").flatMap(RateUnit.init(rawValue:)) ?? .second
        model.updateRateUnit = { [weak self] unit in
            guard let self else { return }
            model.rateUnit = unit
            defaults.set(unit.rawValue, forKey: "rateUnit")
        }
        model.hookAction = { [weak self] action in self?.runHooks(action) }
        if let saved = defaults.stringArray(forKey: "menuFields") { model.menuFields = Set(saved.compactMap(MenuField.init(rawValue:))) }
        model.hideIdle = defaults.bool(forKey: "hideIdle")
        model.hideUnattached = defaults.bool(forKey: "hideUnattached")
        model.retentionDays = [1, 7, 30, 90].contains(defaults.integer(forKey: "retentionDays")) ? defaults.integer(forKey: "retentionDays") : 7
        menu = NativeMenuController(model: model)
        menu?.refreshLoginStatus()
        model.updateLogin = { [weak self] value in self?.menu?.setStartAtLogin(value) }
        model.saveDisplayPreferences = { [weak self] in
            guard let self else { return }
            defaults.set(model.menuFields.map(\.rawValue).sorted(), forKey: "menuFields")
            defaults.set(model.hideIdle, forKey: "hideIdle")
            defaults.set(model.hideUnattached, forKey: "hideUnattached")
        }
        let helper = HelperConnection.bundledURL.path
        model.helperPath = HelperConnection.executable(helper) ? helper : nil
        if let saved = defaults.string(forKey: "codexExecutable"), HelperConnection.executable(saved) { model.codexPath = saved }
        else { model.codexPath = HelperConnection.discoverCodex() }
        model.chooseCodex = { [weak self] in self?.chooseCodex() }
        model.runDoctor = { [weak self] in self?.runDoctor() }
        model.chooseHome = { [weak self] in self?.chooseHome() }
        model.refresh = { [weak self] in self?.refresh() }
        model.clearMetadata = { [weak self] in self?.clearMetadata() }
        model.updateRetention = { [weak self] days in self?.updateRetention(days) }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
        let path = defaults.string(forKey: "codexHome") ?? ProcessInfo.processInfo.environment["CODEX_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
        connect(home: URL(fileURLWithPath: path))
    }

    private func chooseCodex() {
        let panel = NSOpenPanel()
        panel.title = model.text("Choose installed Codex executable")
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard HelperConnection.executable(url.path) else {
            model.notice = "Choose an executable file."; return
        }
        model.codexPath = url.path
        defaults.set(url.path, forKey: "codexExecutable")
        model.doctorResult = "Not checked. Managed relay is experimental; G0 is unverified."
    }

    private func runDoctor() {
        guard !model.doctorBusy, let helper = model.helperPath, let codex = model.codexPath else { return }
        let home = model.codexHome
        model.doctorBusy = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                HelperConnection.doctor(home: home, codex: codex, helper: helper)
            }.value
            model.doctorBusy = false
            guard model.codexHome == home, model.codexPath == codex else { return }
            model.doctorResult = result
        }
    }

    private func runHooks(_ action: HelperConnection.HookAction) {
        guard !model.hooksBusy, let helper = model.helperPath else { return }
        let home = model.codexHome
        if action != .status {
            let alert = NSAlert()
            alert.messageText = model.text(action == .install ? "Install optional compatibility hooks?" : "Remove Tokloom compatibility hooks?")
            alert.informativeText = model.language.resolved == .korean ? "선택한 파일: \(home)/hooks.json\n\n도우미는 다른 핸들러를 유지하고, 기존 파일을 변경하기 전에 비공개 백업을 만듭니다. 백업은 보관되며, 제거하려면 Hub가 설치한 훅이 변경되지 않아야 합니다. 작업 중에는 이 파일을 편집하지 마세요.\n\n훅은 상태만 전달하며 토큰 사용량의 출처가 아닙니다. 기능이나 신뢰를 자동으로 활성화하지 않습니다. Codex /hooks에서 정확한 훅 정의를 직접 검토하고 신뢰해야 합니다. 설치만으로 호환성이나 신뢰가 검증되지는 않습니다." : "Selected file: \(home)/hooks.json\n\nThe helper preserves unrelated handlers and privately backs up an existing file before changing it. Backups are retained; owned hooks must be unchanged for removal. Do not edit this file during the operation.\n\nHooks provide state only, never token usage. No feature or trust is enabled automatically. You must review and trust the exact hook definitions manually in Codex /hooks; installation does not verify compatibility or trust."
            alert.addButton(withTitle: model.text("Cancel"))
            alert.addButton(withTitle: model.text(action == .install ? "Install hooks" : "Remove hooks"))
            NSApplication.shared.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        model.hooksBusy = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                HelperConnection.hooks(action, home: home, helper: helper)
            }.value
            model.hooksBusy = false
            guard model.codexHome == home else { return }
            model.hooksResult = result
        }
    }

    private func chooseHome() {
        let panel = NSOpenPanel()
        panel.title = model.text("Choose Codex home")
        panel.message = model.text("Choose the Codex home directory containing sessions. Original logs are read only.")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        defaults.set(url.path, forKey: "codexHome")
        connect(home: url)
    }

    private func connect(home: URL) {
        polling?.cancel()
        quotaPolling?.cancel()
        backgroundRefresh?.cancel()
        generation += 1
        let current = generation
        var previous = collector
        collector = nil
        claudeCollector = ClaudeCollector(claudeHome: ClaudeCollector.defaultHome())
        model.canManageMetadata = false
        model.sessions = []
        model.restoreUsageHistory([:])
        savedChartHistory = nil
        model.historyError = nil
        model.unattachedProcesses = []
        model.frame = nil
        model.refreshedAt = nil
        let canonicalHome = home.standardizedFileURL.resolvingSymlinksInPath()
        model.codexHome = canonicalHome.path
        // The usage endpoint is rate limited, so the weekly windows refresh every five minutes.
        quotaPolling = Task { [weak self] in
            while !Task.isCancelled {
                let codex = await Task.detached { QuotaReader.codexWindows(home: canonicalHome) }.value
                let claude = await QuotaReader.claudeWindows()
                guard let self, !Task.isCancelled else { return }
                model.quotas = codex + claude
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
            }
        }
        model.doctorResult = "Not checked. Managed relay is experimental; G0 is unverified."
        model.hooksResult = "Not checked. Hook trust and runtime compatibility are unverified."
        model.busy = true
        model.checkingConnection = true
        polling = Task { [weak self] in
            guard let self else { return }
            await previous?.stop()
            previous = nil
            do {
                let homeID = SHA256.hash(data: Data(canonicalHome.path.utf8)).map { String(format: "%02x", $0) }.joined()
                let directory = try metadataDirectory(homeID: homeID)
                let managed = directory.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("managed-runs/" + homeID, isDirectory: true)
                let service = try LogCollector(codexHome: canonicalHome, metadataDirectory: directory, managedRunsDirectory: managed, hooksDirectory: directory.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("hooks/" + homeID, isDirectory: true), monotonic: { ProcessInfo.processInfo.systemUptime }, wallTime: { Date().timeIntervalSince1970 })
                try await service.updateRetention(RetentionPolicy(days: model.retentionDays, maximumSessions: 1000))
                guard generation == current, !Task.isCancelled else { return }
                collector = service
                chartHomePath = canonicalHome.path
                do {
                    let data = try await service.loadChartHistory()
                    guard generation == current else { return }
                    model.restoreUsageHistory(try UsageHistoryArchive.decode(data, home: canonicalHome.path, monotonic: ProcessInfo.processInfo.systemUptime, wall: Date().timeIntervalSince1970))
                    savedChartHistory = nil
                } catch {
                    guard generation == current else { return }
                    model.historyError = "저장된 관측 차트를 불러오지 못했습니다. 새 관측은 계속됩니다."
                }
                model.canManageMetadata = true
                model.busy = false
                model.checkingConnection = false
                while !Task.isCancelled && generation == current {
                    if !model.busy {
                        let refresh = Task {
                            do {
                                let snapshot = try await service.refresh()
                                guard generation == current, !Task.isCancelled else { return }
                                try await apply(snapshot)
                            } catch {
                                guard generation == current else { return }
                                collectionFailed(error)
                            }
                        }
                        backgroundRefresh = refresh
                        await refresh.value
                        guard generation == current else { return }
                        backgroundRefresh = nil
                    }
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                }
            } catch {
                guard generation == current else { return }
                collectionFailed(error)
                model.busy = false
                model.checkingConnection = false
            }
        }
    }

    private func metadataDirectory(homeID: String) throws -> URL {
        var directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).resolvingSymlinksInPath()
        for component in ["CodexHub", "homes"] {
            directory.appendPathComponent(component, isDirectory: true)
            guard mkdir(directory.path, 0o700) == 0 || errno == EEXIST else { throw CollectorError.unsafePath }
            var info = stat()
            guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw CollectorError.unsafePath }
        }
        return directory.appendingPathComponent(homeID, isDirectory: true)
    }

    private func apply(_ snapshot: CollectorSnapshot) async throws {
        let current = generation
        let home = model.codexHome
        let observed = await Task.detached(priority: .utility) {
            (RunningCodexProcess.capture(), HelperConnection.configuredServiceTier(home: home))
        }.value
        guard generation == current else { return }
        model.configuredServiceTier = observed.1
        guard let running = observed.0 else {
            model.sessions = []; model.unattachedProcesses = []; model.frame = nil
            model.recordUsageHistory([], at: snapshot.observedAt)
            model.error = "Running Codex processes could not be inspected."
            return
        }
        let owned = Set(snapshot.sessions.compactMap { session -> String? in
            let controller = session.source == .directRelay ? session.processes.first(where: { $0.role == .tui })?.identity : nil
            return RunningCodexProcess.owner(of: session.id, controller: controller, in: running) == nil ? nil : session.id
        })
        let connected = try await collector?.bindRunningSessions(owned) ?? snapshot
        guard generation == current else { return }
        func presentation(_ session: SessionSnapshot, process: ProcessIdentity) -> SessionPresentation {
            SessionPresentation(monitor: session.monitor, cwd: session.cwd, model: session.model,
                                lastObserved: Date(timeIntervalSince1970: session.lastObserved),
                                process: process,
                                server: session.processes.first(where: { $0.role == .appServer })?.identity,
                                rootObserved: session.observedCLIRoot, parentThreadID: session.parentThreadID,
                                observedSource: session.source, sourceMeasurement: session.measurement,
                                sourceReconciliationPending: session.sourceReconciliationPending,
                                observationStopped: session.observationStopped,
                                observedActivity: session.activity, hookCompletionCandidate: session.hookCompletionCandidate,
                                                                usageDetails: session.usageDetails,
                                serverTiming: session.serverTiming, provider: session.provider)
        }
        let rows = connected.sessions.compactMap { session -> SessionPresentation? in
            let controller = session.source == .directRelay ? session.processes.first(where: { $0.role == .tui })?.identity : nil
            guard let process = RunningCodexProcess.owner(of: session.id, controller: controller, in: running) else { return nil }
            return presentation(session, process: process)
        }
        // Claude shares the Codex frame time so one clock orders every monitor.
        let claude = await claudeCollector?.refresh(at: snapshot.observedAt)
        let claudeRows = (claude?.sessions ?? []).compactMap { session in session.process.map { presentation(session, process: $0) } }
        let allRows = rows + claudeRows
        let represented = Set(rows.flatMap { [$0.process, $0.server].compactMap { $0 } })
        model.unattachedProcesses = running.filter { !represented.contains($0.identity) && !$0.isAppServer }.map(\.identity)
        let frame = try ReportedFrame(monitors: allRows.map(\.monitor), verifiedIndependentThreads: Set(allRows.filter { $0.rootObserved && ($0.measurement == .reported || $0.measurement == .warmingUp) }.map(\.id)), at: snapshot.observedAt)
        model.recordUsageHistory(allRows, at: snapshot.observedAt)
        model.sessions = allRows
        model.frame = frame
        model.diagnostics = Dictionary(grouping: snapshot.diagnostics + (claude?.diagnostics ?? []), by: \.message).map { message, occurrences in
            occurrences.count == 1 ? message : "\(message) (\(occurrences.count) occurrences)"
        }.sorted()
        model.refreshedAt = Date()
        model.error = nil
        // The archive is scoped to the Codex home and also carries Claude rows, which use their own claude: home.
        let persisted = model.usageHistory.filter { UsageHistoryArchive.isPersisted($0.key, home: chartHomePath) }
        if savedChartHistory != persisted, let collector {
            let history = persisted
            do {
                let data = try UsageHistoryArchive.encode(history, home: chartHomePath, monotonic: ProcessInfo.processInfo.systemUptime, wall: Date().timeIntervalSince1970)
                try await collector.saveChartHistory(data)
                guard generation == current else { return }
                savedChartHistory = history
                model.historyError = nil
            } catch {
                if generation == current { model.historyError = "관측 차트를 저장하지 못했습니다. 현재 관측은 계속됩니다." }
            }
        }
    }

    private func collectionFailed(_ error: Error) {
        model.suspendUsageHistory()
        model.error = (error as? CollectorError)?.message ?? "Could not read or store metadata. Check the selected Codex home and its permissions."
        model.diagnostics = ["Collection failed. Original Codex sessions were not changed."]
    }

    private func refresh() {
        guard !model.busy else { return }
        guard let collector else { connect(home: URL(fileURLWithPath: model.codexHome)); return }
        model.busy = true
        model.checkingConnection = true
        let current = generation
        Task {
            await backgroundRefresh?.value
            guard generation == current else { return }
            defer { if generation == current { model.busy = false; model.checkingConnection = false } }
            do {
                let snapshot = try await collector.refresh()
                guard generation == current else { return }
                try await apply(snapshot)
            } catch { if generation == current { collectionFailed(error) } }
        }
    }

    private func clearMetadata() {
        guard let collector, !model.busy else { return }
        model.busy = true
        let current = generation
        Task {
            await backgroundRefresh?.value
            guard generation == current else { return }
            defer { if generation == current { model.busy = false } }
            do {
                try await collector.clearMetadata()
                guard generation == current else { return }
                model.restoreUsageHistory([:])
                savedChartHistory = [:]
                model.historyError = nil
                let snapshot = await collector.snapshot()
                guard generation == current else { return }
                try await apply(snapshot)
                model.notice = "Tokloom metadata cleared. Original Codex logs were preserved." + (snapshot.diagnostics.isEmpty ? "" : " Some managed files were retained; see Connection diagnostics.")
            } catch { if generation == current { model.notice = "Metadata could not be cleared." } }
        }
    }

    private func updateRetention(_ days: Int) {
        guard let collector, !model.busy else { return }
        model.busy = true
        let current = generation
        Task {
            await backgroundRefresh?.value
            guard generation == current else { return }
            defer { if generation == current { model.busy = false } }
            do {
                try await collector.updateRetention(RetentionPolicy(days: days, maximumSessions: 1000))
                let snapshot = await collector.snapshot()
                guard generation == current else { return }
                try await apply(snapshot)
                model.retentionDays = days
                defaults.set(days, forKey: "retentionDays")
                model.notice = "Metadata retention updated." + (snapshot.diagnostics.isEmpty ? "" : " Some managed files were retained; see Connection diagnostics.")
            } catch { if generation == current { model.notice = "Metadata retention could not be updated." } }
        }
    }

    @objc private func woke(_ notification: Notification) {
        guard let collector else { return }
        let current = generation
        Task {
            do {
                try await collector.markGap()
                guard generation == current else { return }
                refresh()
            } catch { if generation == current { collectionFailed(error) } }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        polling?.cancel()
        backgroundRefresh?.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
