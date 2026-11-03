import AppKit
import BurrowKit
import Observation
import SwiftUI

/// The menu-bar icon. A click opens the panel (big connect button, settings); a right-click
/// (or Control/Option-click) opens a compact menu.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let vpn: VPNController
    private let settings: AppSettings
    private let showSettings: () -> Void
    private let showRouting: () -> Void
    private let checkForUpdates: () -> Void
    private var panel: MenuBarPanel!
    private var blinkTimer: Timer?
    private var blinkPhase = false

    init(vpn: VPNController, settings: AppSettings, showSettings: @escaping () -> Void,
         showRouting: @escaping () -> Void, checkForUpdates: @escaping () -> Void) {
        self.vpn = vpn
        self.settings = settings
        self.showSettings = showSettings
        self.showRouting = showRouting
        self.checkForUpdates = checkForUpdates
        super.init()
        item.button?.target = self
        item.button?.action = #selector(buttonClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        let actions = PanelActions(
            toggle: { [weak self] in self?.vpn.toggle() },
            select: { [weak self] id in self?.vpn.connect(id) },
            openSettings: { [weak self] in
                self?.panel.close()
                self?.showSettings()
            },
            showLog: { [weak self] in
                self?.panel.close()
                self?.showLog()
            },
            checkForUpdates: { [weak self] in
                self?.panel.close()
                self?.checkForUpdates()
            },
            copyCode: { [weak self] in self?.copyCode() },
            quitTunnelblick: { [weak self] in self?.quitTunnelblick() },
            openApprovalSettings: { [weak self] in
                self?.panel.close()
                self?.vpn.openExtensionSettings()
            },
            openRouting: { [weak self] in
                self?.panel.close()
                self?.showRouting()
            },
            openWebAuth: { [weak self] in
                self?.panel.close()
                self?.vpn.openWebAuthPage()
            },
            quit: { NSApp.terminate(nil) })
        panel = MenuBarPanel(content: LivePanel(vpn: vpn, settings: settings, actions: actions))
        observe()
    }

    private func togglePanel() {
        guard let button = item.button else { return }
        panel.toggle(below: button)
    }

    // MARK: - Icon

    private func observe() {
        withObservationTracking {
            render(vpn.status)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func render(_ status: VPNController.Status) {
        switch status {
        case .connecting, .disconnecting:
            if blinkTimer == nil {
                blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.blinkPhase.toggle()
                        self.setSymbol(self.blinkPhase ? "shield.lefthalf.filled" : "shield")
                    }
                }
            }
            setSymbol("shield.lefthalf.filled")
        case .connected:
            stopBlinking()
            setSymbol("lock.shield.fill")
        case .disconnected:
            stopBlinking()
            setSymbol("shield")
        case .failed:
            stopBlinking()
            setSymbol("exclamationmark.shield")
        }
        item.button?.toolTip = "Burrow — \(Self.headline(for: status))"
    }

    private func stopBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = nil
    }

    private func setSymbol(_ name: String) {
        // Larger than the default menu-bar symbol size (about 13 pt) so the state reads at a glance.
        let size = NSImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Burrow VPN")?.withSymbolConfiguration(size)
        image?.isTemplate = true
        item.button?.image = image
    }

    static func headline(for status: VPNController.Status) -> String {
        switch status {
        case .disconnected: "Disconnected"
        case .connecting(let detail): detail
        case .connected: "Connected"
        case .disconnecting: "Disconnecting…"
        case .failed(let message): message
        }
    }

    // MARK: - Clicks and menu

    @objc private func buttonClicked() {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
            || event?.modifierFlags.contains(.option) == true
        if wantsMenu { showMenu() } else { togglePanel() }
    }

    private func showMenu() {
        panel.close()
        let menu = buildMenu()
        menu.delegate = self
        item.menu = menu
        item.button?.performClick(nil)
    }

    nonisolated func menuDidClose(_ menu: NSMenu) {
        MainActor.assumeIsolated { item.menu = nil }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let active = vpn.activeProfile
        let selected = settings.selectedProfile
        let shown = vpn.status == .disconnected ? selected : (active ?? selected)
        let name = shown.map { $0.name.isEmpty ? "Untitled" : $0.name }

        switch vpn.status {
        case .connected(let since, let address):
            menu.addItem(info("Connected\(name.map { " to \($0)" } ?? "")"))
            var details = [Self.duration(since: since)]
            if !address.isEmpty { details.insert(address, at: 0) }
            details.append("↓ \(Self.bytes(vpn.bytesReceived))  ↑ \(Self.bytes(vpn.bytesSent))")
            menu.addItem(info(details.joined(separator: "  ·  ")))
        case .failed(let message):
            menu.addItem(info("Not connected"))
            menu.addItem(info(message, secondary: true))
        default:
            menu.addItem(info(Self.headline(for: vpn.status)))
        }
        if vpn.needsExtensionApproval {
            menu.addItem(action("Open System Settings to Allow Burrow…", #selector(openApprovalSettings)))
        }
        if vpn.tunnelblickIsRunning {
            menu.addItem(action("Quit Tunnelblick (two VPN apps conflict)", #selector(quitTunnelblick)))
        }

        menu.addItem(.separator())
        let toggleTitle = switch vpn.status {
        case .connected: "Disconnect"
        case .connecting: "Cancel"
        case .disconnecting: "Disconnecting…"
        case .disconnected, .failed:
            name.map { "Connect to \($0)\(selected?.asksBeforeConnecting == true ? "…" : "")" } ?? "Add a Configuration…"
        }
        let toggle = action(toggleTitle, settings.profiles.isEmpty ? #selector(openSettings) : #selector(toggleConnection))
        if case .disconnecting = vpn.status { toggle.isEnabled = false }
        menu.addItem(toggle)
        if let otp = vpn.currentCode() {
            menu.addItem(action("Copy OTP Code  \(Self.grouped(otp.code))  (\(otp.secondsLeft) s)", #selector(copyCode)))
        }

        if settings.profiles.count > 1 {
            menu.addItem(.separator())
            menu.addItem(info("Configurations"))
            for profile in settings.profiles {
                let item = action(profile.name.isEmpty ? "Untitled" : profile.name, #selector(chooseProfile(_:)))
                item.representedObject = profile.id
                item.state = profile.id == (vpn.isActive ? active?.id : selected?.id) ? .on : .off
                item.toolTip = profile.modeBadge
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        menu.addItem(action("About Burrow", #selector(showAbout)))
        menu.addItem(action("Check for Updates…", #selector(checkForUpdatesClicked)))
        menu.addItem(action("Settings…", #selector(openSettings), key: ","))
        menu.addItem(action("Show Log", #selector(showLog)))
        menu.addItem(.separator())
        menu.addItem(action("Quit Burrow", #selector(quit), key: "q"))
        return menu
    }

    /// Picking a configuration selects it and connects it (switching from the running one).
    @objc private func chooseProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        vpn.connect(id)
    }

    private func info(_ title: String, secondary: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        if secondary {
            item.attributedTitle = NSAttributedString(string: Self.wrap(title, width: 46), attributes: [
                .font: NSFont.menuFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor,
            ])
        }
        return item
    }

    static func wrap(_ text: String, width: Int) -> String {
        var lines: [String] = []
        var line = ""
        for word in text.split(separator: " ") {
            if !line.isEmpty, line.count + word.count + 1 > width {
                lines.append(line)
                line = ""
            }
            line += line.isEmpty ? String(word) : " " + word
        }
        if !line.isEmpty { lines.append(line) }
        return lines.joined(separator: "\n")
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func toggleConnection() { vpn.toggle() }
    @objc private func openSettings() { showSettings() }
    @objc private func openApprovalSettings() { vpn.openExtensionSettings() }
    @objc private func checkForUpdatesClicked() { checkForUpdates() }

    /// The standard About panel: name, version and copyright come from Info.plist (Cirtadev GmbH).
    @objc private func showAbout() {
        let credits = NSMutableAttributedString()
        for site in AboutView.websites {
            credits.append(NSAttributedString(string: (site.host() ?? site.absoluteString) + "\n", attributes: [
                .link: site, .font: NSFont.systemFont(ofSize: 11),
            ]))
        }
        credits.append(NSAttributedString(string: "\n"))
        let licences = AboutView.credits.map { "\($0.name) — \($0.license)" }.joined(separator: "\n")
        credits.append(NSAttributedString(string: "Built with:\n\(licences)", attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func copyCode() {
        guard let otp = vpn.currentCode() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(otp.code, forType: .string)
    }

    /// The running extension's recent OpenVPN lines, or the system log of earlier sessions.
    @objc private func showLog() {
        Task {
            var text = await vpn.fetchLog()
            if text == nil { text = await Self.systemLog() }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Burrow.log")
            try? (text ?? "No log yet.").write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.open(url)
        }
    }

    private static func systemLog() async -> String? {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
            process.arguments = ["show", "--last", "2h", "--info", "--style", "compact",
                                 "--predicate", "subsystem == \"dev.cirta.burrow.tunnel\""]
            let pipe = Pipe()
            process.standardOutput = pipe
            guard (try? process.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }.value
    }

    @objc private func quitTunnelblick() {
        NSRunningApplication.runningApplications(withBundleIdentifier: "net.tunnelblick.tunnelblick")
            .forEach { $0.terminate() }
    }

    // MARK: - Formatting

    static func grouped(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return code.prefix(3) + " " + code.suffix(3)
    }

    static func duration(since: Date, now: Date = .now) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        let elapsed = max(60, now.timeIntervalSince(since))
        return formatter.string(from: elapsed) ?? ""
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
