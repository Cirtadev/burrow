import Foundation
import Security

/// One VPN configuration: the OpenVPN config (with its inline keys), the account and how the OTP is obtained.
/// Stored as one item in the app's data-protection keychain group; the tunnel gets it in its start options.
public struct VPNProfile: Codable, Equatable, Sendable, Identifiable {
    public enum OTPMode: String, Codable, Sendable, CaseIterable {
        /// One click: Burrow computes the code from the stored secret. The fastest, but the secret then lives
        /// on the same Mac as the password, so the code no longer proves a second device.
        case automatic
        /// The user types a code from another device each time (recommended).
        case prompt
        /// No one-time password: username/password, certificate only, or whatever the server asks for.
        case off
    }

    /// How the server takes the code.
    public enum CodeDelivery: String, Codable, Sendable, CaseIterable {
        /// Password and code in one field (e.g. "mypassword123456"), what most servers expect.
        case appended
        /// The server asks for the code after checking the password (dynamic challenge or CR_TEXT).
        case challenge
    }

    /// Where the code sent with the password comes from.
    public enum UpFrontCode: Sendable {
        case none
        /// Typed in the sign-in window.
        case typed
        /// Computed from the setup key.
        case generated
    }

    public var id: UUID
    public var name: String
    /// Full `.ovpn` text, including `<ca>`, `<cert>` and `<key>`.
    public var ovpn: String
    public var username: String
    /// Empty when `savePassword` is off.
    public var password: String
    public var savePassword: Bool
    public var otpMode: OTPMode
    /// Base32 secret or `otpauth://totp/…` URI, as entered (automatic mode).
    public var otpSecret: String
    /// Addresses or ranges always routed into the tunnel, as entered ("192.168.1.20, 10.1.0.0/16"). Their
    /// specific routes win when the local network uses the same range as the VPN.
    public var alwaysViaVPN: String
    public var codeDelivery: CodeDelivery
    /// Unlocks an encrypted `<key>`; saved with the password (`savePassword`).
    public var keyPassphrase: String
    /// For an `http-proxy` that asks for a login; saved with the password.
    public var proxyUsername: String
    public var proxyPassword: String
    /// Addresses or ranges kept on the local network even though the VPN routes them (`excludedRoutes`).
    public var alwaysLocal: String

    public init(id: UUID = UUID(), name: String = "", ovpn: String = "", username: String = "", password: String = "",
                savePassword: Bool = true, otpMode: OTPMode = .automatic, otpSecret: String = "",
                alwaysViaVPN: String = "", codeDelivery: CodeDelivery = .appended, keyPassphrase: String = "",
                proxyUsername: String = "", proxyPassword: String = "", alwaysLocal: String = "") {
        self.id = id
        self.name = name
        self.ovpn = ovpn
        self.username = username
        self.password = password
        self.savePassword = savePassword
        self.otpMode = otpMode
        self.otpSecret = otpSecret
        self.alwaysViaVPN = alwaysViaVPN
        self.codeDelivery = codeDelivery
        self.keyPassphrase = keyPassphrase
        self.proxyUsername = proxyUsername
        self.proxyPassword = proxyPassword
        self.alwaysLocal = alwaysLocal
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        ovpn = try container.decode(String.self, forKey: .ovpn)
        username = try container.decode(String.self, forKey: .username)
        password = try container.decode(String.self, forKey: .password)
        savePassword = try container.decodeIfPresent(Bool.self, forKey: .savePassword) ?? true
        otpMode = try container.decodeIfPresent(OTPMode.self, forKey: .otpMode) ?? .automatic
        otpSecret = try container.decodeIfPresent(String.self, forKey: .otpSecret) ?? ""
        alwaysViaVPN = try container.decodeIfPresent(String.self, forKey: .alwaysViaVPN) ?? ""
        codeDelivery = try container.decodeIfPresent(CodeDelivery.self, forKey: .codeDelivery) ?? .appended
        keyPassphrase = try container.decodeIfPresent(String.self, forKey: .keyPassphrase) ?? ""
        proxyUsername = try container.decodeIfPresent(String.self, forKey: .proxyUsername) ?? ""
        proxyPassword = try container.decodeIfPresent(String.self, forKey: .proxyPassword) ?? ""
        alwaysLocal = try container.decodeIfPresent(String.self, forKey: .alwaysLocal) ?? ""
    }

    public var summary: OVPNSummary { OVPNSummary(ovpn) }
    public var hasValidSecret: Bool { (try? TOTP(parsing: otpSecret)) != nil }

