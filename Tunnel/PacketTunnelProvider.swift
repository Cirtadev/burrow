import BurrowKit
import NetworkExtension
import OpenVPNAdapter
import os

extension NEPacketTunnelFlow: OpenVPNAdapterPacketFlow {}

/// Runs OpenVPN 3 (OpenVPNAdapter) inside the system's packet tunnel and signs in the way the configuration and
/// server want: password + a fresh TOTP code, a static or dynamic challenge, CR_TEXT, a web sign-in page, a
/// certificate only. Every (re)connection gets a code that was never sent before: instead of letting OpenVPN
/// replay cached credentials, it restarts the session with new ones.
final class PacketTunnelProvider: NEPacketTunnelProvider, OpenVPNAdapterDelegate {
    private let log = Logger(subsystem: "dev.cirta.burrow.tunnel", category: "tunnel")
    private let queue = DispatchQueue(label: "dev.cirta.burrow.tunnel.state")
    private let reachability = OpenVPNReachability()

    /// From the start options; kept in memory for restarts, dropped when the tunnel ends.
    private var profile = VPNProfile()
    /// The saved password, or the one typed in the sign-in window.
    private var password = ""
    /// Prompt mode: the code typed for this start, used once.
    private var typedCode: String?
    private var useVPNDNS = false
    /// IPv4 routes of the current session (after the user's choices), and the server's own ones.
    private var routes: [String] = []
    private var pushedRoutes: [String] = []
    /// The session's settings as the server sent them, to apply new routing choices without reconnecting.
    private var sessionSettings: NEPacketTunnelNetworkSettings?
    private var serverIncluded: [NEIPv4Route] = []
    private var serverExcluded: [NEIPv4Route] = []
    /// From the app: the devices on the local network in the ranges it shares with the VPN.
    private var localDevices: [LocalDevices] = []
    private var adapter: OpenVPNAdapter?
    private var endedAdapters = Set<ObjectIdentifier>()
    private var startCompletion: ((Error?) -> Void)?
    private var stopCompletion: (() -> Void)?
    private var stopping = false
    private var restarting = false
    private var everConnected = false
    private var authFailures = 0
    /// Burrow checks the server certificate with remote-cert-tls instead of the configuration's ns-cert-type.
    private var nsCertTypeReplaced = false
    private var pendingError: NSError?
    private var phase = "Starting…"
    private var recentLog: [String] = []
    /// The server's question, shown by the app until the user answers it.
    private var challenge: TunnelChallenge?
    private var challengeCount = 0
    /// A dynamic challenge (CRV1) ended the session; the next session carries the answer.
    private var challengeCookie: String?
    private var challengeAnswer: String?
    /// The page the server asked the user to sign in on, while it waits (OPEN_URL / WEB_AUTH).
    private var webAuthURL: String?

    private var scheduler: OTPScheduler = {
        let stored = UserDefaults.standard.object(forKey: "lastUsedOTPCounter") as? NSNumber
        return OTPScheduler(lastUsedCounter: stored?.uint64Value)
    }()

    // MARK: - NEPacketTunnelProvider

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        // Running as root, the extension can't read the user's keychain: Burrow sends the configuration and
        // credentials with every start. They stay in this object's memory (for restarts) and are never logged.
        guard let request = TunnelStartRequest(options: options) else {
            log.error("started without Burrow's options")
            completionHandler(TunnelFailure.startedWithoutAppError)
            return
        }
        if let failure = request.failure {
            completionHandler(failure)
            return
        }
        let configuration = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
        queue.async {
            self.profile = request.profile
            self.password = request.profile.password
            self.typedCode = request.code
            self.useVPNDNS = configuration?[TunnelOption.useVPNDNS] as? Bool ?? false
            self.startCompletion = completionHandler
            self.reachability.startTracking { [weak self] status in
                guard let self else { return }
                self.queue.async {
                    guard self.everConnected, status != .notReachable else { return }
                    self.renewSession("network changed")
                }
            }
            self.launchAdapter()
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        queue.async {
            self.log.info("stop requested, reason \(reason.rawValue, privacy: .public)")
            self.stopping = true
            self.reachability.stopTracking()
            guard let adapter = self.adapter, !self.endedAdapters.contains(ObjectIdentifier(adapter)) else {
                self.forgetCredentials()
                completionHandler()
                return
            }
            self.stopCompletion = completionHandler
            adapter.disconnect()
            self.queue.asyncAfter(deadline: .now() + 5) { self.adapterEnded(adapter) }
        }
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        queue.async {
            self.adapter?.pause(withReason: "sleep")
            completionHandler()
        }
    }

