import CryptoKit
import Foundation

/// A release version: the canonical X.Y.Z that `scripts/release-version.py` accepts, and nothing else.
public struct ReleaseVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int, minor: Int, patch: Int

    public init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard (1...3).contains(part.count), part.utf8.allSatisfy({ (48...57).contains($0) }),
                  part == "0" || !part.hasPrefix("0"), let number = Int(part) else { return nil }
            numbers.append(number)
        }
        (major, minor, patch) = (numbers[0], numbers[1], numbers[2])
    }

    public static func < (left: Self, right: Self) -> Bool {
        (left.major, left.minor, left.patch) < (right.major, right.minor, right.patch)
    }
    public var description: String { "\(major).\(minor).\(patch)" }
    /// The placeholder in the repository's Info.plist: a build no release produced.
    public var isPlaceholder: Bool { major == 0 && minor == 0 && patch == 0 }
}

public enum UpdateError: Error, Equatable, Sendable, CaseIterable {
    case network, rateLimited, invalidResponse, unsafeURL, tooLarge, incompleteDownload
    case checksumUnreadable, checksumMismatch, mountFailed, appMissing
    case wrongBundleIdentifier, wrongVersion, invalidSignature, stagingFailed, helperFailed
    /// The previous launch handed over to the helper, which kept the old app.
    case replacementFailed

    /// An English key of `AppLanguage`.
    public var message: String {
        switch self {
        case .network: "Could not reach GitHub. Try again later."
        case .rateLimited: "GitHub is limiting requests from this network. Try again later."
        case .invalidResponse: "GitHub returned a release this app could not read."
        case .unsafeURL: "The download address is not a Tokloom release on GitHub, so it was refused."
        case .tooLarge: "The download is larger than a Tokloom release can be, so it was stopped."
        case .incompleteDownload: "The download did not finish. The current app was not changed."
        case .checksumUnreadable: "The release's checksum file could not be read. The current app was not changed."
        case .checksumMismatch: "The download does not match its checksum. The current app was not changed."
        case .mountFailed: "The downloaded disk image could not be opened. The current app was not changed."
        case .appMissing: "The disk image does not contain Tokloom. The current app was not changed."
        case .wrongBundleIdentifier: "The downloaded app is not Tokloom. The current app was not changed."
        case .wrongVersion: "The downloaded app is not the expected version. The current app was not changed."
        case .invalidSignature: "The downloaded app's signature is broken. The current app was not changed."
        case .stagingFailed: "The update could not be prepared next to the app. The current app was not changed."
        case .helperFailed: "The update could not start. The current app was not changed."
        case .replacementFailed: "The last update could not be installed, so the previous version was kept."
        }
    }
}

public struct UpdateRelease: Equatable, Sendable {
    public struct Asset: Equatable, Sendable {
        public let url: URL
        public let size: Int
    }
    public let version: ReleaseVersion
    public let notesURL: URL
    public let image: Asset
    public let checksum: Asset
}

/// Why this copy of the app cannot replace itself. The releases page stays available in every case.
public enum UpdateInstallBlock: String, Sendable, CaseIterable {
    case debugBuild, unversionedBuild, notAnAppBundle, wrongBundleIdentifier, translocated, readOnlyVolume, notWritable

    /// An English key of `AppLanguage`.
    public var message: String {
        switch self {
        case .debugBuild: "Development builds do not update themselves."
        case .unversionedBuild: "This build has no release version, so it does not update itself."
        case .notAnAppBundle, .wrongBundleIdentifier: "This copy is not a Tokloom app bundle, so it does not update itself."
        case .translocated: "macOS is running this copy from a temporary location. Move Tokloom to Applications, then open it again."
        case .readOnlyVolume: "Tokloom is running from a read-only disk. Drag it to Applications, then open it there."
        case .notWritable: "Tokloom cannot write to the folder it is in. Download the new version from the releases page."
        }
    }
}

/// What the install decision depends on, observed once so the decision itself is a pure rule.
public struct UpdateInstallFacts: Sendable {
    public var bundlePath: String
    public var bundleIdentifier: String?
    public var version: String?
    public var isDebugBuild: Bool
    public var volumeIsReadOnly: Bool
    public var canWrite: Bool

