import Darwin
import Foundation

/// An IPv4 address range, e.g. `192.168.1.0/24`, or a single host `192.168.1.20` (/32).
public struct IPv4Network: Equatable, Hashable, Sendable, CustomStringConvertible {
    /// Network address, host byte order, host bits cleared.
    public let address: UInt32
    public let prefix: Int

    public init(address: UInt32, prefix: Int) {
        let prefix = min(max(prefix, 0), 32)
        self.prefix = prefix
        self.address = address & Self.mask(prefix)
    }

    /// `"192.168.1.20"`, `"192.168.1.0/24"`; whitespace around it is ignored.
    public init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let address = Self.parse(String(parts[0])) else { return nil }
        var prefix = 32
        if parts.count == 2 {
            guard let value = Int(parts[1]), (0...32).contains(value) else { return nil }
            prefix = value
        }
        self.init(address: address, prefix: prefix)
    }

    /// From an address and a dotted subnet mask, as NetworkExtension routes carry them.
    public init?(address: String, mask: String) {
        guard let address = Self.parse(address), let mask = Self.parse(mask) else { return nil }
        self.init(address: address, prefix: mask.nonzeroBitCount)
    }

    public var mask: UInt32 { Self.mask(prefix) }
    public var addressString: String { Self.format(address) }
    public var maskString: String { Self.format(mask) }
    public var description: String { prefix == 32 ? addressString : "\(addressString)/\(prefix)" }

    public func overlaps(_ other: IPv4Network) -> Bool {
        let shared = Self.mask(min(prefix, other.prefix))
        return address & shared == other.address & shared
    }

    /// `other` lies entirely inside this range.
    public func contains(_ other: IPv4Network) -> Bool {
        other.prefix >= prefix && other.address & mask == address
    }

    /// The two ranges one bit narrower: together the same addresses, but they win over a route as wide as this one.
    public var halves: [IPv4Network] {
        guard prefix < 32 else { return [self] }
        return [IPv4Network(address: address, prefix: prefix + 1),
                IPv4Network(address: address | (1 << UInt32(31 - prefix)), prefix: prefix + 1)]
    }

    /// This range without `holes`, as few ranges as possible.
    public func subtracting(_ holes: [IPv4Network]) -> [IPv4Network] {
        let inside = holes.filter(overlaps)
        if inside.isEmpty { return [self] }
        if inside.contains(where: { $0.contains(self) }) { return [] }
        return halves.flatMap { $0.subtracting(inside) }
    }

    /// Splits a list separated by commas, spaces or new lines into ranges, and the entries that aren't one.
    public static func parseList(_ text: String) -> (networks: [IPv4Network], invalid: [String]) {
        var networks: [IPv4Network] = []
        var invalid: [String] = []
        for entry in text.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace }) {
            if let network = IPv4Network(String(entry)) {
                if !networks.contains(network) { networks.append(network) }
            } else {
                invalid.append(String(entry))
            }
        }
        return (networks, invalid)
    }

    static func mask(_ prefix: Int) -> UInt32 { prefix == 0 ? 0 : UInt32.max << UInt32(32 - prefix) }

    static func parse(_ text: String) -> UInt32? {
        let octets = text.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return nil }
        var value: UInt32 = 0
        for octet in octets {
            guard let byte = UInt8(octet) else { return nil }
            value = value << 8 | UInt32(byte)
        }
        return value
    }

    static func format(_ value: UInt32) -> String {
        [24, 16, 8, 0].map { String(value >> UInt32($0) & 0xff) }.joined(separator: ".")
    }
}

/// A VPN route that the network the Mac is on also uses, so macOS sends that traffic to the local network.
public struct RouteClash: Equatable, Sendable {
    public let vpnRoute: IPv4Network
    public let localNetwork: IPv4Network
    public let interface: String

    /// The addresses both use: the narrower of the two (CIDR ranges that overlap are inside one another).
    public var shared: IPv4Network { vpnRoute.prefix >= localNetwork.prefix ? vpnRoute : localNetwork }

