import Darwin
import Foundation

/// The steps of an install that touch the disk. Everything up to `handOver` leaves the current app alone.
public enum UpdateInstaller {
    public struct Staged: Sendable {
        /// Beside the app, so moving out of it is a rename and never a copy.
        public let work: URL
        public let app: URL
        public let target: URL
    }

    private static let workPrefix = ".Tokloom-update-"
    private static let toolSeconds: TimeInterval = 120

    /// Runs one tool with fixed arguments, without a shell, and stops only that child when it overruns.
    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) -> (status: Int32, output: Data) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        guard (try? process.run()) != nil else { return (-1, Data()) }
        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + toolSeconds, execute: timer)
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        finished.wait()
        timer.cancel()
        return (process.terminationStatus, output)
    }

    /// Copies the app out of a verified image to sit beside `target`, then checks that copy, because it is what will run.
    /// `ditto` carries extended attributes over, so a quarantined image stays quarantined. `scratch` holds the mount.
    public static func stage(image: URL, version: ReleaseVersion, target: URL, scratch: URL) throws -> Staged {
        let attached = run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountrandom", scratch.path, "-plist", image.path])
        guard attached.status == 0, let mount = UpdateRules.mountPoint(fromAttachOutput: attached.output) else { throw UpdateError.mountFailed }
        defer {
            if run("/usr/bin/hdiutil", ["detach", mount]).status != 0 { run("/usr/bin/hdiutil", ["detach", "-force", mount]) }
        }
        return try stage(app: URL(fileURLWithPath: mount).appendingPathComponent(UpdateRules.appName), version: version, target: target)
    }

    public static func stage(app source: URL, version: ReleaseVersion, target: URL) throws -> Staged {
        var info = stat()
        // A symlink named like the app would point the copy anywhere.
        guard lstat(source.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw UpdateError.appMissing }
        let folder = target.deletingLastPathComponent()
        removeLeftovers(in: folder)
        let work = folder.appendingPathComponent(workPrefix + UUID().uuidString, isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])) != nil else {
            throw UpdateError.stagingFailed
        }
        do {
            let app = work.appendingPathComponent("new.app", isDirectory: true)
            guard run("/usr/bin/ditto", [source.path, app.path]).status == 0 else { throw UpdateError.stagingFailed }
            try UpdateRules.verifyBundle(at: app, version: version)
            guard run("/usr/bin/codesign", ["--verify", "--strict", app.path]).status == 0 else { throw UpdateError.invalidSignature }
            return Staged(work: work, app: app, target: target)
        } catch {
            try? FileManager.default.removeItem(at: work)
            throw error
        }
    }

    /// What an interrupted install left. The app calling this runs from the folder, so these are not its only copy.
    private static func removeLeftovers(in folder: URL) {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix(workPrefix) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    public static func discard(_ staged: Staged) { try? FileManager.default.removeItem(at: staged.work) }

    /// Replaces the app once `pid` has exited. It lives here, not in a file of the bundle it replaces. Values reach it only
    /// as positional arguments, always quoted, so no path can become code. It never looks for any process but `pid`.
    /// Whenever the swap fails the old app goes back; only if that too fails does `work` stay, because it then holds the app.
    public static let helperScript = #"""
    pid=$1 new=$2 target=$3 work=$4 result=$5 opener=$6 ticks=$7
    trap '' HUP
    backup=$work/old.app
    report() { printf '%s\n' "$1" > "$result"; }
    case $work in */.Tokloom-update-*) ;; *) report refused; exit 64 ;; esac
    while kill -0 "$pid" 2>/dev/null; do
        ticks=$((ticks - 1))
        if [ "$ticks" -le 0 ]; then report still-running; /bin/rm -rf -- "$work"; exit 1; fi
        /bin/sleep 0.1
    done
    if ! /bin/mv -- "$target" "$backup"; then
        report backup-failed
        /bin/rm -rf -- "$work"
        "$opener" -n "$target"
        exit 1
    fi
    if /bin/mv -- "$new" "$target" && "$opener" -n "$target"; then
        /bin/rm -rf -- "$work"
        exit 0
    fi
    /bin/rm -rf -- "$target"
    if ! /bin/mv -- "$backup" "$target"; then report restore-failed; exit 2; fi
    report replace-failed
    /bin/rm -rf -- "$work"
    "$opener" -n "$target"
    exit 1
    """#

    public static let helperName = "tokloom-update"
    public static let openTool = "/usr/bin/open"

    public static func helperArguments(_ staged: Staged, pid: Int32, result: URL, opener: String = openTool, waitSeconds: Int = 30) -> [String] {
        ["-c", helperScript, helperName, String(pid), staged.app.path, staged.target.path, staged.work.path, result.path, opener, String(waitSeconds * 10)]
    }

    /// Starts the helper, which outlives this process. The caller quits next.
    public static func handOver(_ staged: Staged, pid: Int32, result: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = helperArguments(staged, pid: pid, result: result)
        process.environment = ["PATH": "/usr/bin:/bin"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { throw UpdateError.helperFailed }
    }

    /// Whether the previous launch's helper reported a failure; reading clears it.
    public static func takeHelperFailure(at result: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: result.path) else { return false }
        try? FileManager.default.removeItem(at: result)
        return true
    }
}
