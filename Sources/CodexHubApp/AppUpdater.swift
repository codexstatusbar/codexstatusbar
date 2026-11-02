import AppKit
import CodexHubCore

/// Finds new releases on its own and installs one only when asked. Its screens and socket commands reach it through the model.
@MainActor final class AppUpdater {
    private enum Key {
        static let autoCheck = "autoCheckUpdates", lastCheck = "updateLastCheck", etag = "updateETag", body = "updateReleaseBody"
    }
    private static let waitAfterWake: Duration = .seconds(30)

    private let model: HubPresentation
    private let defaults: UserDefaults
    private let bundle = Bundle.main
    private var schedule: Task<Void, Never>?
    private var wake: Task<Void, Never>?
    private var checking: Task<Bool, Never>?
    private var pendingFailure = false

    private var resultFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CodexHub/update-result")
    }
    /// The real location: a symlink in Applications must not be mistaken for the bundle.
    private var appURL: URL { bundle.bundleURL.resolvingSymlinksInPath() }

    init(model: HubPresentation, defaults: UserDefaults) {
        self.model = model
        self.defaults = defaults
        var status = UpdateStatus()
        status.currentVersion = bundle.infoDictionary?["CFBundleShortVersionString"] as? String
        status.autoCheck = defaults.object(forKey: Key.autoCheck) as? Bool ?? true
        status.lastCheck = (defaults.object(forKey: Key.lastCheck) as? Double).map(Date.init(timeIntervalSince1970:))
        status.block = Self.installBlock(bundle: bundle, path: appURL.path)
        status.release = cachedRelease
        status.phase = status.offered == nil ? .idle : .available
        pendingFailure = UpdateInstaller.takeHelperFailure(at: resultFile)
        if pendingFailure { status.phase = .failed(.replacementFailed) }
        model.update = status
        model.checkForUpdate = { [weak self] in self?.manualCheck() }
        model.installUpdate = { [weak self] in self?.install() }
        model.setAutoUpdate = { [weak self] in self?.setAutoCheck($0) }
        model.openReleasePage = { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.open(model.update.offered?.notesURL ?? UpdateRules.releasesPageURL)
        }
    }

    private static func installBlock(bundle: Bundle, path: String) -> UpdateInstallBlock? {
        #if DEBUG
        let debug = true
        #else
        let debug = false
        #endif
        return UpdateInstallFacts.observe(bundlePath: path, bundleIdentifier: bundle.bundleIdentifier,
                                          version: bundle.infoDictionary?["CFBundleShortVersionString"] as? String, isDebugBuild: debug).block
    }

    func start() {
        guard model.update.autoCheck else { return }
        schedule = Task { [weak self] in
            var failed = false
            if let self, UpdateSchedule.isDue(.launch, last: model.update.lastCheck, now: Date()) { failed = await !check() }
            while !Task.isCancelled {
                guard let self else { return }
                let delay = UpdateSchedule.delay(last: model.update.lastCheck, now: Date(), failed: failed)
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                failed = UpdateSchedule.isDue(.periodic, last: model.update.lastCheck, now: Date()) ? await !check() : false
            }
        }
    }

    func stop() {
        schedule?.cancel()
        wake?.cancel()
    }

    /// The network needs a moment after a wake. An overdue timer would fire now and fail quietly, then wait for the retry.
    func woke() {
        wake?.cancel()
        guard model.update.autoCheck else { return }
        wake = Task { [weak self] in
            try? await Task.sleep(for: Self.waitAfterWake)
            guard let self, !Task.isCancelled, UpdateSchedule.isDue(.periodic, last: model.update.lastCheck, now: Date()) else { return }
            await check()
        }
    }

    private func setAutoCheck(_ enabled: Bool) {
        model.update.autoCheck = enabled
        defaults.set(enabled, forKey: Key.autoCheck)
        stop()
        if enabled { start() }
    }

    private func manualCheck() {
        guard !model.update.phase.isInstalling else { return }
        pendingFailure = false
        model.update.phase = .checking
        Task { await check() }
    }

    /// Returns whether GitHub answered. One request runs at a time; a manual check joins one already under way.
    @discardableResult
    private func check() async -> Bool {
        if let checking { return await checking.value }
        let running = Task { @MainActor in await self.fetch() }
        checking = running
        let answered = await running.value
        checking = nil
        return answered
    }

    private func fetch() async -> Bool {
        guard !model.update.phase.isInstalling else { return false }
        do {
            let release = try await latestRelease()
            guard !model.update.phase.isInstalling else { return true }
            let now = Date()
            defaults.set(now.timeIntervalSince1970, forKey: Key.lastCheck)
            model.update.lastCheck = now
            model.update.release = release
            if !pendingFailure { model.update.phase = model.update.offered == nil ? .upToDate : .available }
            return true
        } catch {
            guard !model.update.phase.isInstalling else { return false }
            // Only someone who asked hears about it; an automatic check leaves what the screens already show.
            if model.update.phase == .checking { model.update.phase = .failed(error as? UpdateError ?? .network) }
            return false
        }
    }

    private var cachedRelease: UpdateRelease? {
        defaults.data(forKey: Key.body).flatMap { try? UpdateRules.parseRelease($0) }
    }

    /// GitHub answers one variant per Accept header, so the ETag only holds with this exact request.
    private func latestRelease() async throws -> UpdateRelease? {
        var request = URLRequest(url: UpdateRules.latestReleaseURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Tokloom/" + (model.update.currentVersion ?? "0"), forHTTPHeaderField: "User-Agent")
        // Without the body it answered, a 304 would say nothing.
        if cachedRelease != nil, let etag = defaults.string(forKey: Key.etag) { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let session = URLSession(configuration: UpdateTransfer.configuration)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(for: request, delegate: RedirectRefusal()),
              let http = response as? HTTPURLResponse else { throw UpdateError.network }
        switch http.statusCode {
        case 200:
            let release = try UpdateRules.parseRelease(data)
            defaults.set(data, forKey: Key.body)
            defaults.set(http.value(forHTTPHeaderField: "ETag"), forKey: Key.etag)
            return release
        case 304: return cachedRelease
        case 403, 429: throw UpdateError.rateLimited
        default: throw UpdateError.invalidResponse
        }
    }

    private func install() {
        guard model.update.canInstall, let release = model.update.offered else { return }
        pendingFailure = false
        model.update.phase = .downloading(0)
        let target = appURL
        let pid = ProcessInfo.processInfo.processIdentifier
        let result = resultFile
        Task {
            do {
                let staged = try await prepare(release, target: target)
                model.update.phase = .restarting
                do {
                    try UpdateInstaller.handOver(staged, pid: pid, result: result)
                } catch {
                    UpdateInstaller.discard(staged)
                    throw error
                }
                // A socket client gets its reply first, as with quit.
                try? await Task.sleep(for: .milliseconds(500))
                model.quit?()
            } catch {
                model.update.phase = .failed(error as? UpdateError ?? .stagingFailed)
            }
        }
    }

    /// Download, verify and stage. Nothing here touches the app, so any failure simply leaves it as it was.
    private func prepare(_ release: UpdateRelease, target: URL) async throws -> UpdateInstaller.Staged {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("tokloom-update-" + UUID().uuidString, isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])) != nil else {
            throw UpdateError.stagingFailed
        }
        defer { try? FileManager.default.removeItem(at: scratch) }
        let image = scratch.appendingPathComponent(UpdateRules.imageName)
        let checksum = scratch.appendingPathComponent(UpdateRules.checksumName)
        try await UpdateTransfer(destination: checksum, asset: release.checksum).run()
        try await UpdateTransfer(destination: image, asset: release.image) { [weak self] fraction in
            Task { @MainActor in
                guard let self, case .downloading = self.model.update.phase else { return }
                self.model.update.phase = .downloading(fraction)
            }
        }.run()
        model.update.phase = .verifying
        return try await Task.detached(priority: .userInitiated) {
            guard let text = try? String(contentsOf: checksum, encoding: .utf8) else { throw UpdateError.checksumUnreadable }
            try UpdateRules.verifyChecksum(of: image, expected: try UpdateRules.parseChecksum(text, assetName: UpdateRules.imageName))
            return try UpdateInstaller.stage(image: image, version: release.version, target: target, scratch: scratch)
        }.value
    }
}

