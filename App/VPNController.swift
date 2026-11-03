import AppKit
import BurrowKit
import NetworkExtension
import Observation

/// Owns Burrow's VPN configuration in System Settings and starts/stops its packet tunnel.
/// The tunnel system extension (BurrowTunnel) does the OpenVPN work; in 1-click mode it also computes the code.
/// It runs as root and can't read this user's keychain, so every start hands it the configuration and credentials.
@MainActor
@Observable
final class VPNController {
    enum Status: Equatable {
        case disconnected
        case connecting(String)
        case connected(since: Date, address: String)
        case disconnecting
        case failed(String)
    }

    static let tunnelBundleIdentifier = "dev.cirta.burrow.tunnel"

    private(set) var status: Status = .disconnected
    private(set) var bytesReceived: Int64 = 0
    private(set) var bytesSent: Int64 = 0
    /// Set while connected on a local network that uses one of the VPN's address ranges.
    private(set) var networkClash: String?
    /// The devices found on the local network in the ranges it shares with the VPN: they stay local, the rest
    /// of each range goes through the VPN.
    private(set) var localDevices: [LocalDevices] = []
    /// Local Network access is off for Burrow, so it can't look for those devices.
    private(set) var localNetworkBlocked = false
    /// The configuration the tunnel is (or was last) running.
    private(set) var activeProfileID: UUID?
    /// The page the server wants the user to sign in on while it waits (opened in the browser once).
    private(set) var webAuthURL: URL?

    /// Shows the sign-in window for a profile; the app delegate wires it to `SignInWindowController`.
    @ObservationIgnored var onNeedsSignIn: ((VPNProfile, String?) -> Void)?
    @ObservationIgnored var onNeedsSetup: (() -> Void)?
    /// Shows the server's question while connecting; nil closes it (answered, or the connection ended).
    @ObservationIgnored var onServerQuestion: ((VPNProfile, TunnelChallenge?) -> Void)?
    @ObservationIgnored private var askedChallengeID: Int?
    @ObservationIgnored let notifier: Notifier
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let tunnelExtension = SystemExtensionActivator()
    @ObservationIgnored private var manager: NETunnelProviderManager?
    @ObservationIgnored private var snapshot: TunnelSnapshot?
    @ObservationIgnored private var statusObserver: NSObjectProtocol?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    /// The shared ranges last scanned, and when.
    @ObservationIgnored private var lastScan: (key: String, at: Date)?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectDelay: TimeInterval = 5
    /// The user wants the tunnel up: set by connect, cleared by disconnect and by failures a retry can't fix.
    @ObservationIgnored private var wantsConnection = false
    @ObservationIgnored private var wasConnected = false
    /// Set while recovering from a drop or a session restart, so the next CONNECTED says "reconnected".
    @ObservationIgnored private var recovering = false
    @ObservationIgnored private var afterDisconnect: [() -> Void] = []
    /// Counts starts, so a start that waited for the extension's approval doesn't race a newer one.
    @ObservationIgnored private var startCount = 0
    /// The tunnel is starting, but not from Burrow (System Settings or the VPN menu).
    @ObservationIgnored private var startedElsewhere = false

    init(settings: AppSettings, notifier: Notifier) {
        self.settings = settings
        self.notifier = notifier
    }