    override func wake() {
        queue.async { self.renewSession("wake") }
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        queue.async {
            switch TunnelMessage(messageData) {
            case .log:
                completionHandler?(Data(self.recentLog.joined(separator: "\n").utf8))
            case .answer(let id, let response):
                self.answer(id, response)
                completionHandler?(nil)
            case .routes(let viaVPN, let local):
                self.profile.alwaysViaVPN = viaVPN
                self.profile.alwaysLocal = local
                self.reapplyRoutes()
                completionHandler?(nil)
            case .devices(let scans):
                if scans != self.localDevices {
                    self.localDevices = scans
                    self.reapplyRoutes()
                }
                completionHandler?(nil)
            case .snapshot:
                let stats = self.adapter?.interfaceStatistics
                let info = self.adapter?.connectionInformation
                let snapshot = TunnelSnapshot(
                    phase: self.phase,
                    bytesIn: Int64(stats?.bytesIn ?? 0), bytesOut: Int64(stats?.bytesOut ?? 0),
                    tunnelAddress: info?.vpnIPv4, serverAddress: info?.serverIP,
                    lastError: self.pendingError?.localizedDescription, routes: self.routes,
                    challenge: self.challenge, webAuthURL: self.webAuthURL, pushedRoutes: self.pushedRoutes)
                completionHandler?(try? JSONEncoder().encode(snapshot))
            }
        }
    }

    // MARK: - Session lifecycle (on `queue`)

    private func launchAdapter() {
        guard !stopping else { return }
        if let cookie = challengeCookie {
            if let answer = challengeAnswer {
                challengeCookie = nil
                challengeAnswer = nil
                connect(code: nil, challengeReply: (cookie, answer))
            } else if challenge == nil, profile.answersChallenges {
                freshCode { code in
                    guard self.challengeCookie == cookie else { return }
                    self.challengeCookie = nil
                    self.connect(code: nil, challengeReply: (cookie, code))
                }
            }
            // Otherwise the app shows the question, and answer(_:_:) starts the next session.
            return
        }
        switch profile.upFrontCode {
        case .none:
            connect(code: nil)
        case .typed:
            guard let code = typedCode else {
                // A typed code works once; the app asks the user for a new one.
                finish(TunnelFailure.error(TunnelFailure.codeNeeded, "Enter a new code to reconnect \(profile.name)."))
                return
            }
            typedCode = nil
            connect(code: code)
        case .generated:
            freshCode { self.connect(code: $0) }
        }
    }

    /// A code for a time step that was never sent, waiting for the next step if this one is used or ending.
    private func freshCode(then use: @escaping (String) -> Void) {
        guard !stopping else { return }
        let totp: TOTP
        do {
            totp = try TOTP(parsing: profile.otpSecret)
        } catch {
            giveUp(TunnelFailure.error(TunnelFailure.notConfigured, "OTP secret: \(error.localizedDescription)"))
            return
        }
        switch scheduler.decide(totp, now: Date()) {
        case .wait(let delay):
            log.info("waiting \(delay, privacy: .public) s for a fresh code")
            waitForCode(until: Date().addingTimeInterval(delay), then: use)
        case .send(let code, let counter):
            scheduler.markUsed(counter)
            UserDefaults.standard.set(NSNumber(value: counter), forKey: "lastUsedOTPCounter")
            use(code)
        }
    }

    /// Counts the wait down in the phase, which the panel shows, a second at a time; then asks for the code again.
    private func waitForCode(until end: Date, then use: @escaping (String) -> Void) {
        guard !stopping else { return }
        let left = end.timeIntervalSinceNow
        guard left > 0 else { return freshCode(then: use) }
        let shown = left.rounded(.up)
        phase = "Waiting \(Int(shown)) s for a fresh code…"
        // Tick when the number changes.
        queue.asyncAfter(deadline: .now() + (left - (shown - 1))) { self.waitForCode(until: end, then: use) }
    }

