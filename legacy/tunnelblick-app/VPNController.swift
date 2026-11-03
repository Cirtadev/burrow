import AppKit
import BurrowKit
import Observation

/// Drives one Tunnelblick configuration without Tunnelblick.app: tunnelblickd starts OpenVPN, and
/// Burrow answers OpenVPN's management interface itself, appending a fresh TOTP code to the password.
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

    private(set) var status: Status = .disconnected
    private(set) var bytesReceived: UInt64 = 0
    private(set) var bytesSent: UInt64 = 0
    private(set) var activeConfiguration: TunnelblickConfiguration?
    private(set) var logURL: URL?

    @ObservationIgnored var onNeedsSetup: (() -> Void)?
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let daemon = TunnelblickDaemon()
    @ObservationIgnored private var session: Session?
    @ObservationIgnored private var scheduler: OTPScheduler
    /// The user wants the tunnel up: set by connect, cleared by disconnect and by rejected credentials.
    @ObservationIgnored private var wantsConnection = false
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectDelay: TimeInterval = 5
    @ObservationIgnored private var credentialsTask: Task<Void, Never>?
    @ObservationIgnored private var disconnectCompletions: [() -> Void] = []
    @ObservationIgnored private var sleptAt: Date?

    private final class Session {
        let configuration: TunnelblickConfiguration
        let port: UInt16
        let managementPassword: String
        /// Started by this process (as opposed to re-attached after a relaunch).
        let isNew: Bool
        var credentials: Credentials?
        var connection: ManagementConnection?
        var pid: Int32?
        var openAttempts = 0
        var authFailures = 0
        var everConnected = false
        var stopping = false
        var stopReason: String?
        var lastFatal: String?
        var stopTask: Task<Void, Never>?

        init(configuration: TunnelblickConfiguration, port: UInt16, managementPassword: String, isNew: Bool,
             credentials: Credentials?) {
            self.configuration = configuration
            self.port = port
            self.managementPassword = managementPassword
            self.isNew = isNew
            self.credentials = credentials
        }
    }

    init(settings: AppSettings) {
        self.settings = settings
        scheduler = OTPScheduler(lastUsedCounter: settings.lastUsedOTPCounter)
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sleptAt = .now }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemDidWake() }
        }
    }

    var hasSession: Bool { session != nil }

    var tunnelblickIsRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Tunnelblick.bundleIdentifier).isEmpty
    }

    // MARK: - Commands

    /// Re-attaches to a tunnel left running by a previous launch, or connects if the user asked for that.
    func start() {
        if let saved = SessionFile.load() {
            if !Processes.pids(named: "openvpn").isEmpty,
               let configuration = Tunnelblick.configurations().first(where: { $0.id == saved.configurationID }) {
                let session = Session(
                    configuration: configuration, port: saved.port, managementPassword: saved.managementPassword,
                    isNew: false, credentials: settings.credentials(for: configuration))
                begin(session)
                wantsConnection = true
                status = .connecting("Re-attaching…")
                openManagement(session)
                return
            }
            SessionFile.clear()
        }
        if settings.connectAtLaunch, settings.isReady { connect() }
    }

    func toggle() {
        switch status {
        case .connected, .connecting: disconnect()
        case .disconnecting: break
        case .disconnected, .failed: connect()
        }
    }

    func connect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        guard session == nil else { return }
        guard Tunnelblick.isInstalled, daemon.isAvailable else {
            status = .failed("Tunnelblick is not installed; Burrow uses its helper to start OpenVPN.")
            return
        }
        guard let configuration = settings.selectedConfiguration else {
            status = .failed("Choose a Tunnelblick configuration in Settings.")
            onNeedsSetup?()
            return
        }
        guard let credentials = settings.credentials(for: configuration), credentials.isComplete else {
            status = .failed("Add your username, password and OTP secret in Settings.")
            onNeedsSetup?()
            return
        }
        let totp: TOTP
        do {
            totp = try TOTP(parsing: credentials.otpSecret)
        } catch {
            status = .failed("OTP secret: \(error.localizedDescription)")
            onNeedsSetup?()
            return
        }
        guard ManagementCommand.fitsLimit(credentials.username),
              ManagementCommand.fitsLimit(credentials.password + totp.code(at: .now)) else {
            status = .failed("Username or password is too long for OpenVPN (250 bytes).")
            return
        }
        guard Processes.pids(named: "openvpn").isEmpty else {
            status = .failed("Another OpenVPN connection is running (Tunnelblick?). Disconnect it first.")
            return
        }
        let port: UInt16
        do {
            port = try LocalPort.free()
        } catch {
            status = .failed("No free local port: \(error.localizedDescription)")
            return
        }

        let session = Session(
            configuration: configuration, port: port, managementPassword: Tunnelblick.makeManagementPassword(),
            isNew: true, credentials: credentials)
        begin(session)
        wantsConnection = true
        status = .connecting("Starting OpenVPN…")

        let arguments = Tunnelblick.startArguments(
            for: configuration, port: port, managementPassword: session.managementPassword)
        let daemon = self.daemon
        Task {
            let result = await Task.detached { Result { try daemon.run(arguments) } }.value
            guard self.session === session else { return }
            switch result {
            case .success(let reply) where reply.status == 0:
                SessionFile.save(.init(
                    configurationID: configuration.id, port: port, managementPassword: session.managementPassword))
                self.logURL = Tunnelblick.openVPNLog(port: port)
                self.openManagement(session)
            case .success(let reply):
                let detail = reply.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    .components(separatedBy: .newlines).last ?? ""
                self.end(session, failure: "Tunnelblick could not start OpenVPN (status \(reply.status)). \(detail)")
            case .failure(let error):
                self.end(session, failure: error.localizedDescription)
            }
        }
    }

    func disconnect(then completion: (() -> Void)? = nil) {
        wantsConnection = false
        reconnectTask?.cancel()
        reconnectTask = nil
        guard let session else {
            if case .connecting = status { status = .disconnected }
            completion?()
            return
        }
        if let completion { disconnectCompletions.append(completion) }
        stop(session, reason: nil)
    }

    /// The code that would be sent right now, for "Copy OTP Code".
    func currentCode() -> (code: String, secondsLeft: Int)? {
        guard let configuration = activeConfiguration ?? settings.selectedConfiguration,
              let secret = settings.credentials(for: configuration)?.otpSecret,
              let totp = try? TOTP(parsing: secret) else { return nil }
        return (totp.code(at: .now), totp.secondsRemaining(at: .now))
    }

    /// Settings changed: forget cached credentials of a running session so a re-prompt uses the new ones.
    func credentialsChanged() {
        guard let session else { return }
        session.credentials = settings.credentials(for: session.configuration)
    }

    // MARK: - Session lifecycle

    private func begin(_ session: Session) {
        self.session = session
        activeConfiguration = session.configuration
        bytesReceived = 0
        bytesSent = 0
        logURL = Tunnelblick.openVPNLog(port: session.port)
    }

    private func openManagement(_ session: Session) {
        let connection = ManagementConnection(port: session.port)
        session.connection = connection
        connection.onEvent = { [weak self, weak session] event in
            guard let self, let session, self.session === session else { return }
            self.handle(event, in: session)
        }
        connection.open()
    }

    private func handle(_ event: ManagementConnection.Event, in session: Session) {
        switch event {
        case .ready:
            session.openAttempts = 0
            let connection = session.connection
            connection?.send(session.managementPassword)
            connection?.send("pid")
            connection?.send("auth-retry interact")
            connection?.send("state on")
            connection?.send("state")
            connection?.send("bytecount 1")

        case .closed(_, let reason):
            session.connection = nil
            let processAlive = session.pid.map(Processes.isAlive) ?? !Processes.pids(named: "openvpn").isEmpty
            if session.stopping {
                // Otherwise the stop loop notices within a second.
                if !processAlive { end(session, failure: nil) }
            } else if !processAlive {
                end(session, failure: session.lastFatal
                    ?? (session.everConnected ? "OpenVPN stopped." : "OpenVPN exited while connecting."))
            } else if session.openAttempts < 40 {
                // OpenVPN is not listening yet, or the socket dropped while OpenVPN still runs: try again.
                session.openAttempts += 1
                Task {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard self.session === session, !session.stopping else { return }
                    self.openManagement(session)
                }
            } else if session.isNew {
                stop(session, reason: "Could not reach OpenVPN's management interface (\(reason ?? "no reason")).")
            } else {
                end(session, failure: "Could not re-attach to the running OpenVPN connection.")
            }

        case .message(let message):
            handle(message, in: session)
        }
    }

    private func handle(_ message: ManagementMessage, in session: Session) {
        switch message {
        case .hold:
            session.connection?.send("hold release")
        case .pid(let pid):
            session.pid = pid
        case .needPassword(let request) where request.type == "Auth":
            provideCredentials(request, in: session)
        case .needPassword(let request):
            stop(session, reason: "OpenVPN asked for a '\(request.type)' password, which Burrow does not handle.")
        case .verificationFailed(_, let detail) where detail.contains("CRV1"):
            wantsConnection = false
            stop(session, reason: "The server asked for a dynamic challenge, which Burrow does not handle.")
        case .verificationFailed:
            session.authFailures += 1
            if session.authFailures >= 2 {
                wantsConnection = false
                stop(session, reason: "The server rejected the password and code twice. Check them in Settings.")
            } else {
                status = .connecting("Code rejected; trying the next one…")
            }
        case .state(let update):
            apply(update, in: session)
        case .byteCount(let received, let sent):
            bytesReceived = received
            bytesSent = sent
        case .fatal(let text):
            session.lastFatal = text
        default:
            break
        }
    }

    private func apply(_ update: StateUpdate, in session: Session) {
        guard !session.stopping else { return }
        switch update.name {
        case "CONNECTED":
            status = .connected(since: update.time ?? .now, address: update.localIP)
            session.everConnected = true
            session.authFailures = 0
            reconnectDelay = 5
            logURL = Tunnelblick.openVPNLog(port: session.port)
            // Without auth-nocache OpenVPN would replay the cached (now stale) code after a restart.
            session.connection?.send("forget-passwords")
        case "RECONNECTING":
            status = .connecting("Reconnecting (\(update.detail))…")
        case "EXITING":
            status = .disconnecting
        default:
            status = .connecting(Self.describe(update.name))
        }
    }

    private func provideCredentials(_ request: PasswordRequest, in session: Session) {
        credentialsTask?.cancel()
        guard let credentials = session.credentials, credentials.isComplete,
              let totp = try? TOTP(parsing: credentials.otpSecret) else {
            wantsConnection = false
            stop(session, reason: "Add your username, password and OTP secret in Settings.")
            onNeedsSetup?()
            return
        }
        switch scheduler.decide(totp, now: .now) {
        case .wait(let delay):
            status = .connecting("Waiting \(Int(delay.rounded(.up))) s for a fresh code…")
            credentialsTask = Task {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, self.session === session, !session.stopping else { return }
                self.provideCredentials(request, in: session)
            }
        case .send(let code, let counter):
            scheduler.markUsed(counter)
            settings.lastUsedOTPCounter = scheduler.lastUsedCounter
            session.connection?.send(ManagementCommand.username(credentials.username))
            if request.staticChallenge != nil {
                session.connection?.send(ManagementCommand.staticChallengeResponse(
                    password: credentials.password, response: code))
            } else {
                session.connection?.send(ManagementCommand.password(credentials.password + code))
            }
            status = .connecting("Signing in…")
        }
    }

    /// Tunnelblick's disconnect: mark it expected, then `signal SIGTERM` every second; after 15 s, or
    /// without a management connection, ask tunnelblick-helper to kill the process.
    private func stop(_ session: Session, reason: String?) {
        credentialsTask?.cancel()
        guard !session.stopping else { return }
        session.stopping = true
        session.stopReason = reason
        status = .disconnecting

        let configuration = session.configuration
        let daemon = self.daemon
        session.stopTask = Task {
            _ = await Task.detached { try? daemon.run(Tunnelblick.expectDisconnectArguments(for: configuration)) }.value
            for second in 0..<20 {
                guard self.session === session else { return }
                if second < 15, let connection = session.connection, connection.isReady {
                    connection.send("signal SIGTERM")
                } else {
                    let pids = session.pid.map { [$0] } ?? (session.isNew ? Processes.pids(named: "openvpn") : [])
                    let alive = pids.filter(Processes.isAlive)
                    if alive.isEmpty {
                        self.end(session, failure: nil)
                        return
                    }
                    for pid in alive {
                        _ = await Task.detached { try? daemon.run(Tunnelblick.killArguments(pid: pid)) }.value
                    }
                }
                try? await Task.sleep(for: .seconds(1))
            }
            self.end(session, failure: "OpenVPN did not stop.")
        }
    }

    private func end(_ session: Session, failure: String?) {
        guard self.session === session else { return }
        session.stopTask?.cancel()
        credentialsTask?.cancel()
        session.connection?.onEvent = nil
        session.connection?.close()
        self.session = nil
        SessionFile.clear()

        if let message = session.stopReason ?? failure {
            status = .failed(message)
        } else {
            status = .disconnected
        }
        let completions = disconnectCompletions
        disconnectCompletions = []
        completions.forEach { $0() }

        // Reconnect only a tunnel that worked and dropped, not one that never came up.
        if !session.stopping, session.everConnected, wantsConnection, settings.keepConnected {
            scheduleReconnect()
        }
    }

    private func scheduleReconnect() {
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 120)
        status = .connecting("Connection lost; reconnecting in \(Int(delay)) s…")
        reconnectTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, self.session == nil, self.wantsConnection else { return }
            self.connect()
        }
    }

    private func systemDidWake() {
        let slept = sleptAt.map { Date.now.timeIntervalSince($0) } ?? 0
        sleptAt = nil
        guard settings.keepConnected else { return }
        if let session, !session.stopping, session.everConnected, slept > 30 {
            // The TCP session is probably dead; restart now instead of waiting for ping-restart.
            session.connection?.send("signal SIGUSR1")
        } else if session == nil, wantsConnection {
            reconnectTask?.cancel()
            reconnectTask = Task {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, self.session == nil, self.wantsConnection else { return }
                self.connect()
            }
        }
    }

    static func describe(_ state: String) -> String {
        switch state {
        case "CONNECTING": "Connecting…"
        case "RESOLVE": "Looking up the server…"
        case "TCP_CONNECT": "Reaching the server…"
        case "WAIT": "Waiting for the server…"
        case "AUTH": "Signing in…"
        case "AUTH_PENDING": "Waiting for the server to approve…"
        case "GET_CONFIG": "Getting settings…"
        case "ASSIGN_IP": "Assigning an address…"
        case "ADD_ROUTES": "Adding routes…"
        default: "\(state.capitalized)…"
        }
    }
}
