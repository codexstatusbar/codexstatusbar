import AppKit

@main enum CodexHubMain {
    @MainActor static func main() {
        if let status = ControlCommandLine.run(Array(CommandLine.arguments.dropFirst())) { exit(status) }
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