    /// `code` goes with the password (appended, or as the static challenge's answer); `challengeReply` answers
    /// the dynamic challenge that ended the previous session.
    private func connect(code: String?, challengeReply: (cookie: String, answer: String)? = nil) {
        let adapter = OpenVPNAdapter()
        adapter.delegate = self
        self.adapter = adapter

        let configuration = OpenVPNConfiguration()
        // OpenVPN 3.11 refuses OpenVPN 2 directives it doesn't use: Burrow leaves out the harmless ones.
        let prepared = TunnelConfig.prepared(for: profile)
        nsCertTypeReplaced = prepared.notes.contains { $0.hasPrefix("ns-cert-type") }
        for note in prepared.notes {
            log.info("configuration: \(note, privacy: .public)")
            appendLog("configuration: \(note)")
        }
        configuration.fileContent = Data(prepared.ovpn.utf8)
        configuration.tunPersist = true
        let info = Bundle.main.infoDictionary
        configuration.guiVersion = "Burrow \(info?["CFBundleShortVersionString"] as? String ?? "?") (Cirtadev GmbH)"
        // Tells the server (IV_SSO) that Burrow can send the user to a sign-in page and answer CR_TEXT.
        configuration.ssoMethods = "openurl,webauth,crtext"
        // Without this OpenVPN drops the server's INFO messages, which carry CR_TEXT and WEB_AUTH (handleInfo).
        configuration.info = true
        // OpenVPN 3.11 allows only AEAD data channel ciphers (AES-GCM, ChaCha20-Poly1305) unless told otherwise;
        // keep AES-CBC with an HMAC working for older servers, as before. 64-bit block ciphers stay off.
        configuration.enableNonPreferredDCAlgorithms = true
        // Pushed DOMAIN options stay search domains (as with OpenVPN 3.6); the DNS settings below decide
        // what goes to the VPN's DNS servers.
        configuration.dhcpSearchDomainsAsSplitDomains = false
        // OpenVPN 3.11 drops the session when a profile or server uses compression framing (comp-lzo,
        // compress, a pushed compressor) unless compression is allowed. Asymmetric, as OpenVPN 2.6's default
        // and as OpenVPN 3.6 did: decompress what the server sends, never compress what Burrow sends.
        configuration.compressionMode = .asym
        if !profile.keyPassphrase.isEmpty { configuration.privateKeyPassword = profile.keyPassphrase }
        do {
            let evaluation = try adapter.apply(configuration: configuration)
            if evaluation.isPrivateKeyPasswordRequired, profile.keyPassphrase.isEmpty {
                endedAdapters.insert(ObjectIdentifier(adapter))
                finish(TunnelFailure.error(TunnelFailure.passphraseNeeded,
                                           "Enter the private key's passphrase to connect \(profile.name)."))
                return
            }
            if !evaluation.autologin {
                let credentials = OpenVPNCredentials()
                credentials.username = profile.username
                credentials.password = password
                if let challengeReply {
                    // OpenVPN signs in as the cookie's user with "CRV1::<state id>::<answer>".
                    credentials.response = challengeReply.answer
                    credentials.dynamicChallengeCookie = challengeReply.cookie
                } else if let code {
                    if let challenge = evaluation.staticChallenge, !challenge.isEmpty {
                        credentials.response = code
                    } else {
                        credentials.password = password + code
                    }
                }
                // If the server hands out a session token, OpenVPN's reconnects use it instead of the code.
                try adapter.provide(credentials: credentials)
            }
        } catch {
            endedAdapters.insert(ObjectIdentifier(adapter))
            finish(TunnelFailure.error(TunnelFailure.configurationInvalid, "OpenVPN rejected the configuration: \(Self.describe(error))"))
            return
        }
        phase = "Connecting…"
        log.info("connecting\(code != nil || challengeReply != nil ? " with a fresh code" : "", privacy: .public)")
        adapter.connect(using: packetFlow)
    }

    // MARK: - Routes (on `queue`)

    /// The server's routes with the user's choices: "always via the VPN" entries win over a local network of the
    /// same size, "keep local" ones become excluded routes (Settings › Routing). A range shared with the local
    /// network goes through the VPN but for the devices the app found there.
    private func applyRoutes(to ipv4: NEIPv4Settings) {
        let server = serverIncluded.compactMap(Self.network)
        let networks = LocalNetworks.current().map(\.network)
        let plan = RoutePlan.make(pushed: server, viaVPN: IPv4Network.parseList(profile.alwaysViaVPN).networks,
                                  local: IPv4Network.parseList(profile.alwaysLocal).networks,
                                  split: localDevices.filter { networks.contains($0.localNetwork) })
        // Keep the server's route objects (with their gateways) for the routes that stay.
        var included = serverIncluded.filter { route in Self.network(route).map(plan.included.contains) ?? true }
        included += plan.included.filter { !server.contains($0) }.map(Self.route)
        ipv4.includedRoutes = included
        ipv4.excludedRoutes = serverExcluded + plan.excluded.map(Self.route)
        pushedRoutes = server.map(\.description)
        routes = included.compactMap(Self.network).map(\.description)
    }

