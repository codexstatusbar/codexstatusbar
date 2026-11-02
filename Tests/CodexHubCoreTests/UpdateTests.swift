import Darwin
import Foundation
import Testing
import CodexHubCore

private func release(tag: String = "1.2.3", draft: Bool = false, prerelease: Bool = false, notes: String? = nil,
                     imageURL: String? = nil, imageSize: Int = 3_492_404, imageState: String = "uploaded", includeChecksum: Bool = true) -> Data {
    let base = "https://github.com/codexstatusbar/codexstatusbar/releases"
    var assets: [[String: Any]] = [["name": "Tokloom-macos-arm64.dmg", "size": imageSize, "state": imageState,
                                    "browser_download_url": imageURL ?? "\(base)/download/\(tag)/Tokloom-macos-arm64.dmg"]]
    if includeChecksum {
        assets.append(["name": "Tokloom-macos-arm64.dmg.sha256", "size": 90, "state": "uploaded",
                       "browser_download_url": "\(base)/download/\(tag)/Tokloom-macos-arm64.dmg.sha256"])
    }
    let body: [String: Any] = ["tag_name": tag, "draft": draft, "prerelease": prerelease, "html_url": notes ?? "\(base)/tag/\(tag)", "assets": assets]
    return try! JSONSerialization.data(withJSONObject: body)
}

private func version(_ text: String) -> ReleaseVersion { ReleaseVersion(text)! }