    /// The config signs in with a username and password (`auth-user-pass`); otherwise with its certificate only.
    public var usesPassword: Bool { summary.needsUsernamePassword }
    /// A certificate-only config has no password to put a code in.
    public var effectiveOTPMode: OTPMode { usesPassword ? otpMode : .off }

    public var upFrontCode: UpFrontCode {
        guard usesPassword else { return .none }
        // A static challenge asks for the code next to the password, whatever the delivery.
        let withPassword = codeDelivery == .appended || summary.staticChallenge != nil
        switch otpMode {
        case .automatic: return withPassword ? .generated : .none
        case .prompt: return withPassword ? .typed : .none
        case .off: return summary.staticChallenge != nil ? .typed : .none
        }
    }

    /// The sign-in window has to ask for the password.
    public var needsPassword: Bool { usesPassword && (!savePassword || password.isEmpty) }
    /// The sign-in window has to ask for the private key's passphrase.
    public var needsPassphrase: Bool { summary.keyIsEncrypted && (!savePassword || keyPassphrase.isEmpty) }
    /// The sign-in window has to ask for the code (or the static challenge's answer).
    public var needsCode: Bool { upFrontCode == .typed }
    /// The sign-in window opens before connecting (otherwise only if the server asks something).
    public var asksBeforeConnecting: Bool { needsPassword || needsPassphrase || needsCode }
    /// Burrow answers the server's questions (dynamic challenge, CR_TEXT) with a generated code.
    public var answersChallenges: Bool { effectiveOTPMode == .automatic }
    /// Connects without asking anything (unless the server asks a question Burrow can't answer).
    public var isOneClick: Bool {
        !needsPassword && !needsPassphrase && !needsCode && effectiveOTPMode != .prompt
    }

    /// What still has to be filled in before connecting, or nil.
    public var problem: String? {
        if ovpn.isEmpty { return "Import an .ovpn file." }
        if let problem = summary.problem { return problem }
        if usesPassword, username.isEmpty { return "Enter the username." }
        if effectiveOTPMode == .automatic, !hasValidSecret {
            return "Add the setup key, or switch to “Ask me for the code”."
        }
        return nil
    }

    public var isUsable: Bool { problem == nil }
}

/// The few `.ovpn` facts the UI shows and checks.
public struct OVPNSummary: Equatable, Sendable {
    public var remoteHost: String?
    public var remotePort: Int?
    public var proto: String?
    public var needsUsernamePassword = false
    public var hasInlineKey = false
    public var isClient = false
    /// `static-challenge "<text>" <echo> [scrv1|concat]`: the code goes in a field of its own, labelled with this
    /// text, and is sent as SCRV1 or (`concat`, OpenVPN 2.6) appended to the password.
    public var staticChallenge: String?
    public var staticChallengeEcho = false
    public var staticChallengeConcat = false
    /// `http-proxy <host> <port>`; `hasProxyLogin` when the file carries `<http-proxy-user-pass>`.
    public var usesHTTPProxy = false
    public var hasProxyLogin = false
    /// `secret`: static-key mode, which OpenVPN 3 doesn't support.
    public var usesStaticKey = false
    /// The inline `<key>` is encrypted and needs a passphrase.
    public var keyIsEncrypted = false
    /// A `pkcs12` bundle, which OpenVPN 3 with Mbed TLS can't read.
    public var usesPKCS12 = false
    /// Files the config names (`ca ca.crt`) instead of carrying them inline; the tunnel can't read them.
    public var missingFiles: [String] = []

    /// Directives that name a file the tunnel would have to read.
    public static let fileDirectives: Set<String> = [
        "ca", "cert", "key", "tls-auth", "tls-crypt", "tls-crypt-v2", "extra-certs",
    ]

