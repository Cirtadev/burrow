import AppKit
import BurrowKit
import SwiftUI

/// What the panel shows; built from the live controller, or from sample data for snapshots.
struct PanelState {
    struct Choice: Identifiable {
        let id: UUID
        let name: String
        let oneClick: Bool
    }

    var profileName: String?
    /// How connecting goes: "1-click", "asks for code", "certificate"…
    var badge: String?
    /// Connecting opens the sign-in window first.
    var asksFirst = false
    var choices: [Choice] = []
    var selectedID: UUID?
    var status: VPNController.Status = .disconnected
    var bytesIn: Int64 = 0
    var bytesOut: Int64 = 0
    var code: (code: String, secondsLeft: Int)?
    var tunnelblickRunning = false
    /// macOS waits for the user to allow the tunnel extension.
    var needsApproval = false
    /// The local network uses one of the VPN's address ranges.
    var networkClash: String?
    /// Burrow splits a range the local network shares with the VPN.
    var networkSplit: String?
    /// The server waits for the user to sign in on a web page.
    var webAuthPending = false
}

struct PanelActions {
    var toggle: () -> Void = {}
    var select: (UUID) -> Void = { _ in }
    var openSettings: () -> Void = {}
    var showLog: () -> Void = {}
    var checkForUpdates: () -> Void = {}
    var copyCode: () -> Void = {}
    var quitTunnelblick: () -> Void = {}
    var openApprovalSettings: () -> Void = {}
    var openRouting: () -> Void = {}
    var openWebAuth: () -> Void = {}
    var quit: () -> Void = {}
}

/// The popover under the menu-bar shield: one big button, then the less frequent things.
struct PanelView: View {
    let state: PanelState
    let actions: PanelActions
    var now = Date()

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)

            bigButton
                .padding(.top, 18)

            statusText
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 16)

            Divider()

            VStack(spacing: 2) {
                if let code = state.code {
                    codeRow(code)
                }
                if state.tunnelblickRunning {
                    PanelRow(icon: "exclamationmark.triangle", title: "Quit Tunnelblick", detail: "it conflicts with Burrow",
                             action: actions.quitTunnelblick)
                }
                PanelRow(icon: "gearshape", title: "Settings…", action: actions.openSettings)
                PanelRow(icon: "doc.text.magnifyingglass", title: "Show Log", action: actions.showLog)
                PanelRow(icon: "arrow.down.circle", title: "Check for Updates…", action: actions.checkForUpdates)
                PanelRow(icon: "xmark.circle", title: "Quit Burrow", action: actions.quit)
            }
            .padding(6)
        }
        .frame(width: 300)
    }

    // MARK: - Header

    @ViewBuilder private var header: some View {
        HStack {
            if state.choices.count > 1 {
                Menu {
                    ForEach(state.choices) { choice in
                        Button {
                            actions.select(choice.id)
                        } label: {
                            if choice.id == state.selectedID {
                                Label(choice.name, systemImage: "checkmark")
                            } else {
                                Text(choice.name)
                            }
                        }
                    }
                } label: {
                    Text(state.profileName ?? "Choose a configuration").font(.headline)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            } else {
                Text(state.profileName ?? "Burrow").font(.headline)
            }
            Spacer()
            if state.profileName != nil, let badge = state.badge {
                Text(badge)
                    .font(.caption)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Big button

    private var isConnecting: Bool {
        switch state.status {
        case .connecting, .disconnecting: true
        default: false
        }
    }

    private var tint: Color {
        switch state.status {
        case .connected: Color(red: 0.16, green: 0.70, blue: 0.40)
        case .connecting, .disconnecting: Color.accentColor
        case .failed: Color.orange
        case .disconnected: Color(nsColor: .systemGray)
        }
    }

    private var bigButton: some View {
        Button(action: state.profileName == nil ? actions.openSettings : actions.toggle) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.7)], startPoint: .top, endPoint: .bottom))
                Circle()
                    .strokeBorder(.white.opacity(0.25), lineWidth: 1)
                Image(systemName: state.profileName == nil ? "plus" : "power")
                    .font(.system(size: 54, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, isActive: isConnecting)
            }
            .frame(width: 128, height: 128)
            .shadow(color: tint.opacity(stateIsConnected ? 0.5 : 0.2), radius: stateIsConnected ? 18 : 6, y: 3)
            .contentShape(Circle())
        }
        .buttonStyle(BigButtonStyle())
        .disabled({ if case .disconnecting = state.status { return true } else { return false } }())
        .help(buttonHelp)
        .animation(.easeInOut(duration: 0.25), value: tintKey)
    }

    private var stateIsConnected: Bool {
        if case .connected = state.status { return true }
        return false
    }

    private var tintKey: Int {
        switch state.status {
        case .disconnected: 0
        case .connecting: 1
        case .connected: 2
        case .disconnecting: 3
        case .failed: 4
        }
    }

    private var buttonHelp: String {
        guard state.profileName != nil else { return "Add a configuration" }
        switch state.status {
        case .connected: return "Disconnect"
        case .connecting: return "Cancel"
        case .disconnecting: return "Disconnecting"
        case .disconnected, .failed: return state.asksFirst ? "Connect (asks before connecting)" : "Connect"
        }
    }

    // MARK: - Status text

    @ViewBuilder private var statusText: some View {
        VStack(spacing: 4) {
            switch state.status {
            case .disconnected:
                Text(state.profileName == nil ? "No configuration yet" : "Not connected").font(.title3.weight(.semibold))
                Text(state.profileName == nil ? "Click to add one in Settings." : "Click to connect.")
                    .foregroundStyle(.secondary)
            case .connecting(let detail):
                Text("Connecting").font(.title3.weight(.semibold))
                Text(detail).foregroundStyle(.secondary)
            case .disconnecting:
                Text("Disconnecting").font(.title3.weight(.semibold))
            case .connected(let since, let address):
                Text("Connected").font(.title3.weight(.semibold))
                Text([address, StatusItemController.duration(since: since, now: now)].filter { !$0.isEmpty }
                    .joined(separator: "  ·  "))
                    .foregroundStyle(.secondary)
                Text("↓ \(StatusItemController.bytes(state.bytesIn))   ↑ \(StatusItemController.bytes(state.bytesOut))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Text("Not connected").font(.title3.weight(.semibold))
                Text(message)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let clash = state.networkClash {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(clash).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .multilineTextAlignment(.leading)
                .padding(.top, 8)
                Button("Choose Routes…", action: actions.openRouting)
                    .controlSize(.small)
            } else if let split = state.networkSplit {
                Button(action: actions.openRouting) {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
                        Text(split).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                .help("Choose Routes…")
                .padding(.top, 8)
            }
            if state.webAuthPending {
                Button("Open Sign-in Page", action: actions.openWebAuth)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, 8)
                    .help("The server waits until you sign in on its page in your browser.")
            }
            if state.needsApproval {
                Button("Open System Settings", action: actions.openApprovalSettings)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, 8)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Rows

    private func codeRow(_ code: (code: String, secondsLeft: Int)) -> some View {
        Button(action: actions.copyCode) {
            HStack(spacing: 10) {
                Image(systemName: "key").frame(width: 18).foregroundStyle(.secondary)
                Text("OTP code").lineLimit(1)
                Spacer()
                Text(StatusItemController.grouped(code.code))
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                Text("\(code.secondsLeft) s")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .trailing)
                Image(systemName: "doc.on.doc").foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .help("Copy the current code")
    }
}

private struct PanelRow: View {
    let icon: String
    let title: String
    var detail: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 18).foregroundStyle(.secondary)
                Text(title)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
    }
}

/// Menu-like rows: highlight on hover.
private struct RowButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : hovering ? 0.08 : 0)))
            .onHover { hovering = $0 }
    }
}