/// A temporary folder that takes itself away, with any read-only folders inside it.
private final class Sandbox {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tokloom-tests-" + UUID().uuidString, isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    deinit {
        _ = run("/bin/chmod", ["-R", "u+rwx", root.path])
        try? FileManager.default.removeItem(at: root)
    }
    func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    /// A signed bundle shaped like Tokloom; `marker` tells two of them apart after a swap.
    @discardableResult
    func app(at url: URL, identifier: String = UpdateRules.bundleIdentifier, version: String = "1.2.3", marker: String = "new", signed: Bool = true) throws -> URL {
        let macOS = url.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleExecutable": UpdateRules.executableName, "CFBundleShortVersionString": version]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url.appendingPathComponent("Contents/Info.plist"))
        let executable = macOS.appendingPathComponent(UpdateRules.executableName)
        try Data("#!/bin/sh\n# \(marker)\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        if signed { #expect(run("/usr/bin/codesign", ["--force", "--sign", "-", url.path]) == 0) }
        return url
    }
    /// Stands in for `open`: records what it was asked to open, and fails as many times as there are lines in `failures`.
    func opener(failures: Int = 0) throws -> (tool: URL, log: URL) {
        let tool = root.appendingPathComponent("fake-open-" + UUID().uuidString)
        let log = root.appendingPathComponent(tool.lastPathComponent + ".log")
        let count = root.appendingPathComponent(tool.lastPathComponent + ".count")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$2" >> '\(log.path)'
        printf x >> '\(count.path)'
        [ "$(wc -c < '\(count.path)')" -gt \(failures) ]
        """
        try Data(script.utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        return (tool, log)
    }
}

@discardableResult
private func run(_ tool: String, _ arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return -1 }
    process.waitUntilExit()
    return process.terminationStatus
}

private func marker(of app: URL) -> String? {
    (try? String(contentsOf: app.appendingPathComponent("Contents/MacOS/\(UpdateRules.executableName)"), encoding: .utf8))?
        .split(separator: "\n").last.map { String($0.dropFirst(2)) }
}

/// A pid that existed and has exited.
private func goneProcess() -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try! process.run()
    process.waitUntilExit()
    return process.processIdentifier
}

private struct Swap {
    let sandbox: Sandbox
    let staged: UpdateInstaller.Staged
    let result: URL
    /// `Tokloom.app` holding marker "old", and a staged copy holding marker "new", laid out as `stage` leaves them.
    init(_ sandbox: Sandbox, folder name: String = "Applications") throws {
        self.sandbox = sandbox
        let folder = try sandbox.folder(name)
        let target = folder.appendingPathComponent("Tokloom.app", isDirectory: true)
        try sandbox.app(at: target, version: "1.2.2", marker: "old")
        let incoming = try sandbox.app(at: sandbox.root.appendingPathComponent("incoming-\(UUID().uuidString).app"))
        staged = try UpdateInstaller.stage(app: incoming, version: version("1.2.3"), target: target)
        result = sandbox.root.appendingPathComponent("result")
    }
    /// Runs the real helper to its end.
    func helper(pid: Int32, opener: URL, waitSeconds: Int = 30) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = UpdateInstaller.helperArguments(staged, pid: pid, result: result, opener: opener.path, waitSeconds: waitSeconds)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
    var report: String? { (try? String(contentsOf: result, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) }
    var workRemains: Bool { FileManager.default.fileExists(atPath: staged.work.path) }
}

// MARK: Versions and responses

@Test(arguments: [("1.2.3", "1.2.4"), ("1.2.9", "1.3.0"), ("1.9.9", "2.0.0"), ("0.0.9", "0.0.10"), ("0.9.0", "0.10.0")])
func U01VersionsCompareAsNumbers(older: String, newer: String) {
    #expect(version(older) < version(newer))
    #expect(!(version(newer) < version(older)))
}

@Test(arguments: ["", "1", "1.2", "1.2.3.4", "v1.2.3", "1.2.3-beta", "01.2.3", "1.2.3 ", "1000.0.0", "1..3", "a.b.c", "1.2.+3"])
func U02OnlyCanonicalVersionsParse(text: String) {
    #expect(ReleaseVersion(text) == nil)
}

@Test func U03APublishedReleaseOffersItsAssets() throws {
    let parsed = try #require(try UpdateRules.parseRelease(release()))
    #expect(parsed.version == version("1.2.3"))
    #expect(parsed.image.url.lastPathComponent == UpdateRules.imageName && parsed.image.size == 3_492_404)
    #expect(parsed.checksum.url.lastPathComponent == UpdateRules.checksumName)
    #expect(parsed.notesURL.absoluteString.hasSuffix("/releases/tag/1.2.3"))
}

@Test func U04DraftsAndPrereleasesAreNeverOffered() throws {
    #expect(try UpdateRules.parseRelease(release(draft: true)) == nil)
    #expect(try UpdateRules.parseRelease(release(prerelease: true)) == nil)
}

@Test func U05MalformedResponsesAreRefused() {
    #expect(throws: UpdateError.invalidResponse) { try UpdateRules.parseRelease(Data("not json".utf8)) }
    #expect(throws: UpdateError.invalidResponse) { try UpdateRules.parseRelease(Data("{}".utf8)) }
    #expect(throws: UpdateError.invalidResponse) { try UpdateRules.parseRelease(release(tag: "v1.2.3")) }
    #expect(throws: UpdateError.invalidResponse) { try UpdateRules.parseRelease(release(includeChecksum: false)) }
    #expect(throws: UpdateError.invalidResponse) { try UpdateRules.parseRelease(release(imageState: "starter")) }
    #expect(throws: UpdateError.invalidResponse) { try UpdateRules.parseRelease(release(imageSize: 0)) }
    #expect(throws: UpdateError.invalidResponse) { try UpdateRules.parseRelease(Data(count: UpdateRules.maximumResponseBytes + 1)) }
}

@Test func U06AnAssetMustBeThisReleaseOnThisRepositoryAndFitTheLimit() {
    #expect(throws: UpdateError.unsafeURL) { try UpdateRules.parseRelease(release(imageURL: "https://evil.example/Tokloom-macos-arm64.dmg")) }
    #expect(throws: UpdateError.unsafeURL) { try UpdateRules.parseRelease(release(imageURL: "http://github.com/codexstatusbar/codexstatusbar/releases/download/1.2.3/Tokloom-macos-arm64.dmg")) }
    #expect(throws: UpdateError.unsafeURL) { try UpdateRules.parseRelease(release(imageURL: "https://github.com/someone/fork/releases/download/1.2.3/Tokloom-macos-arm64.dmg")) }
    #expect(throws: UpdateError.unsafeURL) { try UpdateRules.parseRelease(release(imageURL: "https://github.com/codexstatusbar/codexstatusbar/releases/download/1.0.0/Tokloom-macos-arm64.dmg")) }
    #expect(throws: UpdateError.unsafeURL) { try UpdateRules.parseRelease(release(notes: "https://evil.example/notes")) }
    #expect(throws: UpdateError.tooLarge) { try UpdateRules.parseRelease(release(imageSize: UpdateRules.maximumImageBytes + 1)) }
}

@Test(arguments: [
    "https://github.com/codexstatusbar/codexstatusbar/releases/download/1.2.3/Tokloom-macos-arm64.dmg",
    "https://release-assets.githubusercontent.com/github-production-release-asset/1/x?sig=y",
    "https://objects.githubusercontent.com/github-production-release-asset/1/x"
])
func U07DownloadsMayFollowGitHubsAssetHosts(address: String) throws {
    #expect(UpdateRules.isAllowedDownload(try #require(URL(string: address))))
}

@Test(arguments: [
    "http://release-assets.githubusercontent.com/x",
    "https://evil.example/x",
    "https://github.com.evil.example/codexstatusbar/codexstatusbar/releases/download/x",
    "https://evilgithub.com/x",
    "https://raw.githubusercontent.com/x",
    "https://user@release-assets.githubusercontent.com/x",
    "https://user:secret@github.com/codexstatusbar/codexstatusbar/releases/download/x",
    "https://release-assets.githubusercontent.com:8443/x",
    "https://github.com/someone/fork/releases/download/1.2.3/Tokloom-macos-arm64.dmg",
    "https://github.com/codexstatusbar/codexstatusbar/archive/main.zip",
    "file:///tmp/Tokloom-macos-arm64.dmg"
])
func U08ARedirectAnywhereElseIsRefused(address: String) throws {
    #expect(!UpdateRules.isAllowedDownload(try #require(URL(string: address))))
}

// MARK: Checksums

@Test func U09TheChecksumFileMustBeTheLineShasumWrites() throws {
    let digest = String(repeating: "a", count: 64)
    #expect(try UpdateRules.parseChecksum("\(digest)  Tokloom-macos-arm64.dmg\n", assetName: UpdateRules.imageName) == digest)
    #expect(try UpdateRules.parseChecksum("\(digest) *Tokloom-macos-arm64.dmg", assetName: UpdateRules.imageName) == digest)
    for bad in ["", digest, "\(digest)  other.dmg\n", String(digest.dropLast()) + "  Tokloom-macos-arm64.dmg", String(repeating: "A", count: 64) + "  Tokloom-macos-arm64.dmg",
                "\(digest)  Tokloom-macos-arm64.dmg\n\(digest)  Tokloom-macos-arm64.dmg\n", "<html>Not Found</html>"] {
        #expect(throws: UpdateError.checksumUnreadable) { try UpdateRules.parseChecksum(bad, assetName: UpdateRules.imageName) }
    }
}

@Test func U10AChangedFileFailsItsChecksum() throws {
    let sandbox = try Sandbox()
    let file = sandbox.root.appendingPathComponent("image")
    try Data("abc".utf8).write(to: file)
    // SHA-256 of "abc", the FIPS 180 test vector.
    let expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    #expect(try UpdateRules.sha256(of: file) == expected)
    try UpdateRules.verifyChecksum(of: file, expected: expected)
    try Data("abd".utf8).write(to: file)
    #expect(throws: UpdateError.checksumMismatch) { try UpdateRules.verifyChecksum(of: file, expected: expected) }
    #expect(throws: UpdateError.checksumMismatch) { try UpdateRules.verifyChecksum(of: sandbox.root.appendingPathComponent("missing"), expected: expected) }
}

// MARK: The app in the image

@Test func U11OnlyTokloomOfTheExpectedVersionPasses() throws {
    let sandbox = try Sandbox()
    let good = try sandbox.app(at: sandbox.root.appendingPathComponent("good.app"), signed: false)
    try UpdateRules.verifyBundle(at: good, version: version("1.2.3"))
    let other = try sandbox.app(at: sandbox.root.appendingPathComponent("other.app"), identifier: "com.example.other", signed: false)
    #expect(throws: UpdateError.wrongBundleIdentifier) { try UpdateRules.verifyBundle(at: other, version: version("1.2.3")) }
    #expect(throws: UpdateError.wrongVersion) { try UpdateRules.verifyBundle(at: good, version: version("1.2.4")) }
    #expect(throws: UpdateError.wrongBundleIdentifier) { try UpdateRules.verifyBundle(at: sandbox.root.appendingPathComponent("missing.app"), version: version("1.2.3")) }
    try FileManager.default.removeItem(at: good.appendingPathComponent("Contents/MacOS/\(UpdateRules.executableName)"))
    #expect(throws: UpdateError.appMissing) { try UpdateRules.verifyBundle(at: good, version: version("1.2.3")) }
}

@Test func U12StagingChecksTheCopyAndLeavesNothingWhenItFails() throws {
    let sandbox = try Sandbox()
    let folder = try sandbox.folder("Applications")
    let target = try sandbox.app(at: folder.appendingPathComponent("Tokloom.app"), version: "1.2.2", marker: "old")
    func entries() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: folder.path) }

    let wrongID = try sandbox.app(at: sandbox.root.appendingPathComponent("a.app"), identifier: "com.example.other")
    #expect(throws: UpdateError.wrongBundleIdentifier) { try UpdateInstaller.stage(app: wrongID, version: version("1.2.3"), target: target) }
    let wrongVersion = try sandbox.app(at: sandbox.root.appendingPathComponent("b.app"), version: "1.2.1")
    #expect(throws: UpdateError.wrongVersion) { try UpdateInstaller.stage(app: wrongVersion, version: version("1.2.3"), target: target) }
    let tampered = try sandbox.app(at: sandbox.root.appendingPathComponent("c.app"))
    try Data("#!/bin/sh\n# tampered\n".utf8).write(to: tampered.appendingPathComponent("Contents/MacOS/\(UpdateRules.executableName)"))
    #expect(throws: UpdateError.invalidSignature) { try UpdateInstaller.stage(app: tampered, version: version("1.2.3"), target: target) }
    let unsigned = try sandbox.app(at: sandbox.root.appendingPathComponent("d.app"), signed: false)
    #expect(throws: UpdateError.invalidSignature) { try UpdateInstaller.stage(app: unsigned, version: version("1.2.3"), target: target) }
    let link = sandbox.root.appendingPathComponent("e.app")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: wrongID)
    #expect(throws: UpdateError.appMissing) { try UpdateInstaller.stage(app: link, version: version("1.2.3"), target: target) }

    #expect(try entries() == ["Tokloom.app"], "a refused app leaves the folder as it was")
    #expect(marker(of: target) == "old")
}

@Test func U13StagingSweepsWhatAnInterruptedInstallLeft() throws {
    let sandbox = try Sandbox()
    let folder = try sandbox.folder("Applications")
    let target = try sandbox.app(at: folder.appendingPathComponent("Tokloom.app"), version: "1.2.2", marker: "old")
    let leftover = try sandbox.folder("Applications/.Tokloom-update-interrupted")
    let unrelated = try sandbox.folder("Applications/Other.app")
    let incoming = try sandbox.app(at: sandbox.root.appendingPathComponent("incoming.app"))
    _ = try UpdateInstaller.stage(app: incoming, version: version("1.2.3"), target: target)
    #expect(!FileManager.default.fileExists(atPath: leftover.path))
    #expect(FileManager.default.fileExists(atPath: unrelated.path))
}

@Test func U14ARealDiskImageIsMountedStagedAndDetached() throws {
    let sandbox = try Sandbox()
    let contents = try sandbox.folder("contents")
    try sandbox.app(at: contents.appendingPathComponent(UpdateRules.appName))
    let image = sandbox.root.appendingPathComponent("image.dmg")
    #expect(run("/usr/bin/hdiutil", ["create", "-quiet", "-volname", "Tokloom", "-srcfolder", contents.path, "-fs", "HFS+", "-format", "UDZO", image.path]) == 0)
    let folder = try sandbox.folder("Applications")
    let target = try sandbox.app(at: folder.appendingPathComponent("Tokloom.app"), version: "1.2.2", marker: "old")
    let scratch = try sandbox.folder("scratch")

    let staged = try UpdateInstaller.stage(image: image, version: version("1.2.3"), target: target, scratch: scratch)

    #expect(marker(of: staged.app) == "new")
    #expect(staged.work.deletingLastPathComponent() == folder, "beside the app, so the swap is a rename")
    let mounted = try FileManager.default.subpathsOfDirectory(atPath: scratch.path).filter { $0.hasSuffix(UpdateRules.appName) }
    #expect(mounted.isEmpty, "detached")

    let empty = try sandbox.folder("empty-contents")
    let noApp = sandbox.root.appendingPathComponent("empty.dmg")
    try Data("x".utf8).write(to: empty.appendingPathComponent("readme"))
    #expect(run("/usr/bin/hdiutil", ["create", "-quiet", "-volname", "Empty", "-srcfolder", empty.path, "-fs", "HFS+", "-format", "UDZO", noApp.path]) == 0)
    #expect(throws: UpdateError.appMissing) { try UpdateInstaller.stage(image: noApp, version: version("1.2.3"), target: target, scratch: scratch) }
    let garbage = sandbox.root.appendingPathComponent("garbage.dmg")
    try Data("not an image".utf8).write(to: garbage)
    #expect(throws: UpdateError.mountFailed) { try UpdateInstaller.stage(image: garbage, version: version("1.2.3"), target: target, scratch: scratch) }
}

@Test func U15StagingKeepsQuarantineItNeverRemovesOrAddsIt() throws {
    let sandbox = try Sandbox()
    let folder = try sandbox.folder("Applications")
    let target = try sandbox.app(at: folder.appendingPathComponent("Tokloom.app"), version: "1.2.2", marker: "old")
    let incoming = try sandbox.app(at: sandbox.root.appendingPathComponent("incoming.app"))
    func quarantine(_ url: URL) -> Int { getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0) }

    let plain = try UpdateInstaller.stage(app: incoming, version: version("1.2.3"), target: target)
    #expect(quarantine(plain.app) < 0, "none is added")
    UpdateInstaller.discard(plain)

    let flag = "0081;00000000;Tokloom test;"
    #expect(setxattr(incoming.path, "com.apple.quarantine", flag, flag.utf8.count, 0, 0) == 0)
    let marked = try UpdateInstaller.stage(app: incoming, version: version("1.2.3"), target: target)
    #expect(quarantine(marked.app) > 0, "what is there stays")
    #expect(!UpdateInstaller.helperScript.contains("xattr") && !UpdateInstaller.helperScript.contains("spctl"))
}

// MARK: Who may install

private func facts(path: String = "/Applications/Tokloom.app", identifier: String? = UpdateRules.bundleIdentifier, version: String? = "1.2.3",
                   debug: Bool = false, readOnly: Bool = false, writable: Bool = true) -> UpdateInstallFacts {
    UpdateInstallFacts(bundlePath: path, bundleIdentifier: identifier, version: version, isDebugBuild: debug, volumeIsReadOnly: readOnly, canWrite: writable)
}

@Test func U16AnInstalledReleaseMayReplaceItself() {
    #expect(facts().block == nil)
    #expect(facts(path: "/Users/me/Apps/Tokloom.app").block == nil)
}

@Test func U17EveryUnsafeCopyIsSentToTheReleasePage() {
    #expect(facts(debug: true).block == .debugBuild)
    #expect(facts(version: "0.0.0").block == .unversionedBuild)
    #expect(facts(version: nil).block == .unversionedBuild)
    #expect(facts(version: "dev").block == .unversionedBuild)
    #expect(facts(path: "/usr/local/bin/CodexHubApp").block == .notAnAppBundle)
    #expect(facts(identifier: "com.example.other").block == .wrongBundleIdentifier)
    #expect(facts(identifier: nil).block == .wrongBundleIdentifier)
    #expect(facts(path: "/private/var/folders/x/T/AppTranslocation/UUID/d/Tokloom.app").block == .translocated)
    #expect(facts(path: "/Volumes/Tokloom/Tokloom.app", readOnly: true).block == .readOnlyVolume)
    #expect(facts(writable: false).block == .notWritable)
}

@Test func U18WriteAccessIsMeasuredOnTheFolderAndTheBundle() throws {
    let sandbox = try Sandbox()
    let folder = try sandbox.folder("Applications")
    let app = try sandbox.app(at: folder.appendingPathComponent("Tokloom.app"), signed: false)
    func block() -> UpdateInstallBlock? {
        UpdateInstallFacts.observe(bundlePath: app.path, bundleIdentifier: UpdateRules.bundleIdentifier, version: "1.2.3", isDebugBuild: false).block
    }
    #expect(block() == nil)
    #expect(chmod(folder.path, 0o555) == 0)
    #expect(block() == .notWritable, "the folder")
    #expect(chmod(folder.path, 0o755) == 0)
    #expect(chmod(app.path, 0o555) == 0)
    #expect(block() == .notWritable, "the bundle")
}

@Test func U19AnOfferNeedsANewerReleaseAndInstallNeedsNoBlock() throws {
    var status = UpdateStatus()
    #expect(status.autoCheck, "automatic checks are on by default")
    status.release = try UpdateRules.parseRelease(release())
    #expect(status.offered == nil, "no current version, no offer")
    status.currentVersion = "1.2.3"
    #expect(status.offered == nil && !status.canInstall)
    status.currentVersion = "1.2.4"
    #expect(status.offered == nil, "no downgrades")
    status.currentVersion = "1.2.2"
    #expect(status.offered != nil && status.canInstall)
    status.phase = .downloading(0.5)
    #expect(!status.canInstall, "one install at a time")
    status.phase = .failed(.checksumMismatch)
    #expect(status.canInstall, "a failed install can be retried")
    status.block = .notWritable
    #expect(status.offered != nil && !status.canInstall, "a blocked copy still hears about the release")
}

// MARK: When to ask

@Test func U20EveryLaunchChecksExceptRightAfterAnother() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(UpdateSchedule.isDue(.launch, last: nil, now: now), "first launch")
    #expect(UpdateSchedule.isDue(.launch, last: now.addingTimeInterval(-3600), now: now), "within the six hours, a launch still checks")
    #expect(UpdateSchedule.isDue(.launch, last: now.addingTimeInterval(-UpdateSchedule.launchFloor), now: now))
    #expect(!UpdateSchedule.isDue(.launch, last: now.addingTimeInterval(-60), now: now), "a restart loop does not spend the hourly limit")
    #expect(UpdateSchedule.isDue(.launch, last: now.addingTimeInterval(60), now: now), "a clock that moved back does not stop checks")
}

@Test func U21PeriodicAndWakeChecksWaitForTheInterval() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(!UpdateSchedule.isDue(.periodic, last: now.addingTimeInterval(-5 * 3600), now: now), "woke before the period ended")
    #expect(UpdateSchedule.isDue(.periodic, last: now.addingTimeInterval(-6 * 3600), now: now), "woke after it ended")
    #expect(UpdateSchedule.isDue(.periodic, last: now.addingTimeInterval(-3 * 86400), now: now), "slept for days")
    #expect(UpdateSchedule.isDue(.periodic, last: nil, now: now))
    #expect(UpdateSchedule.isDue(.periodic, last: now.addingTimeInterval(60), now: now), "a clock that moved back does not stop checks")
}

@Test func U22TheNextCheckCountsFromTheSavedTime() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(UpdateSchedule.delay(last: now, now: now, failed: false) == 6 * 3600)
    #expect(UpdateSchedule.delay(last: now.addingTimeInterval(-3600), now: now, failed: false) == 5 * 3600, "a restart does not reset the period")
    #expect(UpdateSchedule.delay(last: now.addingTimeInterval(-7 * 3600), now: now, failed: false) == 0, "overdue")
    #expect(UpdateSchedule.delay(last: now.addingTimeInterval(9000), now: now, failed: false) == 6 * 3600, "never longer than the period")
    #expect(UpdateSchedule.delay(last: nil, now: now, failed: false) == 6 * 3600)
    #expect(UpdateSchedule.delay(last: now.addingTimeInterval(-7 * 3600), now: now, failed: true) == UpdateSchedule.retry, "a failure waits instead of spinning")
}

// MARK: The helper, run for real on fake apps

@Test func U23TheHelperSwapsTheAppAndOpensIt() throws {
    let sandbox = try Sandbox()
    let swap = try Swap(sandbox)
    let opener = try sandbox.opener()
    #expect(try swap.helper(pid: goneProcess(), opener: opener.tool) == 0)
    #expect(marker(of: swap.staged.target) == "new")
    #expect(try String(contentsOf: opener.log, encoding: .utf8) == swap.staged.target.path + "\n")
    #expect(!swap.workRemains && swap.report == nil)
}

@Test func U24TheHelperWaitsForItsPid() throws {
    let sandbox = try Sandbox()
    let swap = try Swap(sandbox)
    let opener = try sandbox.opener()
    let app = Process()
    app.executableURL = URL(fileURLWithPath: "/bin/sleep")
    app.arguments = ["1.5"]
    try app.run()
    let helper = Process()
    helper.executableURL = URL(fileURLWithPath: "/bin/sh")
    helper.arguments = UpdateInstaller.helperArguments(swap.staged, pid: app.processIdentifier, result: swap.result, opener: opener.tool.path)
    try helper.run()
    usleep(500_000)
    #expect(marker(of: swap.staged.target) == "old", "untouched while the app runs")
    helper.waitUntilExit()
    #expect(!app.isRunning)
    #expect(marker(of: swap.staged.target) == "new")
}

@Test func U25AnAppThatWillNotQuitIsLeftAlone() throws {
    let sandbox = try Sandbox()
    let swap = try Swap(sandbox)
    let opener = try sandbox.opener()
    let app = Process()
    app.executableURL = URL(fileURLWithPath: "/bin/sleep")
    app.arguments = ["30"]
    try app.run()
    defer { app.terminate() }
    #expect(try swap.helper(pid: app.processIdentifier, opener: opener.tool, waitSeconds: 1) == 1)
    #expect(app.isRunning, "only waited; never signalled")
    #expect(marker(of: swap.staged.target) == "old")
    #expect(swap.report == "still-running" && !swap.workRemains)
    #expect(!FileManager.default.fileExists(atPath: opener.log.path), "the app is still running, so nothing opens a second one")
}

@Test func U26AFailedReplacementPutsTheOldAppBack() throws {
    let sandbox = try Sandbox()
    let swap = try Swap(sandbox)
    let opener = try sandbox.opener()
    try FileManager.default.removeItem(at: swap.staged.app)
    #expect(try swap.helper(pid: goneProcess(), opener: opener.tool) == 1)
    #expect(marker(of: swap.staged.target) == "old")
    #expect(swap.report == "replace-failed" && !swap.workRemains)
    #expect(try String(contentsOf: opener.log, encoding: .utf8) == swap.staged.target.path + "\n", "the old app comes back up")
}

@Test func U27ANewAppThatWillNotOpenIsRolledBack() throws {
    let sandbox = try Sandbox()
    let swap = try Swap(sandbox)
    let opener = try sandbox.opener(failures: 1)
    #expect(try swap.helper(pid: goneProcess(), opener: opener.tool) == 1)
    #expect(marker(of: swap.staged.target) == "old")
    #expect(swap.report == "replace-failed" && !swap.workRemains)
    #expect(try String(contentsOf: opener.log, encoding: .utf8).split(separator: "\n").count == 2, "tried the new app, then the old one")
}

@Test func U28AnUnwritableFolderStopsBeforeAnythingMoves() throws {
    let sandbox = try Sandbox()
    let swap = try Swap(sandbox)
    let opener = try sandbox.opener()
    #expect(chmod(swap.staged.target.deletingLastPathComponent().path, 0o555) == 0)
    #expect(try swap.helper(pid: goneProcess(), opener: opener.tool) == 1)
    #expect(marker(of: swap.staged.target) == "old")
    #expect(swap.report == "backup-failed")
}

@Test func U29TheOnlyRemainingCopyIsNeverDeleted() throws {
    let sandbox = try Sandbox()
    let swap = try Swap(sandbox)
    let opener = try sandbox.opener(failures: 1)
    // The new app fails to open, and a stale file now blocks the old app's way back.
    let backup = swap.staged.work.appendingPathComponent("old.app")
    let script = UpdateInstaller.helperScript.replacingOccurrences(of: #"if ! /bin/mv -- "$backup" "$target"; then"#, with: #"if ! /bin/mv -- "$backup/missing" "$target"; then"#)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    var arguments = UpdateInstaller.helperArguments(swap.staged, pid: goneProcess(), result: swap.result, opener: opener.tool.path)
    arguments[1] = script
    process.arguments = arguments
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 2)
    #expect(swap.report == "restore-failed")
    #expect(marker(of: backup) == "old", "the work folder stays because it holds the app")
}

@Test(arguments: ["with space", "quo\"te", "sin'gle", "$(touch pwned)", "`touch pwned`", "semi;colon", "new\nline", "-dash", "star*", "한글"])
func U30PathsNeverBecomeCode(name: String) throws {
    let sandbox = try Sandbox()
    let swap = try Swap(sandbox, folder: "Apps \(name)")
    let opener = try sandbox.opener()
    #expect(try swap.helper(pid: goneProcess(), opener: opener.tool) == 0)
    #expect(marker(of: swap.staged.target) == "new")
    #expect(!swap.workRemains)
    #expect(!FileManager.default.fileExists(atPath: sandbox.root.appendingPathComponent("pwned").path))
    #expect(!FileManager.default.fileExists(atPath: "pwned"))
}

@Test func U31TheHelperOnlyDeletesItsOwnWorkFolder() throws {
    let sandbox = try Sandbox()
    let swap = try Swap(sandbox)
    let opener = try sandbox.opener()
    let precious = try sandbox.folder("precious")
    var arguments = UpdateInstaller.helperArguments(swap.staged, pid: goneProcess(), result: swap.result, opener: opener.tool.path)
    arguments[6] = precious.path
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 64)
    #expect(FileManager.default.fileExists(atPath: precious.path))
    #expect(marker(of: swap.staged.target) == "old")
}

@Test func U32TheHelpersReportIsReadOnce() throws {
    let sandbox = try Sandbox()
    let result = sandbox.root.appendingPathComponent("update-result")
    #expect(!UpdateInstaller.takeHelperFailure(at: result))
    try Data("replace-failed\n".utf8).write(to: result)
    #expect(UpdateInstaller.takeHelperFailure(at: result))
    #expect(!UpdateInstaller.takeHelperFailure(at: result))
}