    /// New choices from Settings while connected: the tunnel takes them at once.
    private func reapplyRoutes() {
        guard let settings = sessionSettings, let ipv4 = settings.ipv4Settings, everConnected else { return }
        applyRoutes(to: ipv4)
        let split = localDevices.map { "\($0.range) (\($0.found.count) local)" }.joined(separator: ", ")
        log.info("routing choices changed: \(self.routes.count) routes\(split.isEmpty ? "" : ", split \(split)", privacy: .public)")
        setTunnelNetworkSettings(settings) { error in
            if let error { self.log.error("could not apply the new routes: \(error.localizedDescription, privacy: .public)") }
        }
    }

    private static func network(_ route: NEIPv4Route) -> IPv4Network? {
        IPv4Network(address: route.destinationAddress, mask: route.destinationSubnetMask)
    }

    private static func route(_ network: IPv4Network) -> NEIPv4Route {
        network.prefix == 0 ? NEIPv4Route.default()
            : NEIPv4Route(destinationAddress: network.addressString, subnetMask: network.maskString)
    }

    // MARK: - Questions from the server (on `queue`)

    /// Shows the question in the app; without an answer in 5 minutes the tunnel gives up.
    private func ask(_ kind: TunnelChallenge.Kind, _ text: String, echo: Bool, responseRequired: Bool) {
        challengeCount += 1
        let question = TunnelChallenge(id: challengeCount, kind: kind, text: text, echo: echo,
                                       responseRequired: responseRequired)
        challenge = question
        phase = "Waiting for your answer…"
        log.info("the server asks: \(text, privacy: .public)")
        queue.asyncAfter(deadline: .now() + 300) {
            guard self.challenge?.id == question.id, !self.stopping else { return }
            self.giveUp(TunnelFailure.error(TunnelFailure.challengeUnanswered,
                                            "The server's question was not answered in time."))
        }
    }

    /// The user's answer, from the app's sign-in window.
    private func answer(_ id: Int, _ response: String) {
        guard let question = challenge, question.id == id, !stopping else { return }
        challenge = nil
        phase = "Checking your answer…"
        switch question.kind {
        case .dynamic:
            challengeAnswer = response
            // The challenged session is over (or ending, and adapterEnded starts the next one).
            if adapter.map({ endedAdapters.contains(ObjectIdentifier($0)) }) ?? true { launchAdapter() }
        case .crText:
            adapter?.sendControlChannelMessage(ServerInfo.crResponse(response))
        }
    }

    private func handleInfo(_ message: String, from openVPNAdapter: OpenVPNAdapter) {
        switch ServerInfo(message) {
        case .webAuth(let url, _):
            // The app opens it in the browser; the server goes on once the user has signed in there.
            webAuthURL = url.absoluteString
            phase = "Finish signing in in your browser…"
        case .crText(let text, _, false):
            // Nothing to type (e.g. "approve the sign-in on your phone"): the server goes on by itself.
            phase = text
        case .crText(let text, let echo, let responseRequired):
            guard profile.answersChallenges else {
                ask(.crText, text, echo: echo, responseRequired: responseRequired)
                return
            }
            phase = "Answering the server's code request…"
            freshCode { code in
                guard openVPNAdapter === self.adapter else { return }
                openVPNAdapter.sendControlChannelMessage(ServerInfo.crResponse(code))
            }
        case .other:
            break
        }
    }

    /// After sleep, a network change or a server-side reconnect. OpenVPN would resend the cached password
    /// with an old code, which the server rejects. With a session token it can resume as is; otherwise
    /// start a new session with a new code (automatic mode) or hand back to the user (prompt mode).
    private func renewSession(_ reason: String) {
        guard let adapter, !stopping, !restarting else { return }
        if adapter.sessionToken != nil {
            log.info("\(reason, privacy: .public): resuming with the session token")
            if reason == "wake" { adapter.resume() } else if reason == "network changed" { adapter.reconnect(afterTimeInterval: 1) }
            return
        }
        restart(reason)
    }

