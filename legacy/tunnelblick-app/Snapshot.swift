import AppKit
import BurrowKit
import SwiftUI

/// `Burrow --snapshot <dir>` renders the Settings window with sample data (no real secrets) for the README.
/// It draws a real NSHostingView: ImageRenderer cannot draw AppKit-backed controls such as text fields.
@MainActor
enum Snapshot {
    static func render(into directory: String) {
        _ = NSApplication.shared
        let sample = TunnelblickConfiguration(
            displayName: "office", location: .shared, tblkPath: "/Library/Application Support/Tunnelblick/Shared/office.tblk")
        let draft = SettingsDraft(
            configurationID: sample.id,
            credentials: Credentials(username: "alice", password: "example-password", otpSecret: "JBSWY3DPEHPK3PXP"),
            connectAtLaunch: true, keepConnected: true, launchAtLogin: true)

        for dark in [false, true] {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let hosting = NSHostingView(rootView: SettingsView(draft: draft, configurations: [sample], tunnelblickIsRunning: true))
            hosting.appearance = appearance
            hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = appearance
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))

            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { continue }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { continue }
            let url = URL(fileURLWithPath: directory).appendingPathComponent("settings-\(dark ? "dark" : "light").png")
            try? png.write(to: url)
            print(url.path)
        }
    }
}
