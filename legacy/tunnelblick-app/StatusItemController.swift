import AppKit
import BurrowKit
import Observation

/// The menu-bar icon. A click connects or disconnects; a right-click (or Control/Option-click) opens the menu.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let vpn: VPNController
    private let settings: AppSettings
    private let showSettings: () -> Void
    private var blinkTimer: Timer?
    private var blinkPhase = false

    init(vpn: VPNController, settings: AppSettings, showSettings: @escaping () -> Void) {
        self.vpn = vpn
        self.settings = settings
        self.showSettings = showSettings
        super.init()
        item.button?.target = self
        item.button?.action = #selector(buttonClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        observe()
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
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Burrow VPN")
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
        if wantsMenu { showMenu() } else { vpn.toggle() }
    }

    private func showMenu() {
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
        let name = vpn.activeConfiguration?.displayName ?? settings.selectedConfiguration?.displayName

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
        if vpn.tunnelblickIsRunning {
            menu.addItem(action("Quit Tunnelblick (it can conflict with Burrow)", #selector(quitTunnelblick)))
        }

        menu.addItem(.separator())
        let toggleTitle = switch vpn.status {
        case .connected: "Disconnect"
        case .connecting: "Cancel"
        case .disconnecting: "Disconnecting…"
        case .disconnected, .failed: name.map { "Connect to \($0)" } ?? "Connect"
        }
        let toggle = action(toggleTitle, #selector(toggleConnection))
        if case .disconnecting = vpn.status { toggle.isEnabled = false }
        menu.addItem(toggle)
        if let otp = vpn.currentCode() {
            menu.addItem(action("Copy OTP Code  \(Self.grouped(otp.code))  (\(otp.secondsLeft) s)", #selector(copyCode)))
        }

        menu.addItem(.separator())
        menu.addItem(action("Settings…", #selector(openSettings), key: ","))
        let log = action("Show OpenVPN Log", #selector(showLog))
        log.isEnabled = vpn.logURL != nil
        menu.addItem(log)
        menu.addItem(.separator())
        menu.addItem(action("Quit Burrow", #selector(quit), key: "q"))
        return menu
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
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func copyCode() {
        guard let otp = vpn.currentCode() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(otp.code, forType: .string)
    }

    @objc private func showLog() {
        guard let url = vpn.logURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func quitTunnelblick() {
        NSRunningApplication.runningApplications(withBundleIdentifier: Tunnelblick.bundleIdentifier)
            .forEach { $0.terminate() }
    }

    // MARK: - Formatting

    static func grouped(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return code.prefix(3) + " " + code.suffix(3)
    }

    static func duration(since: Date) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        let elapsed = max(60, Date.now.timeIntervalSince(since))
        return formatter.string(from: elapsed) ?? ""
    }

    static func bytes(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .file)
    }
}