    /// Drop the current OpenVPN session and sign in again, keeping the tunnel up.
    private func restart(_ reason: String) {
        guard !stopping, !restarting, let adapter, !endedAdapters.contains(ObjectIdentifier(adapter)) else { return }
        log.info("restarting: \(reason, privacy: .public)")
        restarting = true
        reasserting = true
        phase = "Reconnecting…"
        adapter.disconnect()
        queue.asyncAfter(deadline: .now() + 5) { self.adapterEnded(adapter) }
    }

    /// Called once per adapter, from its DISCONNECTED event or a fallback timer.
    private func adapterEnded(_ ended: OpenVPNAdapter) {
        let id = ObjectIdentifier(ended)
        guard !endedAdapters.contains(id) else { return }
        endedAdapters.insert(id)
        guard ended === adapter else { return }

        if stopping {
            forgetCredentials()
            stopCompletion?()
            stopCompletion = nil
        } else if restarting {
            restarting = false
            launchAdapter()
        } else {
            finish(pendingError ?? TunnelFailure.error(TunnelFailure.connectionFailed, "The VPN connection ended."))
        }
    }

    /// Ends the tunnel from inside, whatever the adapter is doing.
    private func giveUp(_ error: NSError) {
        if let adapter, !endedAdapters.contains(ObjectIdentifier(adapter)) {
            endedAdapters.insert(ObjectIdentifier(adapter))
            adapter.disconnect()
        }
        finish(error)
    }

    private func finish(_ error: NSError?) {
        reachability.stopTracking()
        forgetCredentials()
        if let completion = startCompletion {
            startCompletion = nil
            completion(error)
        } else {
            cancelTunnelWithError(error)
        }
    }

    // MARK: - OpenVPNAdapterDelegate (called on OpenVPN's threads)

    func openVPNAdapter(_ openVPNAdapter: OpenVPNAdapter,
                        configureTunnelWithNetworkSettings networkSettings: NEPacketTunnelNetworkSettings?,
                        completionHandler: @escaping (Error?) -> Void) {
        guard let networkSettings else {
            // OpenVPN clears the settings when a session ends; keep them through a restart.
            completionHandler(nil)
            return
        }
        let useVPNDNS = queue.sync { self.useVPNDNS }
        if let ipv4 = networkSettings.ipv4Settings {
            let included = ipv4.includedRoutes ?? []
            let excluded = ipv4.excludedRoutes ?? []
            queue.sync {
                self.sessionSettings = networkSettings
                self.serverIncluded = included
                self.serverExcluded = excluded
                self.applyRoutes(to: ipv4)
            }
        }
        if let dns = networkSettings.dnsSettings {
            // The VPN's DNS servers answer every lookup, or only names in the server's split-DNS domains
            // (--dns resolve-domains) and search domains.
            let domains = (dns.matchDomains ?? []) + (dns.searchDomains ?? [])
            if useVPNDNS {
                dns.matchDomains = [""]
            } else if !domains.isEmpty {
                dns.matchDomains = domains
            } else {
                networkSettings.dnsSettings = nil
            }
        }
        setTunnelNetworkSettings(networkSettings, completionHandler: completionHandler)
    }

    func openVPNAdapter(_ openVPNAdapter: OpenVPNAdapter, handleEvent event: OpenVPNAdapterEvent, message: String?) {
        queue.async {
            let shown = Self.loggable(message)
            self.log.info("event \(Self.name(of: event), privacy: .public) \(shown, privacy: .public)")
            self.appendLog("event \(Self.name(of: event)) \(shown)")
            guard openVPNAdapter === self.adapter else {
                if event == .disconnected { self.endedAdapters.insert(ObjectIdentifier(openVPNAdapter)) }
                return
            }
            switch event {
            case .connected:
                self.everConnected = true
                self.authFailures = 0
                self.pendingError = nil
                self.challenge = nil
                self.webAuthURL = nil
                self.phase = "Connected"
                self.reasserting = false
                if let completion = self.startCompletion {
                    self.startCompletion = nil
                    completion(nil)
                }
            case .disconnected:
                self.adapterEnded(openVPNAdapter)
            case .reconnecting:
                if self.everConnected { self.renewSession(message ?? "server asked to reconnect") }
            case .resolve: self.phase = "Looking up the server…"
            case .wait: self.phase = "Waiting for the server…"
            case .connecting: self.phase = "Reaching the server…"
            case .getConfig: self.phase = "Getting settings…"
            case .assignIP: self.phase = "Assigning an address…"
            case .addRoutes: self.phase = "Adding routes…"
            case .authPending: if self.webAuthURL == nil { self.phase = "Waiting for the server to approve…" }
            case .info: if let message { self.handleInfo(message, from: openVPNAdapter) }
            default: break
            }
        }
    }