    var tunnelblickIsRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "net.tunnelblick.tunnelblick").isEmpty
    }

    var isActive: Bool {
        switch manager?.connection.status {
        case .connected, .connecting, .reasserting, .disconnecting: true
        default: false
        }
    }

    var activeProfile: VPNProfile? { activeProfileID.flatMap(settings.profile(id:)) }

    // MARK: - Commands

    func start() async {
        manager = try? await Self.loadManager()
        let configured = (manager?.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
        activeProfileID = (configured?[TunnelOption.profileID] as? String).flatMap(UUID.init(uuidString:))
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: nil, queue: .main
        ) { [weak self] notification in
            let sender = (notification.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, let connection = self.manager?.connection,
                      sender == ObjectIdentifier(connection) else { return }
                self.statusDidChange()
            }
        }
        statusDidChange()
        tunnelExtension.onNeedsApproval = { [weak self] in self?.extensionNeedsApproval() }
        if isActive {
            // Don't install a newer extension now: replacing it would stop the running tunnel.
            wantsConnection = true
        } else if settings.connectAtLaunch, let profile = settings.selectedProfile, profile.isUsable {
            connect(profile.id)
        } else {
            // Install or update the extension now, so the user allows it once at first launch, not at first connect.
            _ = await installExtension()
        }
    }

    /// The menu-bar click: connect the selected configuration, or disconnect.
    func toggle() {
        switch status {
        case .connected, .connecting: disconnect()
        case .disconnecting: break
        case .disconnected, .failed: connect(settings.selectedProfile?.id)
        }
    }

    /// Connects a configuration, switching from another one if needed. Asks for whatever it doesn't store.
    func connect(_ id: UUID?) {
        reconnectTask?.cancel()
        reconnectTask = nil
        guard let id, let profile = settings.profile(id: id) else {
            status = .failed("Add a VPN configuration in Settings.")
            onNeedsSetup?()
            return
        }
        settings.selectedProfileID = id
        if let problem = profile.problem {
            status = .failed("\(profile.name): \(problem)")
            onNeedsSetup?()
            return
        }
        if isActive {
            guard activeProfileID != id else { return }
            disconnect { [weak self] in self?.connect(id) }
            return
        }
        if profile.asksBeforeConnecting {
            onNeedsSignIn?(profile, nil)
        } else {
            // Asks nothing first; a question from the server pops up while connecting.
            start(profile, password: nil, code: nil)
        }
    }

    /// Called by the sign-in window.
    func signIn(_ profile: VPNProfile, _ entry: SignInEntry) {
        if entry.savePassword, !entry.password.isEmpty || !entry.passphrase.isEmpty {
            var updated = settings.profile(id: profile.id) ?? profile
            if !entry.password.isEmpty { updated.password = entry.password }
            if !entry.passphrase.isEmpty { updated.keyPassphrase = entry.passphrase }
            updated.savePassword = true
            try? settings.save(updated)
        }
        start(profile, password: entry.password.isEmpty ? nil : entry.password,
              passphrase: entry.passphrase.isEmpty ? nil : entry.passphrase,
              code: entry.code.isEmpty ? nil : entry.code)
    }

    /// The user's answer to the server's question.
    func answer(_ challenge: TunnelChallenge, with response: String) {
        Task { _ = await sendMessage(TunnelMessage.answer(id: challenge.id, response: response).data) }
    }

    /// Opens the server's sign-in page again (the user closed the browser tab).
    func openWebAuthPage() {
        if let webAuthURL { NSWorkspace.shared.open(webAuthURL) }
    }

    private func start(_ profile: VPNProfile, password: String?, passphrase: String? = nil, code: String?) {
        wantsConnection = true
        activeProfileID = profile.id
        status = .connecting("Starting…")
        startCount += 1
        let thisStart = startCount
        let request = TunnelStartRequest(profile: profile, password: password, passphrase: passphrase, code: code)
        Task {
            guard await self.installExtension() else {
                self.wantsConnection = false
                self.recovering = false
                return
            }
            // Cancelled or superseded while macOS waited for the user to allow the extension.
            guard thisStart == self.startCount, self.wantsConnection else { return }
            do {
                let manager = try await self.installedManager(for: profile)
                try manager.connection.startVPNTunnel(options: request.options)
            } catch {
                self.wantsConnection = false
                self.recovering = false
                self.status = .failed(Self.describe(error))
            }
        }
    }

    func disconnect(then completion: (() -> Void)? = nil) {
        wantsConnection = false
        recovering = false
        reconnectTask?.cancel()
        reconnectTask = nil
        guard let manager, isActive else {
            if case .connecting = status { status = .disconnected }
            completion?()
            return
        }
        if let completion { afterDisconnect.append(completion) }
        manager.connection.stopVPNTunnel()
    }

    /// Settings changed: push the non-secret options into the VPN configuration.
    func settingsChanged() {
        guard let profile = activeProfile ?? settings.selectedProfile, profile.isUsable else { return }
        Task { _ = try? await installedManager(for: profile) }
        if isActive, let active = activeProfile {
            lastScan = nil // a range set back to automatic is scanned at once
            // Routing choices apply to the running tunnel at once.
            let message = TunnelMessage.routes(viaVPN: active.alwaysViaVPN, local: active.alwaysLocal)
            Task { _ = await sendMessage(message.data) }
        }
    }

    /// The VPN server's own routes from the last session of a configuration (for Settings › Routing).
    func knownRoutes(for id: UUID) -> [IPv4Network] {
        (UserDefaults.standard.stringArray(forKey: "serverRoutes.\(id.uuidString)") ?? []).compactMap(IPv4Network.init)
    }

    /// The first clash between the VPN's routes and the local network that the user hasn't decided, explained.
    static func clashMessage(for profile: VPNProfile, serverRoutes: [IPv4Network]) -> String? {
        let local = LocalNetworks.current()
        guard let clash = RouteChoices.undecided(
            pushed: serverRoutes, local: local, viaVPN: IPv4Network.parseList(profile.alwaysViaVPN).networks,
            alwaysLocal: IPv4Network.parseList(profile.alwaysLocal).networks).first else { return nil }
        let network = "Your network (\(clash.localNetwork) on \(InterfaceNames.display(clash.interface)))"
        return clash.vpnRoute.prefix > clash.localNetwork.prefix
            ? "\(network) overlaps the VPN's \(clash.vpnRoute): devices there aren't reachable. Choose what goes where in Routing."
            : "\(network) uses the same addresses as the VPN's \(clash.vpnRoute): servers there aren't reachable. Choose what goes where in Routing."
    }

    static let blockedMessage = "Your network uses the same addresses as the VPN. To keep its devices reachable and send the rest through the VPN, allow Burrow in System Settings › Privacy & Security › Local Network."

    /// The panel's note on a shared range Burrow splits.
    var networkSplit: String? {
        guard let scan = localDevices.first else { return nil }
        let devices = scan.found.count - 1 // without this Mac
        return "Your network shares \(scan.range) with the VPN: its \(devices) device\(devices == 1 ? "" : "s") stay local, everything else there goes through the VPN."
    }

    func currentCode() -> (code: String, secondsLeft: Int)? {
        guard let profile = settings.selectedProfile, profile.effectiveOTPMode == .automatic,
              let totp = try? TOTP(parsing: profile.otpSecret) else { return nil }
        return (totp.code(at: .now), totp.secondsRemaining(at: .now))
    }

    /// Recent OpenVPN log lines from the running extension.
    func fetchLog() async -> String? {
        guard isActive, let data = await sendMessage(TunnelMessage.log.data) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - System extension

    /// Activates the tunnel extension bundled with this copy of Burrow; on failure the status says what to do.
    private func installExtension() async -> Bool {
        if tunnelExtension.needsApproval, case .connecting = status {
            status = .connecting(SystemExtensionActivator.approvalHint)
            tunnelExtension.openApprovalSettings()
        }
        do {
            try await tunnelExtension.activate()
            if status == .failed(SystemExtensionActivator.approvalHint) { status = .disconnected }
            return true
        } catch {
            status = .failed(error.localizedDescription)
            return false
        }
    }

    /// macOS is waiting for the user to allow the tunnel extension in System Settings.
    var needsExtensionApproval: Bool {
        status == .connecting(SystemExtensionActivator.approvalHint) || status == .failed(SystemExtensionActivator.approvalHint)
    }

    /// Opens System Settings › General › Login Items & Extensions, where the extension is allowed.
    func openExtensionSettings() {
        tunnelExtension.openApprovalSettings()
    }

    private func extensionNeedsApproval() {
        switch status {
        case .connecting:
            status = .connecting(SystemExtensionActivator.approvalHint)
        case .disconnected, .failed:
            status = .failed(SystemExtensionActivator.approvalHint)
        default:
            break
        }
        notifier.post("Allow Burrow's VPN", "Click to open System Settings, then click ⓘ next to Burrow and switch it on.",
                      opensApprovalSettings: true)
    }

    // MARK: - VPN configuration

    private static func loadManager() async throws -> NETunnelProviderManager? {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        return managers.first {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == tunnelBundleIdentifier
        }
    }

    /// The certificate this copy of Burrow is signed with ("Developer ID Application: …" or "Apple Development: …").
    static let signingCertificate: String = {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let certificates = (info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first,
              let name = SecCertificateCopySubjectSummary(leaf) as String? else { return "unsigned" }
        return name
    }()

    /// Creates or updates Burrow's entry in System Settings › VPN. The first save makes macOS ask the user.
    private func installedManager(for profile: VPNProfile) async throws -> NETunnelProviderManager {
        var loaded = try await Self.loadManager()
        // macOS ties the configuration to the signature of the Burrow that saved it, and refuses to start the
        // tunnel for a differently signed copy ("does not satisfy the code signature requirements"), e.g. a
        // release after a development build. Recreate it then.
        let signer = Self.signingCertificate
        let signerKey = "vpnConfigurationSigner"
        if let stale = loaded, UserDefaults.standard.string(forKey: signerKey) != signer {
            try? await stale.removeFromPreferences()
            loaded = nil
        }
        let manager = loaded ?? NETunnelProviderManager()
        let existing = manager.protocolConfiguration as? NETunnelProviderProtocol
        let description = "Burrow – \(profile.name)"
        let server = profile.summary.remoteHost ?? "OpenVPN"
        let upToDate = existing?.providerBundleIdentifier == Self.tunnelBundleIdentifier
            && existing?.serverAddress == server
            && (existing?.providerConfiguration?[TunnelOption.profileID] as? String) == profile.id.uuidString
            && (existing?.providerConfiguration?[TunnelOption.useVPNDNS] as? Bool) == settings.useVPNDNS
            && manager.localizedDescription == description
            && manager.isEnabled
        if !upToDate {
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = Self.tunnelBundleIdentifier
            proto.serverAddress = server
            proto.providerConfiguration = [
                TunnelOption.profileID: profile.id.uuidString, TunnelOption.useVPNDNS: settings.useVPNDNS,
            ]
            proto.disconnectOnSleep = false
            manager.protocolConfiguration = proto
            manager.localizedDescription = description
            manager.isEnabled = true
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
        }
        UserDefaults.standard.set(signer, forKey: signerKey)
        if self.manager !== manager {
            self.manager = manager
            statusDidChange()
        }
        return manager
    }

    // MARK: - Status

    private func statusDidChange() {
        guard let connection = manager?.connection else {
            if case .connecting = status { return }
            status = .disconnected
            return
        }
        switch connection.status {
        case .connecting:
            if !wantsConnection { startedElsewhere = true }
            status = .connecting(snapshot?.phase ?? "Connecting…")
            startPolling()
        case .reasserting:
            recovering = true
            lastScan = nil // probably another network
            status = .connecting("Reconnecting…")
            startPolling()
        case .connected:
            if recovering, let name = activeProfile?.name {
                notifier.post("Reconnected", "Burrow reconnected to \(name).")
            }
            recovering = false
            wasConnected = true
            serverAsked(nil, webAuthURL: nil)
            reconnectDelay = 5
            status = .connected(since: connection.connectedDate ?? .now, address: snapshot?.tunnelAddress ?? "")
            startPolling()
        case .disconnecting:
            status = .disconnecting
        case .disconnected, .invalid:
            networkClash = nil
            scanTask?.cancel()
            scanTask = nil
            lastScan = nil
            localDevices = []
            localNetworkBlocked = false
            serverAsked(nil, webAuthURL: nil)
            stopPolling()
            snapshot = nil
            connectionEnded(connection)
        @unknown default:
            break
        }
    }

    private func connectionEnded(_ connection: NEVPNConnection) {
        let userStopped = !wantsConnection
        let hadConnected = wasConnected
        wasConnected = false
        let elsewhere = startedElsewhere
        startedElsewhere = false
        guard !userStopped else {
            status = .disconnected
            runAfterDisconnect()
            if elsewhere { connectIfStartedElsewhere(connection) }
            return
        }
        connection.fetchLastDisconnectError { error in
            let nsError = error as NSError?
            Task { @MainActor in
                self.handleDrop(nsError, hadConnected: hadConnected)
                self.runAfterDisconnect()
            }
        }
    }

    /// Connect in System Settings or the VPN menu starts the tunnel without Burrow's options, and it stops at once.
    /// Do what the user asked for: connect from here.
    private func connectIfStartedElsewhere(_ connection: NEVPNConnection) {
        connection.fetchLastDisconnectError { error in
            let nsError = error as NSError?
            guard nsError?.domain == TunnelFailure.domain, nsError?.code == TunnelFailure.startedWithoutApp else { return }
            Task { @MainActor in
                guard !self.wantsConnection, !self.isActive else { return }
                self.connect(self.activeProfileID ?? self.settings.selectedProfile?.id)
            }
        }
    }

    private func runAfterDisconnect() {
        let callbacks = afterDisconnect
        afterDisconnect = []
        callbacks.forEach { $0() }
    }

    private func handleDrop(_ error: NSError?, hadConnected: Bool) {
        var profile = activeProfile
        let message = error.map(Self.describe) ?? "The VPN connection ended."
        let code = error?.domain == TunnelFailure.domain ? error?.code ?? 0 : 0
        if code == TunnelFailure.passphraseNeeded, var wrong = profile, !wrong.keyPassphrase.isEmpty {
            // The key refused the saved passphrase: forget it, so the sign-in window asks for it.
            wrong.keyPassphrase = ""
            try? settings.save(wrong)
            profile = wrong
        }

        // Prompt mode (or an unsaved password or passphrase): the user has to type something to continue.
        let typedRejected = code == TunnelFailure.credentialsRejected || code == TunnelFailure.passphraseNeeded
        if let profile, code == TunnelFailure.codeNeeded || code == TunnelFailure.passwordNeeded
            || (typedRejected && (!profile.isOneClick || code == TunnelFailure.passphraseNeeded)) {
            status = .failed(message)
            let reconnecting = hadConnected && settings.keepConnected
            if reconnecting || typedRejected {
                recovering = reconnecting
                if reconnecting {
                    notifier.post("\(profile.name) disconnected", Self.reconnectHint(profile), signInProfile: profile.id)
                }
                onNeedsSignIn?(profile, typedRejected ? message : nil)
            } else {
                wantsConnection = false
            }
            return
        }

        status = .failed(message)
        // Reconnect a tunnel that worked and dropped; not one that never came up or was refused.
        if hadConnected, settings.keepConnected, TunnelFailure.allowsReconnect(error), let profile {
            recovering = true
            scheduleReconnect(profile)
        } else {
            wantsConnection = false
            recovering = false
            if hadConnected, let profile {
                notifier.post("\(profile.name) disconnected", message)
            }
        }
    }

    private func scheduleReconnect(_ profile: VPNProfile) {
        guard !profile.asksBeforeConnecting else {
            // Without a stored code source a silent retry can't work: ask the user.
            notifier.post("\(profile.name) disconnected", Self.reconnectHint(profile), signInProfile: profile.id)
            onNeedsSignIn?(profile, nil)
            return
        }
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 120)
        status = .connecting("Connection lost; reconnecting in \(Int(delay)) s…")
        reconnectTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, self.wantsConnection, !self.isActive else { return }
            self.start(profile, password: nil, code: nil)
        }
    }

    private static func reconnectHint(_ profile: VPNProfile) -> String {
        profile.effectiveOTPMode == .prompt ? "Enter a new code to reconnect." : "Sign in again to reconnect."
    }

    /// Shows a new question from the server and opens a new sign-in page; nil clears them.
    private func serverAsked(_ challenge: TunnelChallenge?, webAuthURL page: String?) {
        if let challenge, challenge.id != askedChallengeID, let profile = activeProfile {
            askedChallengeID = challenge.id
            onServerQuestion?(profile, challenge)
        } else if challenge == nil, askedChallengeID != nil {
            askedChallengeID = nil
            onServerQuestion?(activeProfile ?? VPNProfile(), nil)
        }
        let url = page.flatMap(ServerInfo.webURL)
        if let url, url != webAuthURL {
            // Only http(s) pages reach here (ServerInfo.webURL): a server can't make Burrow open files or apps.
            NSWorkspace.shared.open(url)
        }
        webAuthURL = url
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task {
            while !Task.isCancelled {
                await self.poll()
                let connected = if case .connected = self.status { true } else { false }
                // Twice a second while connecting, so the panel's countdowns tick evenly.
                try? await Task.sleep(for: .seconds(connected ? 3 : 0.5))
            }
        }
    }

    /// Looks for the devices of the ranges the local network shares with the VPN (again every 10 minutes, and
    /// after a network change) and hands them to the tunnel, which sends every other address of those ranges
    /// through the VPN. Company servers there are reachable without listing them.
    private func scanLocalNetworkIfNeeded(_ serverRoutes: [IPv4Network]) {
        guard case .connected = status, scanTask == nil, let profile = activeProfile else { return }
        let clashes = RouteChoices.automatic(
            pushed: serverRoutes, local: LocalNetworks.current(), viaVPN: IPv4Network.parseList(profile.alwaysViaVPN).networks,
            alwaysLocal: IPv4Network.parseList(profile.alwaysLocal).networks)
        let key = clashes.map { "\($0.shared) \($0.localNetwork) \($0.interface)" }.joined(separator: ",")
        if let lastScan, lastScan.key == key, Date.now.timeIntervalSince(lastScan.at) < 600 { return }
        lastScan = (key, .now)
        scanTask = Task {
            // Each interface at once: a scan takes about 7 seconds.
            let results = await withTaskGroup(of: Result<LocalDevices, LocalDeviceScan.Failure>.self) { group in
                for clash in clashes {
                    group.addTask {
                        do throws(LocalDeviceScan.Failure) { return .success(try await LocalDeviceScan.run(clash)) }
                        catch { return .failure(error) }
                    }
                }
                var all: [Result<LocalDevices, LocalDeviceScan.Failure>] = []
                for await result in group { all.append(result) }
                return all
            }
            guard !Task.isCancelled else { return }
            let scans = results.compactMap { try? $0.get() }.sorted { $0.found.count > $1.found.count }
            let blocked = results.contains { $0 == .failure(.notAllowed) }
            if scans != localDevices || blocked != localNetworkBlocked {
                localDevices = scans
                localNetworkBlocked = blocked
                _ = await sendMessage(TunnelMessage.devices(scans).data)
            }
            scanTask = nil
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func poll() async {
        guard let data = await sendMessage(TunnelMessage.snapshot.data),
              let snapshot = try? JSONDecoder().decode(TunnelSnapshot.self, from: data) else { return }
        self.snapshot = snapshot
        if manager?.connection.status == .connecting || manager?.connection.status == .reasserting {
            serverAsked(snapshot.challenge, webAuthURL: snapshot.webAuthURL)
        }
        let serverRoutes = (snapshot.pushedRoutes ?? snapshot.routes ?? []).compactMap(IPv4Network.init)
        if let id = activeProfileID, let pushed = snapshot.pushedRoutes, !pushed.isEmpty {
            UserDefaults.standard.set(pushed, forKey: "serverRoutes.\(id.uuidString)")
        }
        networkClash = activeProfile.flatMap { Self.clashMessage(for: $0, serverRoutes: serverRoutes) }
            ?? (localNetworkBlocked ? Self.blockedMessage : nil)
        scanLocalNetworkIfNeeded(serverRoutes)
        bytesReceived = snapshot.bytesIn
        bytesSent = snapshot.bytesOut
        switch status {
        case .connecting(let detail) where detail != snapshot.phase && manager?.connection.status == .connecting:
            status = .connecting(snapshot.phase)
        case .connected(let since, let address) where address != (snapshot.tunnelAddress ?? ""):
            status = .connected(since: since, address: snapshot.tunnelAddress ?? "")
        default:
            break
        }
    }

    private func sendMessage(_ message: Data) async -> Data? {
        guard let session = manager?.connection as? NETunnelProviderSession else { return nil }
        return await withCheckedContinuation { continuation in
            do {
                try session.sendProviderMessage(message) { response in
                    continuation.resume(returning: response)
                }
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NEVPNErrorDomain, nsError.code == NEVPNError.configurationReadWriteFailed.rawValue {
            return "macOS did not allow Burrow to add its VPN configuration."
        }
        return nsError.localizedDescription
    }
}