    /// Small enough for Burrow to look for the devices in it on the local network and send the rest through the VPN.
    public var splittable: Bool { shared.prefix >= LocalDevices.smallestPrefix }

    /// VPN routes that overlap a local network. Host routes (/32, e.g. from "always send through the VPN")
    /// win over the local network and don't count, nor do routes so wide they're a default route.
    public static func find(vpnRoutes: [IPv4Network], local: [(interface: String, network: IPv4Network)]) -> [RouteClash] {
        var clashes: [RouteClash] = []
        for route in vpnRoutes where route.prefix > 1 && route.prefix < 32 {
            for entry in local where entry.network.overlaps(route) {
                clashes.append(RouteClash(vpnRoute: route, localNetwork: entry.network, interface: entry.interface))
            }
        }
        return clashes
    }
}

public enum LocalNetworks {
    /// IPv4 networks of the Mac's active interfaces, without loopback and tunnels.
    public static func current() -> [(interface: String, network: IPv4Network)] {
        interfaces().map { ($0.name, IPv4Network(address: $0.address, prefix: $0.mask.nonzeroBitCount)) }
    }

    /// The Mac's own IPv4 addresses on an interface.
    public static func addresses(on interface: String) -> [UInt32] {
        interfaces().filter { $0.name == interface }.map(\.address)
    }

    private static func interfaces() -> [(name: String, address: UInt32, mask: UInt32)] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [(name: String, address: UInt32, mask: UInt32)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, flags & IFF_POINTOPOINT == 0,
                  let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  let netmask = entry.ifa_netmask else { continue }
            let name = String(cString: entry.ifa_name)
            guard !name.hasPrefix("utun"), !name.hasPrefix("ipsec"), !name.hasPrefix("ppp") else { continue }
            let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            result.append((name, ip, mask))
        }
        return result
    }
}

/// The tunnel's IPv4 routes after the user's routing choices.
public enum RoutePlan {
    /// `pushed`: the server's routes. `viaVPN` entries win over a local network of the same size (a range is sent
    /// as its two halves); `local` entries go to `excludedRoutes`, and the server's routes inside them are dropped.
    /// `split`: shared ranges left on automatic. The devices found on the local network stay there, every other
    /// address of the range goes through the VPN.
    public static func make(pushed: [IPv4Network], viaVPN: [IPv4Network], local: [IPv4Network],
                            split: [LocalDevices] = []) -> (included: [IPv4Network], excluded: [IPv4Network]) {
        // A choice for the whole range (or a wider one) wins over automatic.
        let decided = viaVPN + local
        var found: [IPv4Network: [IPv4Network]] = [:]
        for scan in split where !decided.contains(where: { $0.contains(scan.range) }) {
            found[scan.range, default: []] += scan.found + scan.edges
        }
        var included = pushed.filter { route in
            !local.contains { $0.contains(route) } && !found.keys.contains { $0.contains(route) }
        }
        for network in viaVPN {
            for part in network.halves where !included.contains(part) { included.append(part) }
        }
        for (range, holes) in found.sorted(by: { $0.key.address < $1.key.address }) {
            for part in range.subtracting(holes + local) where !included.contains(part) { included.append(part) }
        }
        return (included, local)
    }
}

/// One row of the routing table in Settings: an address or range, and where its traffic goes.
public struct RouteChoice: Identifiable, Equatable, Sendable {
    public enum Origin: Equatable, Sendable {
        /// Sent by the VPN server.
        case vpnRoute
        /// Sent by the VPN server and also used by a network the Mac is on.
        case clash(localNetwork: IPv4Network, interface: String)
        /// Typed by the user.
        case added
    }

    public enum Side: Equatable, Sendable {
        /// A shared range: the devices found on the local network stay local, the rest goes through the VPN.
        case automatic
        case vpn
        case local
    }

    public var network: IPv4Network
    public var origin: Origin
    public var side: Side
    public var id: String { network.description }