    func openVPNAdapter(_ openVPNAdapter: OpenVPNAdapter, handleError error: Error) {
        queue.async {
            let nsError = error as NSError
            let fatal = nsError.userInfo[OpenVPNAdapterErrorFatalKey] as? Bool ?? false
            let message = Self.describe(error)
            let dynamicChallenge = nsError.code == OpenVPNAdapterError.dynamicChallenge.rawValue
                ? DynamicChallenge(cookie: message) : nil
            // The challenge cookie carries the server's session state: log only its question.
            let shown = dynamicChallenge.map { "dynamic challenge: \($0.text)" } ?? message
            self.log.error("error (fatal: \(fatal, privacy: .public)) \(shown, privacy: .public)")
            self.appendLog("error \(fatal ? "fatal " : "")\(shown)")
            guard fatal, openVPNAdapter === self.adapter, !self.stopping else { return }

            if let dynamicChallenge {
                // The session ends here; the next one carries the answer (generated, or typed in the app).
                self.challengeCookie = dynamicChallenge.cookie
                self.challengeAnswer = nil
                self.restarting = true
                // Without "R" the question needs no typed answer, but the user still has to say when to go on
                // (e.g. after approving on the phone).
                if self.profile.answersChallenges, dynamicChallenge.responseRequired {
                    self.phase = "Answering the server's code request…"
                } else {
                    self.ask(.dynamic, dynamicChallenge.text, echo: dynamicChallenge.echo,
                             responseRequired: dynamicChallenge.responseRequired)
                }
                self.queue.asyncAfter(deadline: .now() + 3) { self.adapterEnded(openVPNAdapter) }
                return
            }

            if nsError.code == OpenVPNAdapterError.certVerifyFail.rawValue, self.nsCertTypeReplaced {
                self.pendingError = TunnelFailure.error(TunnelFailure.connectionFailed,
                    "The server's certificate has no TLS server key usage. OpenVPN 3 no longer supports the "
                    + "configuration's “ns-cert-type server”, so Burrow checks “remote-cert-tls server”, which needs "
                    + "it. The server's certificate must be reissued with the TLS Web Server Authentication usage.")
            } else if nsError.code == OpenVPNAdapterError.pemPasswordFail.rawValue {
                self.pendingError = TunnelFailure.error(TunnelFailure.passphraseNeeded,
                    "The private key's passphrase is wrong.")
            } else if nsError.code == OpenVPNAdapterError.authFailed.rawValue {
                self.authFailures += 1
                if self.profile.effectiveOTPMode == .off {
                    self.pendingError = TunnelFailure.error(TunnelFailure.credentialsRejected,
                        self.profile.usesPassword ? "The server rejected the username or password." : "The server refused the sign-in.")
                } else if self.profile.otpMode == .prompt {
                    self.pendingError = TunnelFailure.error(TunnelFailure.credentialsRejected,
                        "The server rejected the password or code.")
                } else if self.authFailures < 2 {
                    // Maybe the code expired on the way, or this step was used elsewhere: one more try.
                    self.restart("credentials rejected, trying the next code")
                    return
                } else {
                    self.pendingError = TunnelFailure.error(TunnelFailure.credentialsRejected,
                    "The server rejected the password and code twice. Check them in Settings.")
                }
            } else if nsError.code == OpenVPNAdapterError.sessionExpired.rawValue {
                // OpenVPN 3.11: the server refused the session token and signing in again needs more than the
                // saved password (a web page, a CR_TEXT answer, a typed code). Start over like a new connection.
                self.restart("the server's session expired")
                return
            } else if nsError.code == OpenVPNAdapterError.unusedOptionsError.rawValue {
                // OpenVPN's message lists them by kind ("UNKNOWN/UNSUPPORTED OPTIONS: a,b").
                let options = message.split(whereSeparator: \.isNewline).joined(separator: "; ")
                self.pendingError = TunnelFailure.error(TunnelFailure.configurationInvalid,
                    "OpenVPN 3 can't use some options in this configuration (\(options)). Remove them from the .ovpn "
                    + "file and import it again.")
            } else if nsError.code == OpenVPNAdapterError.ntlmMissingCrypto.rawValue {
                self.pendingError = TunnelFailure.error(TunnelFailure.notConfigured,
                    "The HTTP proxy only accepts an NTLM login, which Burrow can't do. Ask for Digest or Basic "
                    + "login on the proxy, or connect without it.")
            } else if nsError.code == OpenVPNAdapterError.proxyNeedCreds.rawValue {
                self.pendingError = TunnelFailure.error(TunnelFailure.notConfigured,
                    "The HTTP proxy asks for a login: enter its username and password in Settings.")
            } else {
                self.pendingError = TunnelFailure.error(TunnelFailure.connectionFailed, message)
            }
            // A fatal error ends the session; make sure the tunnel finishes even if no event follows.
            self.queue.asyncAfter(deadline: .now() + 3) { self.adapterEnded(openVPNAdapter) }
        }
    }

