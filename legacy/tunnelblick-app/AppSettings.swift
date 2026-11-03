import BurrowKit
import Foundation
import Observation
import Security

struct Credentials: Codable, Equatable {
    var username = ""
    var password = ""
    /// Base32 secret or `otpauth://totp/…` URI, as entered.
    var otpSecret = ""

    var isComplete: Bool { !username.isEmpty && !password.isEmpty && !otpSecret.isEmpty }
}

/// Non-secret preferences in UserDefaults; credentials in one login-keychain item per configuration.
@MainActor
@Observable
final class AppSettings {
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var credentialCache: [String: Credentials] = [:]

    var selectedConfigurationID: String? {
        didSet { defaults.set(selectedConfigurationID, forKey: "selectedConfigurationID") }
    }
    var connectAtLaunch: Bool {
        didSet { defaults.set(connectAtLaunch, forKey: "connectAtLaunch") }
    }
    var keepConnected: Bool {
        didSet { defaults.set(keepConnected, forKey: "keepConnected") }
    }
    @ObservationIgnored var lastUsedOTPCounter: UInt64? {
        get { (defaults.object(forKey: "lastUsedOTPCounter") as? NSNumber)?.uint64Value }
        set { defaults.set(newValue.map { NSNumber(value: $0) }, forKey: "lastUsedOTPCounter") }
    }

    init() {
        defaults.register(defaults: ["connectAtLaunch": true, "keepConnected": true])
        selectedConfigurationID = defaults.string(forKey: "selectedConfigurationID")
        connectAtLaunch = defaults.bool(forKey: "connectAtLaunch")
        keepConnected = defaults.bool(forKey: "keepConnected")
    }

    var configurations: [TunnelblickConfiguration] { Tunnelblick.configurations() }

    /// The chosen configuration, or the only one there is.
    var selectedConfiguration: TunnelblickConfiguration? {
        let all = configurations
        return all.first { $0.id == selectedConfigurationID } ?? (all.count == 1 ? all.first : nil)
    }

    var isReady: Bool {
        guard let configuration = selectedConfiguration else { return false }
        return credentials(for: configuration)?.isComplete == true
    }

    func credentials(for configuration: TunnelblickConfiguration) -> Credentials? {
        if let cached = credentialCache[configuration.id] { return cached }
        guard let data = Keychain.read(service: Keychain.burrowService, account: configuration.id),
              let credentials = try? JSONDecoder().decode(Credentials.self, from: data) else { return nil }
        credentialCache[configuration.id] = credentials
        return credentials
    }

    func save(_ credentials: Credentials, for configuration: TunnelblickConfiguration) {
        credentialCache[configuration.id] = credentials
        let data = try? JSONEncoder().encode(credentials)
        Keychain.write(data, service: Keychain.burrowService, account: configuration.id)
    }

    /// Username and password Tunnelblick saved for this configuration. macOS asks the user to allow it.
    func tunnelblickCredentials(for configuration: TunnelblickConfiguration) -> (username: String?, password: String?) {
        let service = "Tunnelblick-Auth-" + configuration.displayName
        let read = { (account: String) in
            Keychain.read(service: service, account: account).flatMap { String(data: $0, encoding: .utf8) }
        }
        return (read("username"), read("password"))
    }
}

enum Keychain {
    static let burrowService = "dev.cirta.burrow"

    static func read(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func write(_ data: Data?, service: String, account: String) {
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        guard let data else {
            SecItemDelete(item as CFDictionary)
            return
        }
        let update = [kSecValueData as String: data]
        if SecItemUpdate(item as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var add = item
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Burrow VPN credentials"
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

/// Port and management password of the running tunnel, so a relaunched Burrow can re-attach.
/// Same exposure as the management socket itself: only this user can read it.
enum SessionFile {
    struct Contents: Codable {
        var configurationID: String
        var port: UInt16
        var managementPassword: String
    }

    static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Burrow/session.json")
    }

    static func load() -> Contents? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Contents.self, from: data)
    }

    static func save(_ contents: Contents) {
        let folder = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(contents) else { return }
        clear()
        FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
