import AppKit
import BurrowKit
import CoreImage
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct GeneralSettings: Equatable {
    var connectAtLaunch = true
    var launchAtLogin = false
    var keepConnected = true
    var useVPNDNS = false
    var showNotifications = true
}

/// Lets the panel open Settings at a configuration's routing table.
@MainActor
@Observable
final class SettingsNavigation {
    var routingProfile: UUID?
}

/// Everything the Settings window edits; nothing is stored until Save.
struct SettingsDraft: Equatable {
    var profiles: [VPNProfile] = []
    var selection: UUID?
    var general = GeneralSettings()
}

struct SettingsView: View {
    @State var draft: SettingsDraft
    var tunnelblickSources: [TunnelblickImport.Source] = []
    var tunnelblickIsRunning = false
    var importFromTunnelblick: ([TunnelblickImport.Source]) throws -> [VPNProfile] = { _ in [] }
    /// The VPN server's routes from a configuration's last session.
    var knownRoutes: (UUID) -> [IPv4Network] = { _ in [] }
    /// The devices the running tunnel found on the local network, for that configuration.
    var localDevices: (UUID) -> [LocalDevices] = { _ in [] }
    var navigation = SettingsNavigation()
    var onSave: (SettingsDraft) -> Void = { _ in }
    var onCancel: () -> Void = {}
    /// False for screenshots: off-screen captures leave the tab bar's glass blank.
    var showsTabs = true
    @State private var tab = "configurations"
    @State private var note: String?
    /// The configuration whose routing table is open.
    @State private var routingFor: UUID?

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if showsTabs {
                    TabView(selection: $tab) {
                        configurations
                            .tabItem { Label("Configurations", systemImage: "network.badge.shield.half.filled") }
                            .tag("configurations")
                        general
                            .tabItem { Label("General", systemImage: "gearshape") }
                            .tag("general")
                        AboutView()
                            .tabItem { Label("About", systemImage: "info.circle") }
                            .tag("about")
                    }
                } else {
                    configurations
                }
            }
            .padding([.horizontal, .top], 12)

            HStack {
                if let note {
                    Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(draft) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(minWidth: 720, idealWidth: 760, maxWidth: .infinity, minHeight: 560, idealHeight: 640, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: Binding(get: { routingFor != nil }, set: { if !$0 { routingFor = nil } })) {
            if let id = routingFor, let index = draft.profiles.firstIndex(where: { $0.id == id }) {
                RoutingSheet(profile: $draft.profiles[index], serverRoutes: knownRoutes(id), localDevices: localDevices(id),
                             onDone: { routingFor = nil })
            }
        }
        .onAppear(perform: followNavigation)
        .onChange(of: navigation.routingProfile) { followNavigation() }
    }

    private func followNavigation() {
        guard let id = navigation.routingProfile else { return }
        navigation.routingProfile = nil
        guard draft.profiles.contains(where: { $0.id == id }) else { return }
        tab = "configurations"
        draft.selection = id
        routingFor = id
    }

    // MARK: - Configurations tab

    private var configurations: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $draft.selection) {
                    ForEach(draft.profiles) { profile in
                        HStack {
                            Image(systemName: profile.isOneClick ? "bolt.shield" : "key")
                                .foregroundStyle(.secondary)
                            Text(profile.name.isEmpty ? "Untitled" : profile.name)
                            Spacer()
                            if profile.problem != nil {
                                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                            }
                        }
                        .tag(profile.id)
                    }
                }
                .listStyle(.bordered)
                HStack(spacing: 4) {
                    Menu {
                        Button("Import .ovpn File…") { importOVPN(into: nil) }
                        if !tunnelblickSources.isEmpty {
                            Button("Import from Tunnelblick…") { importTunnelblick() }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    Button {
                        guard let id = draft.selection else { return }
                        draft.profiles.removeAll { $0.id == id }
                        draft.selection = draft.profiles.first?.id
                    } label: {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.borderless)
                    .disabled(draft.selection == nil)
                    Spacer()
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 6)
            }
            .frame(width: 200)

            if let index = draft.profiles.firstIndex(where: { $0.id == draft.selection }) {
                let id = draft.profiles[index].id
                ProfileEditor(profile: $draft.profiles[index], serverRoutes: knownRoutes(id),
                              replaceFile: { importOVPN(into: id) }, chooseRoutes: { routingFor = id })
            } else {
                VStack(spacing: 10) {
                    Text("No configuration").font(.title3)
                    Text("Add one from an .ovpn file with +.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    HStack {
                        Button("Import .ovpn File…") { importOVPN(into: nil) }
                        if !tunnelblickSources.isEmpty {
                            Button("Import from Tunnelblick…") { importTunnelblick() }
                        }
                    }
                }
                .padding(30)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - General tab

    private var general: some View {
        Form {
            Section {
                Toggle("Start Burrow at login", isOn: $draft.general.launchAtLogin)
                Toggle("Connect when Burrow starts", isOn: $draft.general.connectAtLaunch)
            } footer: {
                Text("Connects the selected configuration. One that asks for a code shows the sign-in window instead.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Reconnect after drops and sleep", isOn: $draft.general.keepConnected)
                Toggle("Show notifications", isOn: $draft.general.showNotifications)
            } footer: {
                Text("Configurations that connect without asking (1-click, a saved password, a certificate) reconnect on their own and tell you when they're back. Those that ask for a code or password notify you and open the sign-in window.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Send all DNS lookups through the VPN", isOn: $draft.general.useVPNDNS)
            } footer: {
                Text("Off: your Mac keeps its own DNS servers. On: the VPN's DNS servers answer every lookup.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if tunnelblickIsRunning {
                Section {
                    Label("Tunnelblick is running. Disconnect it there (and turn off its “Launch at login”) so two tunnels don't fight over the same routes.",
                          systemImage: "exclamationmark.triangle")
                        .font(.callout)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Import

    private func importOVPN(into id: UUID?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ovpn") ?? .data, UTType(filenameExtension: "conf") ?? .data]
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.message = "Choose an OpenVPN configuration (.ovpn) from your VPN portal."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            // The tunnel can't read files next to the .ovpn: carry the certificates and keys it names inline,
            // and move the logins it carries into the keychain.
            let folder = url.deletingLastPathComponent()
            var imported = OVPNImport(try String(contentsOf: url, encoding: .utf8)) { name in
                let file = name.hasPrefix("/") ? URL(fileURLWithPath: name) : folder.appendingPathComponent(name)
                guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 1_000_000 else { return nil }
                return try? Data(contentsOf: file)
            }
            if let bundle = imported.pkcs12 {
                guard let contents = Self.convertPKCS12(bundle, name: url.lastPathComponent) else {
                    note = "\(url.lastPathComponent): not imported, the PKCS#12 certificate wasn't converted."
                    return
                }
                imported.ovpn = OVPNImport.adding(contents, to: imported.ovpn)
            }
            let text = imported.ovpn
            let summary = OVPNSummary(text)
            if let problem = summary.problem {
                note = "\(url.lastPathComponent): \(problem)"
                return
            }
            func fill(_ profile: inout VPNProfile) {
                profile.ovpn = text
                if let username = imported.username { profile.username = username }
                if let password = imported.password {
                    profile.password = password
                    profile.savePassword = true
                }
                if let passphrase = imported.keyPassphrase { profile.keyPassphrase = passphrase }
                if let proxyUsername = imported.proxyUsername { profile.proxyUsername = proxyUsername }
                if let proxyPassword = imported.proxyPassword { profile.proxyPassword = proxyPassword }
            }
            if let id, let index = draft.profiles.firstIndex(where: { $0.id == id }) {
                fill(&draft.profiles[index])
            } else {
                // A new configuration asks for the code unless the user picks otherwise (1-click needs the key).
                var profile = VPNProfile(name: url.deletingPathExtension().lastPathComponent,
                                         otpMode: summary.needsUsernamePassword ? .prompt : .off)
                fill(&profile)
                draft.profiles.append(profile)
                draft.selection = profile.id
            }
            let moved = [imported.password != nil ? "password" : nil, imported.keyPassphrase != nil ? "passphrase" : nil,
                         imported.proxyPassword != nil ? "proxy login" : nil].compactMap { $0 }
            note = "Imported \(url.lastPathComponent)\(moved.isEmpty ? "" : "; its \(moved.joined(separator: ", ")) moved to the keychain")."
        } catch {
            note = "Could not read the file: \(error.localizedDescription)"
        }
    }

    /// Asks for the bundle's password until it opens, or the user cancels.
    private static func convertPKCS12(_ data: Data, name: String) -> PKCS12.Contents? {
        var message = "Burrow converts the PKCS#12 certificate of “\(name)” to the form OpenVPN 3 reads, and keeps it in the keychain."
        while true {
            let alert = NSAlert()
            alert.messageText = "Password of the .p12 certificate"
            alert.informativeText = message
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            alert.accessoryView = field
            alert.addButton(withTitle: "Convert")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            do {
                return try PKCS12.convert(data, password: field.stringValue)
            } catch PKCS12.ConversionError.wrongPassword {
                message = "That password didn't open it. Try again."
            } catch {
                let failure = NSAlert(error: error)
                failure.runModal()
                return nil
            }
        }
    }

    private func importTunnelblick() {
        do {
            let imported = try importFromTunnelblick(tunnelblickSources)
            for profile in imported {
                if let index = draft.profiles.firstIndex(where: { $0.name == profile.name }) {
                    let id = draft.profiles[index].id
                    draft.profiles[index] = profile
                    draft.profiles[index].id = id
                } else {
                    draft.profiles.append(profile)
                }
            }
            draft.selection = draft.profiles.first { $0.name == imported.first?.name }?.id ?? draft.selection
            note = "Imported \(imported.map(\.name).joined(separator: ", ")) from Tunnelblick."
        } catch TunnelblickImporter.ImportError.cancelled {
            note = nil
        } catch {
            note = error.localizedDescription
        }
    }
}

/// Who makes Burrow, its version and the licences of what it is built on.
struct AboutView: View {
    static let credits: [(name: String, role: String, license: String)] = [
        ("OpenVPN 3 Core", "VPN protocol engine, © OpenVPN Inc.", "AGPLv3"),
        ("OpenVPNAdapter", "Objective-C wrapper, © Sergey Abramchuk", "AGPLv3"),
        ("Mbed TLS 2.7", "TLS and cryptography", "Apache 2.0"),
        ("Asio", "networking", "Boost Software License"),
        ("LZ4", "compression", "BSD 2-Clause"),
        ("Sparkle", "software updates", "MIT"),
    ]

    /// cirtadev.com and cirta.dev, from Info.plist.
    static var websites: [URL] {
        (Bundle.main.infoDictionary?["CirtadevWebsites"] as? [String] ?? ["https://cirtadev.com", "https://cirta.dev"])
            .compactMap(URL.init(string:))
    }

    private var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 96, height: 96)
            VStack(spacing: 4) {
                Text("Burrow").font(.title.weight(.semibold))
                Text("Version \(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))")
                    .foregroundStyle(.secondary)
                Text("One-click OpenVPN with built-in one-time passwords.")
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 4) {
                Text(info["NSHumanReadableCopyright"] as? String ?? "© Cirtadev GmbH")
                HStack(spacing: 14) {
                    ForEach(Self.websites, id: \.self) { url in
                        Link(url.host() ?? url.absoluteString, destination: url)
                    }
                }
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Self.credits, id: \.name) { credit in
                        HStack(alignment: .firstTextBaseline) {
                            Text(credit.name).fontWeight(.medium)
                            Text(credit.role).foregroundStyle(.secondary)
                            Spacer()
                            Text(credit.license).foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
                .padding(6)
            } label: {
                Text("Built with")
            }
            .frame(maxWidth: 520)
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The detail pane for one configuration.
private struct ProfileEditor: View {
    @Binding var profile: VPNProfile
    var serverRoutes: [IPv4Network] = []
    var replaceFile: () -> Void
    var chooseRoutes: () -> Void = {}
    @State private var qrNote: String?

    /// Finds an `otpauth://totp` QR code in a screenshot or photo.
    private func readQRCode() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.message = "Choose a screenshot of the QR code you scanned to set up the authenticator."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let image = CIImage(contentsOf: url),
              let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                        options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]) else {
            qrNote = "Could not open the image."
            return
        }
        let codes = detector.features(in: image).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        if let link = codes.first(where: { $0.lowercased().hasPrefix("otpauth://totp") }), (try? TOTP(parsing: link)) != nil {
            profile.otpSecret = link
            qrNote = "Setup key read from the QR code."
        } else if codes.contains(where: { $0.lowercased().hasPrefix("otpauth-migration:") }) {
            qrNote = "That's a Google Authenticator export; use the original setup QR code instead."
        } else {
            qrNote = codes.isEmpty ? "No QR code found in the image." : "The QR code is not an authenticator setup code."
        }
    }

    private var summary: OVPNSummary { profile.summary }

    private static func list(_ text: String) -> String {
        let networks = IPv4Network.parseList(text).networks
        let hosts = HostNames.current()
        return networks.isEmpty ? "—" : networks.map(hosts.label).joined(separator: ", ")
    }

    private static let setupKeyHelp = "The setup key is not a 6-digit code: it's the secret your authenticator app got from the QR code when the token was set up. Copy it from the app (1Password, Bitwarden, Authy…), or screenshot the QR code in the VPN portal and use Read QR Code Image. The current code must then match your phone. No key? Choose “Ask me for the code”."

    /// How the code reaches the server: the ⓘ next to "Send the code" (or "The configuration asks").
    private var deliveryHelp: String {
        let delivery = summary.staticChallenge != nil
            ? "The configuration has a static challenge, so the code goes in a field of its own."
            : profile.codeDelivery == .appended
            ? "Burrow sends the code right after the password (for example, “mypassword123456” for the password “mypassword” and the code 123456), which most servers expect. If yours asks for it in a second step, choose “When the server asks for it”."
            : "Burrow sends the password alone and the code when the server asks for it (a dynamic challenge or CR_TEXT)."
        return delivery + " If the server uses a sign-in page (SSO), Burrow opens it in your browser."
    }

    /// The section's note: what no ⓘ explains.
    private var otpFooter: String? {
        switch profile.otpMode {
        case .automatic: nil
        case .prompt: "Burrow asks for the code from your authenticator each time it connects, and after a drop."
        case .off: "Burrow sends the username and password only. If the server asks a question (a PIN, an SMS code) or sends you to a sign-in page, Burrow shows it when you connect."
        }
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $profile.name)
                LabeledContent("OpenVPN file") {
                    VStack(alignment: .trailing, spacing: 8) {
                        Text(profile.summary.problem ?? profile.summary.serverDescription)
                            .foregroundStyle(profile.summary.problem == nil ? Color.primary : Color.red)
                        Button("Replace…", action: replaceFile).controlSize(.small)
                    }
                }
            }

            Section {
                if profile.usesPassword {
                    TextField("Username", text: $profile.username)
                        .textContentType(.username)
                    SecureField("Password", text: $profile.password,
                                prompt: profile.savePassword ? nil : Text("Asked when you connect"))
                        .textContentType(.password)
                        .disabled(!profile.savePassword)
                } else {
                    LabeledContent("Sign-in", value: "Certificate in the file")
                }
                if summary.keyIsEncrypted {
                    SecureField("Key passphrase", text: $profile.keyPassphrase,
                                prompt: profile.savePassword ? nil : Text("Asked when you connect"))
                        .disabled(!profile.savePassword)
                }
                if profile.usesPassword || summary.keyIsEncrypted {
                    Toggle(profile.usesPassword && summary.keyIsEncrypted ? "Save password and passphrase in the keychain"
                           : profile.usesPassword ? "Save password in the keychain" : "Save passphrase in the keychain",
                           isOn: $profile.savePassword)
                }
            } header: {
                Text("Account")
            } footer: {
                if !profile.usesPassword {
                    Text("This configuration has no auth-user-pass line: the server checks its certificate. If the server asks a question or sends you to a sign-in page, Burrow shows it when you connect.")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if profile.usesPassword {
                Section {
                    Picker("Mode", selection: $profile.otpMode) {
                        (Text("1-click: Burrow generates the code   ")
                            + Text("CAUTION").font(.caption.weight(.bold)).foregroundStyle(.orange))
                            .tag(VPNProfile.OTPMode.automatic)
                        (Text("Ask me for the code   ")
                            + Text("RECOMMENDED").font(.caption.weight(.bold)).foregroundStyle(.green))
                            .tag(VPNProfile.OTPMode.prompt)
                        Text("No one-time password").tag(VPNProfile.OTPMode.off)
                    }
                    .pickerStyle(.radioGroup)
                    if profile.otpMode == .automatic {
                        Label {
                            Text("Caution: the fastest way, not the recommended one. The setup key is stored on this Mac next to your password, so anyone with this Mac has both factors. Use it only on a Mac you alone use, with FileVault on.")
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                        .font(.callout)
                        LabeledContent {
                            SecureField("Setup key", text: $profile.otpSecret, prompt: Text("Paste the key or otpauth:// link"))
                                .labelsHidden()
                        } label: {
                            HStack(spacing: 4) {
                                Text("Setup key")
                                InfoButton(text: Self.setupKeyHelp)
                            }
                        }
                        HStack {
                            if let qrNote {
                                Text(qrNote).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Read QR Code Image…") { readQRCode() }
                                .controlSize(.small)
                        }
                        OTPPreview(secret: profile.otpSecret)
                    }
                    if let challenge = summary.staticChallenge {
                        LabeledContent {
                            Text(challenge)
                        } label: {
                            HStack(spacing: 4) {
                                Text("The configuration asks")
                                InfoButton(text: deliveryHelp)
                            }
                        }
                    } else if profile.otpMode != .off {
                        LabeledContent {
                            Picker("Send the code", selection: $profile.codeDelivery) {
                                Text("With the password").tag(VPNProfile.CodeDelivery.appended)
                                Text("When the server asks for it").tag(VPNProfile.CodeDelivery.challenge)
                            }
                            .labelsHidden()
                            .fixedSize()
                        } label: {
                            HStack(spacing: 4) {
                                Text("Send the code")
                                InfoButton(text: deliveryHelp)
                            }
                        }
                    }
                } header: {
                    Text("One-time password")
                } footer: {
                    if let otpFooter {
                        Text(otpFooter)
                            .font(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            if summary.usesHTTPProxy {
                Section {
                    TextField("Proxy username", text: $profile.proxyUsername)
                    SecureField("Proxy password", text: $profile.proxyPassword)
                } header: {
                    Text("HTTP proxy")
                } footer: {
                    Text(summary.hasProxyLogin ? "The configuration carries the proxy login itself." : "Only if the proxy asks for a login. Kept in the keychain.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Section {
                if let clash = VPNController.clashMessage(for: profile, serverRoutes: serverRoutes) {
                    Button(action: chooseRoutes) {
                        Label {
                            Text(clash).fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Choose what goes where")
                }
                LabeledContent("Through the VPN", value: Self.list(profile.alwaysViaVPN))
                LabeledContent("Kept on your network", value: Self.list(profile.alwaysLocal))
                HStack {
                    Spacer()
                    Button(VPNController.clashMessage(for: profile, serverRoutes: serverRoutes) == nil ? "Choose Routes…" : "Fix Routing…",
                           action: chooseRoutes)
                }
            } header: {
                Text("Routing")
            } footer: {
                Text("The VPN's routes go through the VPN. When your own network uses the same range, Burrow finds your devices on it and keeps them local, and everything else in the range goes through the VPN, so company servers there work without listing them. Choose Routes lists the VPN's routes (from the last connection) to override that with VPN or Local.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let problem = profile.problem {
                Section {
                    Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
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
    private let navigation = SettingsNavigation()

    init(settings: AppSettings, vpn: VPNController) {
        self.settings = settings
        self.vpn = vpn
    }

    /// `routingFor`: open that configuration's routing table.
    func show(routingFor: UUID? = nil) {
        navigation.routingProfile = routingFor
        if let window {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }
        settings.reloadProfiles()
        let draft = SettingsDraft(
            profiles: settings.profiles,
            selection: settings.selectedProfile?.id,
            general: GeneralSettings(
                connectAtLaunch: settings.connectAtLaunch,
                launchAtLogin: SMAppService.mainApp.status == .enabled,
                keepConnected: settings.keepConnected,
                useVPNDNS: settings.useVPNDNS,
                showNotifications: settings.showNotifications))
        let view = SettingsView(
            draft: draft,
            tunnelblickSources: TunnelblickImport.sources(),
            tunnelblickIsRunning: vpn.tunnelblickIsRunning,
            importFromTunnelblick: { try TunnelblickImporter.importProfiles($0) },
            knownRoutes: { [vpn] in vpn.knownRoutes(for: $0) },
            localDevices: { [vpn] in vpn.activeProfileID == $0 ? vpn.localDevices : [] },
            navigation: navigation,
            onSave: { [weak self] in self?.save($0) },
            onCancel: { [weak self] in self?.window?.close() })
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.minSize]  // the SwiftUI minimum; the user can make it as large as they like
        let window = NSWindow(contentViewController: hosting)
        window.title = "Burrow Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 760, height: 640))
        window.center()
        window.setFrameAutosaveName("BurrowSettings")  // reopens at the size and place the user left it
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func save(_ draft: SettingsDraft) {
        let general = draft.general
        settings.connectAtLaunch = general.connectAtLaunch
        settings.keepConnected = general.keepConnected
        settings.useVPNDNS = general.useVPNDNS
        settings.showNotifications = general.showNotifications
        if general.showNotifications { vpn.notifier.requestPermission() }

        let kept = Set(draft.profiles.map(\.id))
        for profile in settings.profiles where !kept.contains(profile.id) {
            settings.delete(id: profile.id)
        }
        for profile in draft.profiles where settings.profile(id: profile.id) != profile {
            do {
                try settings.save(profile)
            } catch {
                let alert = NSAlert(error: error)
                alert.messageText = "Burrow could not save “\(profile.name)” in the keychain."
                alert.runModal()
                return
            }
        }
        settings.selectedProfileID = draft.selection ?? draft.profiles.first?.id
        vpn.settingsChanged()
        do {
            switch (general.launchAtLogin, SMAppService.mainApp.status == .enabled) {
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

/// An ⓘ next to a label: its text shows as a tooltip on hover, and in a popover on click.
struct InfoButton: View {
    let text: String
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "info.circle").foregroundStyle(.primary)
        }
        .buttonStyle(.borderless)
        .help(text)
        .accessibilityLabel("More about this")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 340, alignment: .leading)
                .padding(16)
        }
    }
}