    public init(network: IPv4Network, origin: Origin, side: Side) {
        self.network = network
        self.origin = origin
        self.side = side
    }

    /// The range the VPN and the local network share, when Burrow can split it.
    public var splittable: IPv4Network? {
        guard case .clash(let localNetwork, let interface) = origin else { return nil }
        let clash = RouteClash(vpnRoute: network, localNetwork: localNetwork, interface: interface)
        return clash.splittable ? clash.shared : nil
    }

    /// Where the traffic goes without a choice: a shared range Burrow can split is automatic; otherwise the more
    /// specific route wins, and the local one on a tie.
    public var defaultSide: Side? {
        switch origin {
        case .vpnRoute: .vpn
        case .clash(let localNetwork, _): splittable != nil ? .automatic : network.prefix > localNetwork.prefix ? .vpn : .local
        case .added: nil
        }
    }

    public var isClash: Bool {
        if case .clash = origin { return true }
        return false
    }
}

public enum RouteChoices {
    /// Rows for the server's routes (with the local networks they clash with), then the user's own entries.
    public static func rows(pushed: [IPv4Network], local: [(interface: String, network: IPv4Network)],
                            viaVPN: [IPv4Network], alwaysLocal: [IPv4Network]) -> [RouteChoice] {
        var rows: [RouteChoice] = []
        for route in pushed where route.prefix > 0 && !rows.contains(where: { $0.network == route }) {
            let clash = RouteClash.find(vpnRoutes: [route], local: local).first
            var row = RouteChoice(network: route, origin: clash.map { .clash(localNetwork: $0.localNetwork, interface: $0.interface) }
                                  ?? .vpnRoute, side: .vpn)
            row.side = viaVPN.contains(route) ? .vpn : alwaysLocal.contains(route) ? .local : row.defaultSide ?? .vpn
            rows.append(row)
        }
        for network in viaVPN where !rows.contains(where: { $0.network == network }) {
            rows.append(RouteChoice(network: network, origin: .added, side: .vpn))
        }
        for network in alwaysLocal where !rows.contains(where: { $0.network == network }) {
            rows.append(RouteChoice(network: network, origin: .added, side: .local))
        }
        return rows
    }

    /// The profile's two lists: the user's own entries, every clash decided by hand (so it stops warning), and
    /// server routes moved off the VPN. Automatic is the default and isn't stored.
    public static func lists(_ rows: [RouteChoice]) -> (viaVPN: String, local: String) {
        var via: [String] = []
        var local: [String] = []
        for row in rows where row.side != .automatic {
            guard row.origin == .added || row.isClash || row.side != row.defaultSide else { continue }
            if row.side == .vpn { via.append(row.id) } else { local.append(row.id) }
        }
        return (via.joined(separator: ", "), local.joined(separator: ", "))
    }

    /// Clashes the user hasn't decided and Burrow can't split (too large to look for devices in): neither side
    /// chosen for the range, and no address in it sent to the VPN.
    public static func undecided(pushed: [IPv4Network], local: [(interface: String, network: IPv4Network)],
                                 viaVPN: [IPv4Network], alwaysLocal: [IPv4Network]) -> [RouteClash] {
        RouteClash.find(vpnRoutes: pushed, local: local).filter { clash in
            !clash.splittable && !alwaysLocal.contains(clash.vpnRoute) && !viaVPN.contains { clash.vpnRoute.overlaps($0) }
        }
    }

    /// Clashes left on automatic: the local networks to look for devices on.
    public static func automatic(pushed: [IPv4Network], local: [(interface: String, network: IPv4Network)],
                                 viaVPN: [IPv4Network], alwaysLocal: [IPv4Network]) -> [RouteClash] {
        RouteClash.find(vpnRoutes: pushed, local: local).filter { clash in
            clash.splittable && !(viaVPN + alwaysLocal).contains { $0.contains(clash.shared) }
        }
    }
}
