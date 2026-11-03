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
    private let notifier = Notifier()
    private(set) lazy var vpn = VPNController(settings: settings, notifier: notifier)
    private var statusItem: StatusItemController?
    private lazy var settingsWindow = SettingsWindowController(settings: settings, vpn: vpn)
    private let signInWindow = SignInWindowController()
    private var updater: Updater?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let updater = Updater()
        self.updater = updater
        statusItem = StatusItemController(vpn: vpn, settings: settings,
                                          showSettings: { [weak self] in self?.settingsWindow.show() },
                                          showRouting: { [weak self] in
                                              guard let self else { return }
                                              let id = self.vpn.activeProfileID ?? self.settings.selectedProfile?.id
                                              self.settingsWindow.show(routingFor: id)
                                          },
                                          checkForUpdates: { updater.checkForUpdates() })
        notifier.isEnabled = { [settings] in settings.showNotifications }
        notifier.onOpenSignIn = { [weak self] id in
            guard let self, let profile = self.settings.profile(id: id) else { return }
            self.showSignIn(profile, message: nil)
        }
        notifier.onOpenApprovalSettings = { [weak self] in self?.vpn.openExtensionSettings() }
        if settings.showNotifications { notifier.requestPermission() }
        vpn.onNeedsSetup = { [weak self] in self?.settingsWindow.show() }
        vpn.onNeedsSignIn = { [weak self] profile, message in self?.showSignIn(profile, message: message) }
        vpn.onServerQuestion = { [weak self] profile, challenge in
            guard let self else { return }
            guard let challenge else {
                self.signInWindow.closeChallenge()
                return
            }
            self.signInWindow.show(challenge, for: profile,
                                   onAnswer: { [weak self] in self?.vpn.answer(challenge, with: $0) },
                                   onCancel: { [weak self] in self?.vpn.disconnect() })
        }
        Task { await vpn.start() }
        if settings.selectedProfile?.isUsable != true { settingsWindow.show() }

        // A menu-bar app, but while Settings or the sign-in window is open it joins ⌘-Tab and the Dock.
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // After willClose the window is still visible; look again on the next turn.
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.updateActivationPolicy() } }
            }
        }
        // Settings may already be open from above, before these observers existed.
        DispatchQueue.main.async { MainActor.assumeIsolated { self.updateActivationPolicy() } }
    }

    private func updateActivationPolicy() {
        let hasWindow = NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) }
        let policy: NSApplication.ActivationPolicy = hasWindow ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if hasWindow { NSApp.activate() }
    }

    private func showSignIn(_ profile: VPNProfile, message: String?) {
        signInWindow.show(for: profile, message: message) { [weak self] entry in
            self?.vpn.signIn(profile, entry)
        }
    }

    /// Like Tunnelblick, quitting takes the tunnel down.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard vpn.isActive else { return .terminateNow }
        vpn.disconnect { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
