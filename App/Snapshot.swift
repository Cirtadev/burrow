import AppKit
import BurrowKit
import SwiftUI

/// `Burrow --snapshot <dir>` renders Settings and the sign-in window with sample data (no real secrets).
/// It draws a real NSHostingView: ImageRenderer cannot draw AppKit-backed controls such as text fields.
@MainActor
enum Snapshot {
    static func render(into directory: String) {
        _ = NSApplication.shared
        let ovpn = "client\ndev tun\nproto tcp\nremote vpn.example.com 443\nauth-user-pass\n<key>\n…\n</key>\n"
        let office = VPNProfile(name: "office", ovpn: ovpn, username: "alice", password: "example-password",
                                otpSecret: "JBSWY3DPEHPK3PXP")
        let lab = VPNProfile(name: "lab", ovpn: ovpn.replacingOccurrences(of: "vpn.example.com", with: "lab.example.com"),
                             username: "alice", savePassword: false, otpMode: .prompt)
        let draft = SettingsDraft(profiles: [lab, office], selection: office.id, general: GeneralSettings())

        render(SettingsView(draft: draft, tunnelblickSources: []), to: directory, name: "settings")
        render(SignInView(profile: lab, message: nil), to: directory, name: "sign-in")
        let question = TunnelChallenge(id: 1, kind: .dynamic, text: "Enter the code we sent to your phone by SMS.",
                                       echo: true, responseRequired: true)
        render(SignInView(profile: lab, message: nil, challenge: question), to: directory, name: "sign-in-challenge")
        render(AboutView().frame(width: 696, height: 520), to: directory, name: "about")
        var routed = office
        routed.alwaysViaVPN = "192.168.1.20, 192.168.1.40"
        let serverRoutes = ["192.168.1.0/24", "192.168.40.0/24", "192.168.30.0/24"].compactMap(IPv4Network.init)
        render(RoutingSheet(profile: .constant(routed), serverRoutes: serverRoutes, hosts: HostNames("192.168.1.20 server"),
                            onDone: {}), to: directory, name: "routing")

        let choices = [PanelState.Choice(id: lab.id, name: "lab", oneClick: false),
                       PanelState.Choice(id: office.id, name: "office", oneClick: true)]
        let base = PanelState(profileName: "office", badge: "1-click", choices: choices, selectedID: office.id,
                              code: ("482915", 17))
        var connected = base
        connected.status = .connected(since: Date().addingTimeInterval(-4_380), address: "10.8.0.2")
        connected.bytesIn = 48_300_000
        connected.bytesOut = 6_100_000
        var connecting = base
        connecting.status = .connecting("Signing in…")
        var webAuth = base
        webAuth.status = .connecting("Finish signing in in your browser…")
        webAuth.webAuthPending = true
        render(PanelView(state: webAuth, actions: PanelActions()), to: directory, name: "panel-web-sign-in")
        var approval = base
        approval.status = .connecting("Allow Burrow's VPN: in System Settings › Login Items & Extensions, click ⓘ next to Burrow and switch it on.")
        approval.needsApproval = true
        render(PanelView(state: approval, actions: PanelActions()), to: directory, name: "panel-approval")
        var failed = base
        failed.status = .failed("The server rejected the password and code twice. Check them in Settings.")
        for (name, state) in [("panel-off", base), ("panel-connecting", connecting),
                              ("panel-connected", connected), ("panel-failed", failed)] {
            render(PanelView(state: state, actions: PanelActions()), to: directory, name: name)
        }
        renderNotched(PanelView(state: connected, actions: PanelActions()), to: directory)
    }

    /// The panel as it hangs from the menu bar: body plus arrow, outline and a strip of fake menu bar above.
    private static func renderNotched(_ view: some View, to directory: String) {
        for dark in [false, true] {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            let hosting = NSHostingView(rootView: view.fixedSize().background(Color(nsColor: .windowBackgroundColor)))
            hosting.appearance = appearance
            let body = hosting.fittingSize
            hosting.frame = NSRect(origin: .zero, size: body)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = appearance
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            guard let content = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { continue }
            hosting.cacheDisplay(in: hosting.bounds, to: content)

            let menuBar: CGFloat = 30, margin: CGFloat = 24
            let panelSize = NSSize(width: body.width, height: body.height + MenuBarPanel.arrowHeight)
            let canvas = NSSize(width: panelSize.width + 2 * margin, height: panelSize.height + menuBar + margin + 1)
            let arrowX = panelSize.width - 70
            let image = NSImage(size: canvas, flipped: false) { _ in
                appearance.performAsCurrentDrawingAppearance {
                    NSColor.windowBackgroundColor.blended(withFraction: 0.3, of: dark ? .black : .gray)!.setFill()
                    NSRect(origin: .zero, size: canvas).fill()
                    NSColor(white: dark ? 0.12 : 0.92, alpha: 1).setFill()
                    NSRect(x: 0, y: canvas.height - menuBar, width: canvas.width, height: menuBar).fill()
                    let icon = NSImage(systemSymbolName: "lock.shield.fill", accessibilityDescription: nil)!
                        .withSymbolConfiguration(.init(pointSize: 17, weight: .semibold))!
                    let tinted = NSImage(size: icon.size, flipped: false) { rect in
                        icon.draw(in: rect)
                        (dark ? NSColor.white : NSColor.black).set()
                        rect.fill(using: .sourceAtop)
                        return true
                    }
                    tinted.draw(at: NSPoint(x: margin + arrowX - icon.size.width / 2, y: canvas.height - menuBar / 2 - icon.size.height / 2),
                                from: .zero, operation: .sourceOver, fraction: 1)

                    let origin = NSPoint(x: margin, y: canvas.height - menuBar - 1 - panelSize.height)
                    let transform = AffineTransform(translationByX: origin.x, byY: origin.y)
                    let shape = MenuBarPanel.shape(in: NSRect(origin: .zero, size: panelSize), arrowX: arrowX)
                    shape.transform(using: transform)
                    NSGraphicsContext.saveGraphicsState()
                    let shadow = NSShadow()
                    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
                    shadow.shadowBlurRadius = 14
                    shadow.shadowOffset = NSSize(width: 0, height: -4)
                    shadow.set()
                    NSColor.windowBackgroundColor.setFill()
                    shape.fill()
                    NSGraphicsContext.restoreGraphicsState()
                    content.draw(in: NSRect(origin: origin, size: body))
                    (dark ? NSColor.white.withAlphaComponent(0.18) : NSColor.black.withAlphaComponent(0.12)).setStroke()
                    shape.lineWidth = 1
                    shape.stroke()
                }
                return true
            }
            guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
            let url = URL(fileURLWithPath: directory).appendingPathComponent("panel-menubar-\(dark ? "dark" : "light").png")
            try? png.write(to: url)
            print(url.path)
        }
    }

    private static func render(_ view: some View, to directory: String, name: String) {
        for dark in [false, true] {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let hosting = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
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
            let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
            try? png.write(to: url)
            print(url.path)
        }
    }
}