    public init(_ text: String) {
        var inBlock: String?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let block = inBlock {
                if line == "</\(block)>" {
                    inBlock = nil
                } else if block == "key", line.contains("ENCRYPTED") {
                    // "BEGIN ENCRYPTED PRIVATE KEY" (PKCS#8) or "Proc-Type: 4,ENCRYPTED" (traditional PEM)
                    keyIsEncrypted = true
                }
                continue
            }
            if line.hasPrefix("<"), line.hasSuffix(">"), !line.hasPrefix("</") {
                let name = String(line.dropFirst().dropLast())
                if name == "key" { hasInlineKey = true }
                if name == "pkcs12" { usesPKCS12 = true }
                if name == "auth-user-pass" { needsUsernamePassword = true }
                if name == "http-proxy-user-pass" { hasProxyLogin = true }
                inBlock = name
                continue
            }
            guard !line.hasPrefix("#"), !line.hasPrefix(";") else { continue }
            let words = Self.tokens(line)
            guard let keyword = words.first else { continue }
            switch keyword {
            case "client": isClient = true
            case "auth-user-pass": needsUsernamePassword = true
            case "proto": proto = proto ?? words.dropFirst().first
            case "remote" where remoteHost == nil:
                remoteHost = words.count > 1 ? words[1] : nil
                remotePort = words.count > 2 ? Int(words[2]) : nil
                if words.count > 3 { proto = words[3] }
            case "static-challenge" where words.count > 1:
                staticChallenge = words[1]
                staticChallengeEcho = words.count > 2 && words[2] == "1"
                staticChallengeConcat = words.count > 3 && words[3] == "concat"
            case "http-proxy" where words.count > 2:
                usesHTTPProxy = true
            case "secret":
                usesStaticKey = true
            case "askpass":
                keyIsEncrypted = true
            case "pkcs12":
                usesPKCS12 = true
            default:
                break
            }
            // `[inline]` is OpenVPN's marker for a block that follows.
            if Self.fileDirectives.contains(keyword), words.count > 1, words[1] != "[inline]", keyword != "pkcs12" {
                missingFiles.append(words[1])
            }
        }
    }

    /// Splits a config line into words the way OpenVPN does: blanks separate, quotes group, `\` escapes.
    public static func tokens(_ line: String) -> [String] {
        var words: [String] = []
        var word = ""
        var hasWord = false
        var quote: Character?
        var escaped = false
        for character in line {
            if escaped {
                word.append(character)
                escaped = false
            } else if character == "\\", quote != "'" {
                escaped = true
                hasWord = true
            } else if let open = quote {
                if character == open { quote = nil } else { word.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
                hasWord = true
            } else if character == " " || character == "\t" {
                if hasWord || !word.isEmpty { words.append(word) }
                word = ""
                hasWord = false
            } else {
                word.append(character)
            }
        }
        if hasWord || !word.isEmpty { words.append(word) }
        return words
    }

    public var serverDescription: String {
        guard let remoteHost else { return "no server in config" }
        let port = remotePort.map { ":\($0)" } ?? ""
        let transport = proto.map { " (\($0.uppercased()))" } ?? ""
        return remoteHost + port + transport
    }

    /// Why this file can't be used, or nil.
    public var problem: String? {
        if remoteHost == nil { return "The file has no `remote` line." }
        if !isClient { return "The file is not an OpenVPN client config." }
        if usesStaticKey {
            return "Static-key (secret) configurations aren't supported by OpenVPN 3: the server needs TLS (ca, cert, key)."
        }
        if usesPKCS12 {
            return "The PKCS#12 (.p12) certificate isn't converted yet: import the .ovpn again with Import .ovpn File…."
        }
        if let file = missingFiles.first {
            return "The file refers to “\(file)”: import the .ovpn again from the folder that has it."
        }
        return nil
    }
}

public enum ProfileStore {
    public static let service = "dev.cirta.burrow.profile"
    /// The single-profile build stored its item under this account.
    static let legacyAccount = "default"