    public init(bundlePath: String, bundleIdentifier: String?, version: String?, isDebugBuild: Bool, volumeIsReadOnly: Bool, canWrite: Bool) {
        self.bundlePath = bundlePath
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.isDebugBuild = isDebugBuild
        self.volumeIsReadOnly = volumeIsReadOnly
        self.canWrite = canWrite
    }

    /// Replacing a bundle takes write access to both the bundle (its `..` moves) and the folder that holds it.
    public static func observe(bundlePath: String, bundleIdentifier: String?, version: String?, isDebugBuild: Bool) -> Self {
        let bundle = URL(fileURLWithPath: bundlePath)
        let readOnly = (try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        let writable = access(bundlePath, W_OK) == 0 && access(bundle.deletingLastPathComponent().path, W_OK) == 0
        return Self(bundlePath: bundlePath, bundleIdentifier: bundleIdentifier, version: version, isDebugBuild: isDebugBuild, volumeIsReadOnly: readOnly, canWrite: writable)
    }

    public var block: UpdateInstallBlock? {
        if isDebugBuild { return .debugBuild }
        guard let version = version.flatMap(ReleaseVersion.init), !version.isPlaceholder else { return .unversionedBuild }
        guard bundlePath.hasSuffix(".app") else { return .notAnAppBundle }
        guard bundleIdentifier == UpdateRules.bundleIdentifier else { return .wrongBundleIdentifier }
        if bundlePath.contains("/AppTranslocation/") { return .translocated }
        if volumeIsReadOnly { return .readOnlyVolume }
        return canWrite ? nil : .notWritable
    }
}

public enum UpdateRules {
    public static let repository = "codexstatusbar/codexstatusbar"
    public static let bundleIdentifier = "local.codexhub.app"
    public static let executableName = "CodexHubApp"
    public static let appName = "Tokloom.app"
    public static let imageName = "Tokloom-macos-arm64.dmg"
    public static let checksumName = imageName + ".sha256"
    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    public static let releasesPageURL = URL(string: "https://github.com/\(repository)/releases/latest")!
    /// Well above the 3.5 MB of today's image; a limit, not an estimate.
    public static let maximumImageBytes = 64 << 20
    public static let maximumChecksumBytes = 1024
    public static let maximumResponseBytes = 1 << 20
    /// `release-assets` is where GitHub sends these downloads today; `objects` is where it used to.
    private static let downloadHosts: Set<String> = ["github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com"]

    private struct Payload: Decodable {
        struct Asset: Decodable {
            let name: String
            let size: Int
            let state: String
            let browserDownloadUrl: String
        }
        let tagName: String
        let draft: Bool
        let prerelease: Bool
        let htmlUrl: String
        let assets: [Asset]
    }

    /// The release a `releases/latest` body offers, or nil for a draft or prerelease. Anything malformed throws.
    public static func parseRelease(_ data: Data) throws -> UpdateRelease? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard data.count <= maximumResponseBytes, let payload = try? decoder.decode(Payload.self, from: data) else { throw UpdateError.invalidResponse }
        guard !payload.draft, !payload.prerelease else { return nil }
        guard let version = ReleaseVersion(payload.tagName), version.description == payload.tagName else { throw UpdateError.invalidResponse }
        guard let notes = URL(string: payload.htmlUrl), isReleasePage(notes) else { throw UpdateError.unsafeURL }
        func asset(_ name: String, limit: Int) throws -> UpdateRelease.Asset {
            guard let found = payload.assets.first(where: { $0.name == name }), found.state == "uploaded" else { throw UpdateError.invalidResponse }
            guard let url = URL(string: found.browserDownloadUrl), url == assetURL(name, tag: payload.tagName) else { throw UpdateError.unsafeURL }
            guard found.size > 0 else { throw UpdateError.invalidResponse }
            guard found.size <= limit else { throw UpdateError.tooLarge }
            return .init(url: url, size: found.size)
        }
        return UpdateRelease(version: version, notesURL: notes, image: try asset(imageName, limit: maximumImageBytes),
                             checksum: try asset(checksumName, limit: maximumChecksumBytes))
    }

    private static func assetURL(_ name: String, tag: String) -> URL {
        URL(string: "https://github.com/\(repository)/releases/download/\(tag)/\(name)")!
    }

    private static func isReleasePage(_ url: URL) -> Bool {
        isSafeHTTPS(url) && url.host == "github.com" && url.path.hasPrefix("/\(repository)/releases/")
    }

