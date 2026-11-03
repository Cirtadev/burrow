import Darwin
import Foundation

/// The devices found on a local network inside a range it shares with the VPN. They stay local; Burrow sends the
/// rest of the range through the VPN (`RoutePlan`), so company servers are reachable without listing them.
public struct LocalDevices: Equatable, Sendable {
    /// Ranges wider than a /22 (1,024 addresses) aren't scanned.
    public static let smallestPrefix = 22

    /// The addresses the VPN and the local network share.
    public var range: IPv4Network
    public var localNetwork: IPv4Network
    /// The addresses that answered on the local network, and the Mac's own (/32 each).
    public var found: [IPv4Network]

    public init(range: IPv4Network, localNetwork: IPv4Network, found: [IPv4Network]) {
        self.range = range
        self.localNetwork = localNetwork
        self.found = found
    }

    /// The local network's network and broadcast addresses, which never go through the VPN.
    public var edges: [IPv4Network] {
        guard localNetwork.prefix <= 30 else { return [] }
        return [IPv4Network(address: localNetwork.address, prefix: 32),
                IPv4Network(address: localNetwork.address | ~localNetwork.mask, prefix: 32)]
    }

    /// `192.168.1.0/24 192.168.1.0/24 192.168.1.1 192.168.1.14`: one line of `TunnelMessage.devices`.
    var line: String { ([range, localNetwork] + found).map(\.description).joined(separator: " ") }

    init?(line: String) {
        let networks = line.split(separator: " ").compactMap { IPv4Network(String($0)) }
        guard networks.count >= 2 else { return nil }
        self.init(range: networks[0], localNetwork: networks[1], found: Array(networks.dropFirst(2)))
    }
}

/// Finds the devices of a shared range on the local network, the way the ARP layer sees them. A tiny UDP packet to
/// each address, once a second and bound to the local interface so it never enters the tunnel, makes macOS ask the
/// network who has it; after 5 unanswered asks it reports the address down ("Host is down", for 20 seconds), while
/// sending to a device that answered goes on working. Apps can't read the ARP table itself (macOS returns it empty,
/// even through `arp`). Takes about 7 seconds. The packets need the app's Local Network permission (Privacy &
/// Security › Local Network); without it macOS drops them unseen.
public enum LocalDeviceScan {
    public enum Failure: Error, Equatable {
        /// The packets never reached the network: Local Network access is off for the app.
        case notAllowed
        /// Nothing answered, not even the router: splitting on that would send the whole network through the VPN.
        case noAnswer
        case unavailable
    }

    /// Rounds of packets: macOS asks up to `net.link.ether.inet.maxtries` (5) times, a second apart.
    static let rounds = 6

    public static func run(_ clash: RouteClash) async throws(Failure) -> LocalDevices {
        let range = clash.shared
        var result = LocalDevices(range: range, localNetwork: clash.localNetwork, found: [])
        let index = if_nametoindex(clash.interface)
        guard index != 0, range.prefix >= LocalDevices.smallestPrefix, let socket = boundSocket(interfaceIndex: index) else {
            throw .unavailable
        }
        defer { close(socket) }
        let own = Set(LocalNetworks.addresses(on: clash.interface).filter { range.contains(IPv4Network(address: $0, prefix: 32)) })
        let edges = Set(result.edges.map(\.address))
        let last = range.address | ~range.mask
        let targets = (range.address...last).filter { !edges.contains($0) && !own.contains($0) }

        var down = Set<UInt32>()
        for round in 0...rounds {
            if round > 0 { try? await Task.sleep(for: .seconds(1)) }
            for address in targets where !down.contains(address) && !send(socket, to: address) {
                down.insert(address)
            }
        }
        // Some addresses are always free; if none ever went down, the packets never left the Mac.
        guard !down.isEmpty else { throw .notAllowed }
        let answered = targets.filter { !down.contains($0) }
        guard !answered.isEmpty else { throw .noAnswer }
        result.found = (answered + own).sorted().map { IPv4Network(address: $0, prefix: 32) }
        return result
    }

    /// Nil if the socket can't be bound to the interface: unbound, the packets would follow the routes, into the
    /// tunnel.
    private static func boundSocket(interfaceIndex: UInt32) -> Int32? {
        let socket = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socket >= 0 else { return nil }
        var index = interfaceIndex
        guard setsockopt(socket, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size)) == 0 else {
            close(socket)
            return nil
        }
        // Packets waiting for an answer count against the send buffer.
        var bufferSize: Int32 = 1 << 20
        _ = setsockopt(socket, SOL_SOCKET, SO_SNDBUF, &bufferSize, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(socket, F_SETFL, O_NONBLOCK)
        return socket
    }

    /// False when macOS reports the address down: nobody answered its asks.
    private static func send(_ socket: Int32, to address: UInt32) -> Bool {
        var target = sockaddr_in()
        target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = in_port_t(9).bigEndian // discard
        target.sin_addr.s_addr = address.bigEndian
        var byte: UInt8 = 0
        for _ in 0..<20 {
            let sent = withUnsafePointer(to: &target) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(socket, &byte, 1, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if sent >= 0 { return true }
            if errno == EHOSTDOWN || errno == EHOSTUNREACH { return false }
            guard errno == EAGAIN || errno == ENOBUFS else { return true }
            usleep(10_000)
        }
        return true
    }
}