    public enum StoreError: Error, LocalizedError {
        case keychain(OSStatus)
        public var errorDescription: String? {
            switch self {
            case .keychain(let status):
                "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")"
            }
        }
    }

    private static func query(account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            // The app's first keychain-access-groups entry: team-scoped, so development and Developer ID builds share it.
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    /// Every profile, sorted by name.
    public static func all() throws -> [VPNProfile] {
        var listQuery = query()
        listQuery[kSecReturnAttributes as String] = true
        listQuery[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(listQuery as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { throw StoreError.keychain(status) }
        var profiles: [VPNProfile] = []
        for account in items.compactMap({ $0[kSecAttrAccount as String] as? String }) {
            guard var profile = try read(account: account) else { continue }
            if account == legacyAccount {
                // Move the single-profile item to its own id.
                profile.id = UUID()
                try save(profile)
                SecItemDelete(query(account: legacyAccount) as CFDictionary)
            }
            profiles.append(profile)
        }
        return profiles.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func load(id: UUID) throws -> VPNProfile? {
        try read(account: id.uuidString)
    }

    private static func read(account: String) throws -> VPNProfile? {
        var readQuery = query(account: account)
        readQuery[kSecReturnData as String] = true
        readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(readQuery as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw StoreError.keychain(status) }
        return try JSONDecoder().decode(VPNProfile.self, from: data)
    }

    public static func save(_ profile: VPNProfile) throws {
        var stored = profile
        if !stored.savePassword {
            stored.password = ""
            stored.keyPassphrase = ""
        }
        let data = try JSONEncoder().encode(stored)
        let itemQuery = query(account: profile.id.uuidString)
        let status = SecItemUpdate(itemQuery as CFDictionary, [
            kSecValueData as String: data, kSecAttrLabel as String: "Burrow VPN – \(profile.name)",
        ] as CFDictionary)
        if status == errSecItemNotFound {
            var add = itemQuery
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Burrow VPN – \(profile.name)"
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let added = SecItemAdd(add as CFDictionary, nil)
            guard added == errSecSuccess else { throw StoreError.keychain(added) }
        } else if status != errSecSuccess {
            throw StoreError.keychain(status)
        }
    }

    public static func delete(id: UUID) {
        SecItemDelete(query(account: id.uuidString) as CFDictionary)
    }
}

/// Keys of `startVPNTunnel(options:)` and the provider configuration.
public enum TunnelOption {
    public static let profileID = "profileID"
    public static let name = "name"
    public static let ovpn = "ovpn"
    public static let username = "username"
    /// The saved password, or the one typed in the sign-in window.
    public static let password = "password"
    public static let otpMode = "otpMode"
    /// Automatic mode only.
    public static let otpSecret = "otpSecret"
    /// Code typed in the sign-in window (prompt mode).
    public static let code = "otp"
    public static let alwaysViaVPN = "alwaysViaVPN"
    public static let codeDelivery = "codeDelivery"
    /// The saved passphrase of an encrypted `<key>`, or the one typed in the sign-in window.
    public static let keyPassphrase = "keyPassphrase"
    public static let proxyUsername = "proxyUsername"
    public static let proxyPassword = "proxyPassword"
    public static let alwaysLocal = "alwaysLocal"
    /// Provider configuration (not a start option): not secret, so it lives in the VPN configuration.
    public static let useVPNDNS = "useVPNDNS"
}

/// Everything the tunnel needs to sign in, handed over in `startVPNTunnel(options:)` on every start.
/// The tunnel is a system extension running as root: it can't read the user's keychain, so the app reads the
/// configuration and sends it. The extension keeps it in memory only.
public struct TunnelStartRequest: Equatable, Sendable {
    /// The configuration as sent: the password to use, and the OTP secret only in automatic mode.
    public var profile: VPNProfile
    /// Prompt mode: the code typed for this start.
    public var code: String?

    /// `password`, `passphrase` and `code` come from the sign-in window; without a typed one the saved one is used.
    public init(profile: VPNProfile, password: String? = nil, passphrase: String? = nil, code: String? = nil) {
        var sent = profile
        if let password, !password.isEmpty {
            sent.password = password
        } else if !profile.savePassword {
            sent.password = ""
        }
        if let passphrase, !passphrase.isEmpty {
            sent.keyPassphrase = passphrase
        } else if !profile.savePassword {
            sent.keyPassphrase = ""
        }
        if sent.effectiveOTPMode != .automatic { sent.otpSecret = "" }
        self.profile = sent
        self.code = code.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Nil when the tunnel was started without Burrow's options (from System Settings or the VPN menu).
    public init?(options: [String: NSObject]?) {
        func text(_ key: String) -> String { options?[key] as? String ?? "" }
        guard !text(TunnelOption.ovpn).isEmpty else { return nil }
        profile = VPNProfile(
            id: UUID(uuidString: text(TunnelOption.profileID)) ?? UUID(),
            name: text(TunnelOption.name), ovpn: text(TunnelOption.ovpn), username: text(TunnelOption.username),
            password: text(TunnelOption.password), savePassword: true,
            otpMode: VPNProfile.OTPMode(rawValue: text(TunnelOption.otpMode)) ?? .automatic,
            otpSecret: text(TunnelOption.otpSecret), alwaysViaVPN: text(TunnelOption.alwaysViaVPN),
            codeDelivery: VPNProfile.CodeDelivery(rawValue: text(TunnelOption.codeDelivery)) ?? .appended,
            keyPassphrase: text(TunnelOption.keyPassphrase), proxyUsername: text(TunnelOption.proxyUsername),
            proxyPassword: text(TunnelOption.proxyPassword), alwaysLocal: text(TunnelOption.alwaysLocal))
        code = text(TunnelOption.code).isEmpty ? nil : text(TunnelOption.code)
    }

    public var options: [String: NSObject] {
        var options: [String: NSObject] = [
            TunnelOption.profileID: profile.id.uuidString as NSString,
            TunnelOption.name: profile.name as NSString,
            TunnelOption.ovpn: profile.ovpn as NSString,
            TunnelOption.username: profile.username as NSString,
            TunnelOption.password: profile.password as NSString,
            TunnelOption.otpMode: profile.otpMode.rawValue as NSString,
            TunnelOption.alwaysViaVPN: profile.alwaysViaVPN as NSString,
            TunnelOption.codeDelivery: profile.codeDelivery.rawValue as NSString,
            TunnelOption.keyPassphrase: profile.keyPassphrase as NSString,
            TunnelOption.proxyUsername: profile.proxyUsername as NSString,
            TunnelOption.proxyPassword: profile.proxyPassword as NSString,
            TunnelOption.alwaysLocal: profile.alwaysLocal as NSString,
        ]
        if profile.effectiveOTPMode == .automatic { options[TunnelOption.otpSecret] = profile.otpSecret as NSString }
        if let code { options[TunnelOption.code] = code as NSString }
        return options
    }

    /// Why the tunnel can't connect with this, as a `TunnelFailure` error, or nil.
    public var failure: NSError? {
        if let problem = profile.problem { return TunnelFailure.error(TunnelFailure.notConfigured, problem) }
        if profile.usesPassword, profile.password.isEmpty {
            return TunnelFailure.error(TunnelFailure.passwordNeeded, "Enter the password to connect \(profile.name).")
        }
        if profile.summary.keyIsEncrypted, profile.keyPassphrase.isEmpty {
            return TunnelFailure.error(TunnelFailure.passphraseNeeded,
                                       "Enter the private key's passphrase to connect \(profile.name).")
        }
        if profile.needsCode, code == nil {
            return TunnelFailure.error(TunnelFailure.codeNeeded, "Enter a code to connect \(profile.name).")
        }
        return nil
    }
}

/// What the tunnel extension reports to the app (`NETunnelProviderSession.sendProviderMessage`).
public struct TunnelSnapshot: Codable, Equatable, Sendable {
    public var phase: String
    public var bytesIn: Int64
    public var bytesOut: Int64
    public var tunnelAddress: String?
    public var serverAddress: String?
    public var lastError: String?
    /// IPv4 routes the tunnel set (pushed plus "always send through the VPN"), e.g. "192.168.1.0/24".
    public var routes: [String]?
    /// The server's own IPv4 routes, without Burrow's routing choices.
    public var pushedRoutes: [String]?
    /// The server's question waiting for the user's answer.
    public var challenge: TunnelChallenge?
    /// The page the server wants the user to sign in on (OPEN_URL / WEB_AUTH), while it waits.
    public var webAuthURL: String?

    public init(phase: String, bytesIn: Int64 = 0, bytesOut: Int64 = 0, tunnelAddress: String? = nil,
                serverAddress: String? = nil, lastError: String? = nil, routes: [String]? = nil,
                challenge: TunnelChallenge? = nil, webAuthURL: String? = nil, pushedRoutes: [String]? = nil) {
        self.phase = phase
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.tunnelAddress = tunnelAddress
        self.serverAddress = serverAddress
        self.lastError = lastError
        self.routes = routes
        self.challenge = challenge
        self.webAuthURL = webAuthURL
        self.pushedRoutes = pushedRoutes
    }
}

/// Error codes the extension hands to `cancelTunnelWithError`, readable by the app through
/// `fetchLastDisconnectError`. Codes below 100 mean "don't reconnect automatically".
public enum TunnelFailure {
    public static let domain = "dev.cirta.burrow.tunnel"
    public static let notConfigured = 1
    public static let credentialsRejected = 2
    public static let configurationInvalid = 3
    /// Prompt mode: reconnecting needs a new code from the user.
    public static let codeNeeded = 4
    /// The password is not saved and none was typed.
    public static let passwordNeeded = 5
    /// Started from System Settings or the VPN menu instead of Burrow, so without the sign-in details.
    public static let startedWithoutApp = 6
    /// The encrypted private key's passphrase is not saved, or the key rejected it.
    public static let passphraseNeeded = 7
    /// The server asked a question and nobody answered it in time.
    public static let challengeUnanswered = 8
    public static let connectionFailed = 100

    public static func error(_ code: Int, _ message: String) -> NSError {
        NSError(domain: domain, code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }

    public static var startedWithoutAppError: NSError {
        error(startedWithoutApp, "Open Burrow to connect: the VPN gets its sign-in details from Burrow's menu-bar app.")
    }

    public static func allowsReconnect(_ error: NSError?) -> Bool {
        guard let error, error.domain == domain else { return true }
        return error.code >= 100
    }
}