    private static func isSafeHTTPS(_ url: URL) -> Bool {
        url.scheme == "https" && url.user == nil && url.password == nil && (url.port == nil || url.port == 443)
    }

    /// Every hop of a download, the redirects included. On github.com only this repository's release assets qualify.
    public static func isAllowedDownload(_ url: URL) -> Bool {
        guard isSafeHTTPS(url), let host = url.host?.lowercased(), downloadHosts.contains(host) else { return false }
        return host != "github.com" || url.path.hasPrefix("/\(repository)/releases/download/")
    }

    /// The line `shasum -a 256 file` writes: the digest, two separators, the file name. Nothing else is accepted.
    public static func parseChecksum(_ text: String, assetName: String) throws -> String {
        var line = text
        if line.hasSuffix("\n") { line.removeLast() }
        let digest = line.prefix(64)
        guard digest.count == 64, digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              line.dropFirst(64) == "  " + assetName || line.dropFirst(64) == " *" + assetName else { throw UpdateError.checksumUnreadable }
        return String(digest)
    }

    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func verifyChecksum(of file: URL, expected: String) throws {
        guard (try? sha256(of: file)) == expected else { throw UpdateError.checksumMismatch }
    }

    /// Reads what `hdiutil attach -plist` reports; the image has one mounted volume.
    public static func mountPoint(fromAttachOutput data: Data) -> String? {
        let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        let entities = plist?["system-entities"] as? [[String: Any]] ?? []
        return entities.lazy.compactMap { $0["mount-point"] as? String }.first
    }

    /// The bundle must say it is Tokloom, and exactly the version the release promised.
    public static func verifyBundle(at app: URL, version: ReleaseVersion) throws {
        let info = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: info),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["CFBundleIdentifier"] as? String == bundleIdentifier, plist["CFBundleExecutable"] as? String == executableName else {
            throw UpdateError.wrongBundleIdentifier
        }
        guard plist["CFBundleShortVersionString"] as? String == version.description else { throw UpdateError.wrongVersion }
        guard FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/\(executableName)").path) else { throw UpdateError.appMissing }
    }
}

/// When the app asks GitHub on its own. Unauthenticated calls share 60 an hour per address, and a 304 spends one too,
/// so an ETag saves the body but not the call: only the last check's time keeps repeated launches from adding up.
public enum UpdateSchedule {
    public enum Trigger: Sendable { case launch, periodic }
    public static let interval: TimeInterval = 6 * 3600
    public static let launchFloor: TimeInterval = 300
    /// How soon a failed check tries again; it stays quiet, so it may as well wait for the network to return.
    public static let retry: TimeInterval = 1800

    public static func isDue(_ trigger: Trigger, last: Date?, now: Date) -> Bool {
        guard let last else { return true }
        let elapsed = now.timeIntervalSince(last)
        // A last check in the future means the clock moved; it says nothing about how long ago that was.
        return elapsed < 0 || elapsed >= (trigger == .launch ? launchFloor : interval)
    }

    /// Seconds until the next periodic check, measured from the last one that got an answer.
    public static func delay(last: Date?, now: Date, failed: Bool) -> TimeInterval {
        if failed { return retry }
        guard let last else { return interval }
        return max(0, min(interval, interval - now.timeIntervalSince(last)))
    }
}

public enum UpdatePhase: Equatable, Sendable {
    case idle, checking, upToDate, available
    /// Fraction done, once the size is known.
    case downloading(Double)
    case verifying, restarting
    case failed(UpdateError)

    public var isInstalling: Bool {
        switch self {
        case .downloading, .verifying, .restarting: true
        default: false
        }
    }
}

/// What the screens and the socket show about updates.
public struct UpdateStatus: Equatable, Sendable {
    public var phase = UpdatePhase.idle
    public var currentVersion: String?
    public var release: UpdateRelease?
    public var autoCheck = true
    public var lastCheck: Date?
    public var block: UpdateInstallBlock?

    public init() {}

    /// A release newer than this copy. An unreadable current version is never offered one.
    public var offered: UpdateRelease? {
        guard let release, let current = currentVersion.flatMap(ReleaseVersion.init), release.version > current else { return nil }
        return release
    }
    public var canInstall: Bool { offered != nil && block == nil && !phase.isInstalling && phase != .checking }
}
