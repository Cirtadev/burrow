import AppKit
import BurrowKit
import Foundation
import Observation
import Security

/// General preferences in UserDefaults; configurations (with their secrets) in the shared keychain.
@MainActor
@Observable
final class AppSettings {
    @ObservationIgnored private let defaults = UserDefaults.standard

    private(set) var profiles: [VPNProfile] = []
    var selectedProfileID: UUID? {
        didSet { defaults.set(selectedProfileID?.uuidString, forKey: "selectedProfileID") }
    }
    var connectAtLaunch: Bool {
        didSet { defaults.set(connectAtLaunch, forKey: "connectAtLaunch") }
    }
    var keepConnected: Bool {
        didSet { defaults.set(keepConnected, forKey: "keepConnected") }
    }
    /// Send every DNS query through the VPN (its pushed DNS servers) instead of only its own domains.
    var useVPNDNS: Bool {
        didSet { defaults.set(useVPNDNS, forKey: "useVPNDNS") }
    }
    var showNotifications: Bool {
        didSet { defaults.set(showNotifications, forKey: "showNotifications") }
    }

    init() {
        defaults.register(defaults: [
            "connectAtLaunch": true, "keepConnected": true, "useVPNDNS": false, "showNotifications": true,
        ])
        selectedProfileID = defaults.string(forKey: "selectedProfileID").flatMap(UUID.init(uuidString:))
        connectAtLaunch = defaults.bool(forKey: "connectAtLaunch")
        keepConnected = defaults.bool(forKey: "keepConnected")
        useVPNDNS = defaults.bool(forKey: "useVPNDNS")
        showNotifications = defaults.bool(forKey: "showNotifications")
        reloadProfiles()
    }

    func reloadProfiles() {
        do {
            profiles = try ProfileStore.all()
        } catch {
            NSLog("Burrow: could not read profiles: \(error.localizedDescription)")
        }
    }

    /// The chosen configuration, or the first one.
    var selectedProfile: VPNProfile? {
        profiles.first { $0.id == selectedProfileID } ?? profiles.first
    }

    func profile(id: UUID) -> VPNProfile? { profiles.first { $0.id == id } }

    func save(_ profile: VPNProfile) throws {
        try ProfileStore.save(profile)
        var stored = profile
        if !stored.savePassword { stored.password = "" }
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = stored
        } else {
            profiles.append(stored)
            profiles.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    func delete(id: UUID) {
        ProfileStore.delete(id: id)
        profiles.removeAll { $0.id == id }
        if selectedProfileID == id { selectedProfileID = profiles.first?.id }
    }
}

/// Reads Tunnelblick configurations, their saved credentials and whether they used the security-token field.
@MainActor
enum TunnelblickImporter {
    enum ImportError: LocalizedError {
        case cancelled
        case unreadable(String)
        var errorDescription: String? {
            switch self {
            case .cancelled: "Cancelled."
            case .unreadable(let detail): detail
            }
        }
    }

    /// One `VPNProfile` per source. Shared configurations are root-only: macOS asks for an administrator
    /// password once for all of them.
    static func importProfiles(_ sources: [TunnelblickImport.Source]) throws -> [VPNProfile] {
        var files: [String: [String: String]] = [:]
        let adminSources = sources.filter(\.needsAdmin)
        if !adminSources.isEmpty {
            let command = adminSources.map {
                "echo '\(TunnelblickImport.marker)@@SOURCE \($0.path)'; " + TunnelblickImport.dumpCommand(for: $0.path)
            }.joined(separator: "; ")
            let output = try runAsAdministrator(command)
            var current: String?
            var chunk = ""
            for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.hasPrefix(TunnelblickImport.marker + "@@SOURCE ") {
                    if let current { files[current] = TunnelblickImport.parseDump(chunk) }
                    current = String(line.dropFirst((TunnelblickImport.marker + "@@SOURCE ").count))
                    chunk = ""
                } else {
                    chunk += line + "\n"
                }
            }
            if let current { files[current] = TunnelblickImport.parseDump(chunk) }
        }
        return try sources.map { source in
            let config: String?
            if source.needsAdmin {
                config = files[source.path].flatMap(TunnelblickImport.configuration(fromFiles:))
            } else if source.path.hasSuffix(".ovpn") || source.path.hasSuffix(".conf") {
                config = try? String(contentsOfFile: source.path, encoding: .utf8)
            } else {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: source.path)) ?? []
                var local: [String: String] = [:]
                for name in names {
                    local[name] = try? String(contentsOfFile: source.path + "/" + name, encoding: .utf8)
                }
                config = TunnelblickImport.configuration(fromFiles: local)
            }
            guard let config else { throw ImportError.unreadable("Could not read the configuration “\(source.name)”.") }
            let credentials = credentials(named: source.name)
            let usedToken = UserDefaults(suiteName: "net.tunnelblick.tunnelblick")?
                .bool(forKey: "\(source.name)-loginWindowSecurityTokenCheckboxIsChecked") ?? false
            return VPNProfile(
                name: source.name, ovpn: config,
                username: credentials.username ?? "", password: credentials.password ?? "",
                savePassword: credentials.password != nil,
                // With the security-token box ticked, Tunnelblick asked for a code every time; without it, none.
                otpMode: usedToken ? .prompt : .off)
        }
    }

    /// Username and password Tunnelblick saved. macOS asks the user to allow access to each item.
    static func credentials(named name: String) -> (username: String?, password: String?) {
        func read(_ account: String) -> String? {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "Tunnelblick-Auth-" + name,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        return (read("username"), read("password"))
    }

    private static func runAsAdministrator(_ command: String) throws -> String {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        do shell script "\(escaped)" with prompt "Burrow wants to read your Tunnelblick configurations." \
        with administrator privileges without altering line endings
        """
        var error: NSDictionary?
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error) else {
            if (error?[NSAppleScript.errorNumber] as? Int) == -128 { throw ImportError.cancelled }
            throw ImportError.unreadable(error?[NSAppleScript.errorMessage] as? String ?? "Could not read the configurations.")
        }
        return result.stringValue ?? ""
    }
}