private final class RedirectRefusal: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? { nil }
}

/// One asset to one file: every redirect is checked, and the transfer stops at the size the release promised.
private final class UpdateTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 900
        return configuration
    }

    private let destination: URL
    private let asset: UpdateRelease.Asset
    private let progress: (@Sendable (Double) -> Void)?
    // Touched only on the session's serial delegate queue, and by `run` before the task starts.
    private var outcome: Result<Void, UpdateError>?
    private var finished: CheckedContinuation<Void, Error>?

    init(destination: URL, asset: UpdateRelease.Asset, progress: (@Sendable (Double) -> Void)? = nil) {
        self.destination = destination
        self.asset = asset
        self.progress = progress
    }

    func run() async throws {
        guard UpdateRules.isAllowedDownload(asset.url) else { throw UpdateError.unsafeURL }
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: Self.configuration, delegate: self, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { continuation in
            finished = continuation
            session.downloadTask(with: asset.url).resume()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        if let url = request.url, UpdateRules.isAllowedDownload(url) { return completionHandler(request) }
        outcome = .failure(.unsafeURL)
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesWritten <= asset.size else {
            outcome = .failure(.tooLarge)
            return downloadTask.cancel()
        }
        progress?(Double(totalBytesWritten) / Double(asset.size))
    }

    /// The file is gone once this returns, so it moves here.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200,
              let final = downloadTask.response?.url, UpdateRules.isAllowedDownload(final) else {
            if outcome == nil { outcome = .failure(.incompleteDownload) }
            return
        }
        let size = (try? location.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        guard size == asset.size, (try? FileManager.default.moveItem(at: location, to: destination)) != nil else {
            outcome = .failure(.incompleteDownload)
            return
        }
        outcome = .success(())
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result = outcome ?? .failure(error == nil ? .incompleteDownload : .network)
        finished?.resume(with: result.mapError { $0 as Error })
        finished = nil
    }
}
