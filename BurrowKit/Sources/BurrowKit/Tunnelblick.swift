import Foundation

/// A Tunnelblick VPN configuration that tunnelblickd is allowed to start: a secured `.tblk`
/// in Tunnelblick's Shared folder or in the per-user shadow folder.
public struct TunnelblickConfiguration: Sendable, Hashable, Identifiable, Codable {
    public enum Location: Int, Sendable, Codable {
        /// `/Library/Application Support/Tunnelblick/Users/<user>` (secured copies of private configs).
        case alternate = 1
        /// `/Library/Application Support/Tunnelblick/Shared`.
        case shared = 3
    }

    public let displayName: String
    public let location: Location
    public let tblkPath: String

    public init(displayName: String, location: Location, tblkPath: String) {
        self.displayName = displayName
        self.location = location
        self.tblkPath = tblkPath
    }

    public var id: String { "\(location.rawValue):\(displayName)" }
    public var tblkName: String { (tblkPath as NSString).lastPathComponent }
    public var resourcesPath: String { tblkPath + "/Contents/Resources" }
}

/// Options for `tunnelblick-helper start`. Defaults are what Tunnelblick 8.0 sent for the user's
/// config (see re/REA-FINDINGS.md §3), i.e. Tunnelblick's own defaults for a TUN config on modern macOS.
public struct StartOptions: Sendable, Equatable {
    /// Bit 0: run Tunnelblick's up/down scripts; bits 8-11: `--verb` level.
    public var useScripts: UInt32 = 0x0000_0301
    public var skipScriptSecurity = false
    public var noMonitor = false
    /// Bits 4, 5 (restore DNS/WINS on reset), 8 (flush DNS cache), 14 (GUI: management hold + query
    /// passwords), 15 (`--route-up`), 20 (disable IPv6 on TUN), 25 (Big Sur or newer).
    public var bitMask: UInt32 = 0x0210_C130
    public var leasewatchOptions = "-ptADGNWradsgnw"
    /// Subfolder of Tunnelblick's `openvpn` folder without the `openvpn-` prefix; nil = Tunnelblick's default.
    public var openvpnVersion: String?

    public init() {}
}

public enum Tunnelblick {
    public static let bundleIdentifier = "net.tunnelblick.tunnelblick"
    public static let supportFolder = "/Library/Application Support/Tunnelblick"
    public static let sharedFolder = supportFolder + "/Shared"
    public static let usersFolder = supportFolder + "/Users"
    public static let logsFolder = supportFolder + "/Logs"
    public static let expectDisconnectFolder = supportFolder + "/expect-disconnect"
    public static let appResources = supportFolder + "/Tunnelblick.app/Contents/Resources"
    public static let openvpnFolder = appResources + "/openvpn"

    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: appResources + "/tunnelblick-helper")
    }

    /// Configurations tunnelblickd can start for `userName`, sorted by name.
    public static func configurations(userName: String = NSUserName()) -> [TunnelblickConfiguration] {
        func scan(_ folder: String, _ location: TunnelblickConfiguration.Location) -> [TunnelblickConfiguration] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            return names.filter { $0.hasSuffix(".tblk") }.map {
                TunnelblickConfiguration(
                    displayName: String($0.dropLast(5)), location: location, tblkPath: folder + "/" + $0)
            }
        }
        let all = scan(sharedFolder, .shared) + scan(usersFolder + "/" + userName, .alternate)
        return all.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// The version Tunnelblick uses by default: the target of `openvpn/default`, minus `openvpn-`.
    public static func defaultOpenVPNVersion() -> String? {
        let link = openvpnFolder + "/default"
        if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link),
           let folder = target.split(separator: "/").first, folder.hasPrefix("openvpn-") {
            return String(folder.dropFirst("openvpn-".count))
        }
        let folders = ((try? FileManager.default.contentsOfDirectory(atPath: openvpnFolder)) ?? [])
            .filter { $0.hasPrefix("openvpn-") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return folders.last.map { String($0.dropFirst("openvpn-".count)) }
    }

    /// Tunnelblick's filename encoding for paths: `-` → `--`, `.` → `-D`, `/` → `-S`.
    public static func encodeSlashesAndPeriods(_ path: String) -> String {
        path.replacingOccurrences(of: "-", with: "--")
            .replacingOccurrences(of: ".", with: "-D")
            .replacingOccurrences(of: "/", with: "-S")
    }

    static func hex(_ value: UInt32) -> String { String(format: "0x%08x", value) }

    public static func startArguments(
        for configuration: TunnelblickConfiguration,
        port: UInt16,
        managementPassword: String,
        options: StartOptions = StartOptions()
    ) -> [String] {
        [
            "start",
            configuration.tblkName,
            String(port),
            hex(options.useScripts),
            options.skipScriptSecurity ? "1" : "0",
            String(configuration.location.rawValue),
            options.noMonitor ? "1" : "0",
            hex(options.bitMask),
            options.leasewatchOptions,
            options.openvpnVersion ?? defaultOpenVPNVersion() ?? "",
            managementPassword,
        ]
    }

    public static func expectDisconnectArguments(for configuration: TunnelblickConfiguration) -> [String] {
        ["expectDisconnect", "1", encodeSlashesAndPeriods(configuration.resourcesPath)]
    }

    public static func killArguments(pid: Int32) -> [String] { ["kill", String(pid)] }

    /// The OpenVPN log for a running connection: tunnelblick-helper names it
    /// `<encoded config path>.<start args>.<port>.openvpn.log`.
    public static func openVPNLog(port: UInt16) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: logsFolder)) ?? []
        return names.first { $0.hasSuffix(".\(port).openvpn.log") }
            .map { URL(fileURLWithPath: logsFolder).appendingPathComponent($0) }
    }

    /// 64 random letters and digits: no tabs, spaces or quotes, well under the helper's 127-byte limit.
    public static func makeManagementPassword() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        var generator = SystemRandomNumberGenerator()
        return String((0..<64).map { _ in alphabet.randomElement(using: &generator)! })
    }
}
