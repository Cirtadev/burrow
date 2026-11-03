import AppKit
import BurrowKit

@main
@MainActor
enum BurrowMain {
    static func main() {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--snapshot") {
            let directory = arguments.indices.contains(index + 1)
                ? arguments[index + 1] : FileManager.default.currentDirectoryPath
            Snapshot.render(into: directory)
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = AppSettings()
    private(set) lazy var vpn = VPNController(settings: settings)
    private var statusItem: StatusItemController?
    private lazy var settingsWindow = SettingsWindowController(settings: settings, vpn: vpn)

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = StatusItemController(vpn: vpn, settings: settings) { [weak self] in self?.settingsWindow.show() }
        vpn.onNeedsSetup = { [weak self] in self?.settingsWindow.show() }
        vpn.start()
        if !settings.isReady { settingsWindow.show() }
    }

    /// Like Tunnelblick, quitting takes the tunnel down (and waits for the down script to restore DNS).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard vpn.hasSession else { return .terminateNow }
        vpn.disconnect { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