private struct BigButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The popover content: rebuilds the state from the live objects every second (code countdown, uptime).
struct LivePanel: View {
    let vpn: VPNController
    let settings: AppSettings
    let actions: PanelActions

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            PanelView(state: state, actions: actions, now: context.date)
        }
    }

    private var state: PanelState {
        let selected = settings.selectedProfile
        let shown = vpn.isActive ? (vpn.activeProfile ?? selected) : selected
        return PanelState(
            profileName: shown.map { $0.name.isEmpty ? "Untitled" : $0.name },
            badge: shown?.modeBadge,
            asksFirst: shown?.asksBeforeConnecting ?? false,
            choices: settings.profiles.map { .init(id: $0.id, name: $0.name.isEmpty ? "Untitled" : $0.name, oneClick: $0.isOneClick) },
            selectedID: shown?.id,
            status: vpn.status,
            bytesIn: vpn.bytesReceived,
            bytesOut: vpn.bytesSent,
            code: vpn.currentCode(),
            tunnelblickRunning: vpn.tunnelblickIsRunning,
            needsApproval: vpn.needsExtensionApproval,
            networkClash: vpn.networkClash,
            networkSplit: vpn.networkSplit,
            webAuthPending: vpn.webAuthURL != nil)
    }
}

extension VPNProfile {
    /// The panel's and menu's short word on how connecting goes.
    var modeBadge: String {
        if effectiveOTPMode == .prompt { return "asks for code" }
        if needsPassword || needsPassphrase || needsCode { return "asks for password" }
        switch effectiveOTPMode {
        case .automatic: return "1-click"
        case .prompt: return "asks for code"
        case .off: return usesPassword ? "password" : "certificate"
        }
    }
}
