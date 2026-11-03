import AppKit
import BurrowKit
import ServiceManagement
import SwiftUI

struct SettingsDraft: Equatable {
    var configurationID: String?
    var credentials = Credentials()
    var connectAtLaunch = true
    var keepConnected = true
    var launchAtLogin = false
}

struct SettingsView: View {
    @State var draft: SettingsDraft
    let configurations: [TunnelblickConfiguration]
    var tunnelblickIsRunning = false
    var importFromTunnelblick: (TunnelblickConfiguration) -> (username: String?, password: String?) = { _ in (nil, nil) }
    var onSave: (SettingsDraft) -> Void = { _ in }
    var onCancel: () -> Void = {}
    @State private var importNote: String?

    private var selected: TunnelblickConfiguration? {
        configurations.first { $0.id == draft.configurationID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    if configurations.isEmpty {
                        Text("No Tunnelblick configurations found. Install one in Tunnelblick first (as a shared configuration).")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Configuration", selection: $draft.configurationID) {
                            ForEach(configurations) { configuration in
                                Text(configuration.displayName).tag(Optional(configuration.id))
                            }
                        }
                    }
                    TextField("Username", text: $draft.credentials.username)
                        .textContentType(.username)
                    SecureField("Password", text: $draft.credentials.password)
                        .textContentType(.password)
                    HStack {
                        Spacer()
                        if let importNote {
                            Text(importNote).font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Import from Tunnelblick") { importCredentials() }
                            .disabled(selected == nil)
                    }
                } header: {
                    Text("Account")
                }

                Section {
                    SecureField("Secret", text: $draft.credentials.otpSecret, prompt: Text("Base32 secret or otpauth:// link"))
                    OTPPreview(secret: draft.credentials.otpSecret)
                } header: {
                    Text("One-time password")
                } footer: {
                    Text("Burrow appends the current code to your password, as Tunnelblick's “security token” field did. Check that the code matches your authenticator app.")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Section {
                    Toggle("Connect when Burrow starts", isOn: $draft.connectAtLaunch)
                    Toggle("Start Burrow at login", isOn: $draft.launchAtLogin)
                    Toggle("Reconnect after drops and sleep", isOn: $draft.keepConnected)
                } header: {
                    Text("Behaviour")
                }

                if tunnelblickIsRunning {
                    Section {
                        Label("Tunnelblick is running. Quit it (and turn off its “Launch at login”) so the two apps don't fight over the same configuration.",
                              systemImage: "exclamationmark.triangle")
                            .font(.callout)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(draft) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
            .padding(.top, 4)
        }
        .frame(width: 460)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: draft.configurationID) { importNote = nil }
    }

    private func importCredentials() {
        guard let selected else { return }
        let found = importFromTunnelblick(selected)
        if let username = found.username { draft.credentials.username = username }
        if let password = found.password { draft.credentials.password = password }
        importNote = switch (found.username != nil, found.password != nil) {
        case (true, true): "Imported username and password."
        case (true, false): "Imported username; no saved password."
        case (false, true): "Imported password; no saved username."
        case (false, false): "Nothing saved in Tunnelblick."
        }
    }
}

private struct OTPPreview: View {
    let secret: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            LabeledContent("Current code") {
                if secret.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("—").foregroundStyle(.secondary)
                } else {
                    switch Result(catching: { try TOTP(parsing: secret) }) {
                    case .success(let totp):
                        HStack(spacing: 8) {
                            Text(StatusItemController.grouped(totp.code(at: context.date)))
                                .font(.system(.body, design: .monospaced).weight(.semibold))
                                .textSelection(.enabled)
                            Text("\(totp.secondsRemaining(at: context.date)) s")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    case .failure(let error):
                        Text(error.localizedDescription).foregroundStyle(.red)
                    }
                }
            }
        }
    }
}

/// Hosts SettingsView in a regular window; Burrow itself has no Dock icon.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let settings: AppSettings
    private let vpn: VPNController

    init(settings: AppSettings, vpn: VPNController) {
        self.settings = settings
        self.vpn = vpn
    }

    func show() {
        if let window {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }
        let configurations = settings.configurations
        let selected = settings.selectedConfiguration ?? configurations.first
        var draft = SettingsDraft(
            configurationID: selected?.id,
            connectAtLaunch: settings.connectAtLaunch,
            keepConnected: settings.keepConnected,
            launchAtLogin: SMAppService.mainApp.status == .enabled)
        if let selected, let credentials = settings.credentials(for: selected) { draft.credentials = credentials }

        let view = SettingsView(
            draft: draft,
            configurations: configurations,
            tunnelblickIsRunning: vpn.tunnelblickIsRunning,
            importFromTunnelblick: { [settings] in settings.tunnelblickCredentials(for: $0) },
            onSave: { [weak self] in self?.save($0) },
            onCancel: { [weak self] in self?.window?.close() })
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Burrow Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func save(_ draft: SettingsDraft) {
        settings.selectedConfigurationID = draft.configurationID
        settings.connectAtLaunch = draft.connectAtLaunch
        settings.keepConnected = draft.keepConnected
        if let configuration = settings.configurations.first(where: { $0.id == draft.configurationID }),
           settings.credentials(for: configuration) != draft.credentials {
            settings.save(draft.credentials, for: configuration)
            vpn.credentialsChanged()
        }
        do {
            switch (draft.launchAtLogin, SMAppService.mainApp.status == .enabled) {
            case (true, false): try SMAppService.mainApp.register()
            case (false, true): try SMAppService.mainApp.unregister()
            default: break
            }
        } catch {
            NSLog("Burrow: login item change failed: \(error)")
        }
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