    func openVPNAdapter(_ openVPNAdapter: OpenVPNAdapter, handleLogMessage logMessage: String) {
        let line = logMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        log.debug("\(line, privacy: .public)")
        queue.async {
            self.appendLog(line)
            // OpenVPN 3 restarts forever, without an error event, when it can't set up the data cipher the server
            // chose: stop with the reason instead.
            if let cipher = OpenVPN3Options.unusableCipher(inLogLine: line), openVPNAdapter === self.adapter,
               !self.stopping, !self.endedAdapters.contains(ObjectIdentifier(openVPNAdapter)) {
                self.log.error("the server's data cipher \(cipher, privacy: .public) is not available")
                self.giveUp(TunnelFailure.error(TunnelFailure.connectionFailed,
                    "The server uses the \(cipher) cipher, which Burrow's VPN engine (OpenVPN 3 with Mbed TLS 3) "
                    + "doesn't support. The server must offer AES-GCM or AES-CBC (its data-ciphers or cipher "
                    + "setting)."))
            }
        }
    }

    // MARK: - Helpers

    /// The tunnel is done: the system extension process lives on, so drop the secrets it was given.
    private func forgetCredentials() {
        profile = VPNProfile()
        password = ""
        typedCode = nil
        challenge = nil
        challengeCookie = nil
        challengeAnswer = nil
        webAuthURL = nil
        sessionSettings = nil
        localDevices = []
    }

    private func appendLog(_ line: String) {
        let stamp = Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute().second())
        recentLog.append("\(stamp) \(line)")
        if recentLog.count > 400 { recentLog.removeFirst(recentLog.count - 400) }
    }

    /// Sign-in page links can carry one-time tokens: the log keeps the page, not its query.
    private static func loggable(_ message: String?) -> String {
        guard let message else { return "" }
        if case .webAuth(let url, _) = ServerInfo(message) {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.query = nil
            components?.fragment = nil
            return "sign-in page \(components?.string ?? url.host() ?? "")"
        }
        return message
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        if let message = nsError.userInfo[OpenVPNAdapterErrorMessageKey] as? String, !message.isEmpty {
            return message
        }
        return nsError.localizedDescription
    }

    private static func name(of event: OpenVPNAdapterEvent) -> String {
        switch event {
        case .disconnected: "DISCONNECTED"
        case .connected: "CONNECTED"
        case .reconnecting: "RECONNECTING"
        case .authPending: "AUTH_PENDING"
        case .resolve: "RESOLVE"
        case .wait: "WAIT"
        case .waitProxy: "WAIT_PROXY"
        case .connecting: "CONNECTING"
        case .getConfig: "GET_CONFIG"
        case .assignIP: "ASSIGN_IP"
        case .addRoutes: "ADD_ROUTES"
        case .echo: "ECHO"
        case .info: "INFO"
        case .warn: "WARN"
        case .pause: "PAUSE"
        case .resume: "RESUME"
        case .relay: "RELAY"
        case .compressionEnabled: "COMPRESSION_ENABLED"
        case .unsupportedFeature: "UNSUPPORTED_FEATURE"
        default: "UNKNOWN"
        }
    }
}
