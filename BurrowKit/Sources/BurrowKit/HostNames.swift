import Darwin
import Foundation

/// The names `/etc/hosts` gives IPv4 addresses (`192.168.1.20 server`), to show and type them in Settings › Routing.
public struct HostNames: Equatable, Sendable {
    public private(set) var names: [UInt32: [String]] = [:]

    public init(_ text: String) {
        for line in text.split(whereSeparator: \.isNewline) {
            let words = line.prefix { $0 != "#" }.split(whereSeparator: \.isWhitespace).map(String.init)
            guard words.count > 1, let address = IPv4Network.parse(words[0]) else { continue }
            for name in words.dropFirst() where !names[address, default: []].contains(name) {
                names[address, default: []].append(name)
            }
        }
    }

    public static func current() -> HostNames {
        HostNames((try? String(contentsOfFile: "/etc/hosts", encoding: .utf8)) ?? "")
    }

    /// `server` for `192.168.1.20`; nil for a range or an address without a name.
    public func name(of network: IPv4Network) -> String? {
        network.prefix == 32 ? names[network.address]?.first : nil
    }

    /// `192.168.1.20 (server)`.
    public func label(_ network: IPv4Network) -> String {
        name(of: network).map { "\(network) (\($0))" } ?? network.description
    }

    /// The addresses of a name: from `/etc/hosts` (case-insensitive, like the resolver), else from DNS.
    public func addresses(of name: String) async -> [IPv4Network] {
        let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
        let listed = names.filter { $0.value.contains { $0.lowercased() == wanted } }.keys.sorted()
        if !listed.isEmpty { return listed.map { IPv4Network(address: $0, prefix: 32) } }
        return await Task.detached { Self.lookUp(wanted) }.value
    }

    private static func lookUp(_ name: String) -> [IPv4Network] {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(name, nil, &hints, &list) == 0, let first = list else { return [] }
        defer { freeaddrinfo(list) }
        var result: [IPv4Network] = []
        for entry in sequence(first: first, next: { $0.pointee.ai_next }) {
            guard let address = entry.pointee.ai_addr, address.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let network = IPv4Network(address: ip, prefix: 32)
            if !result.contains(network) { result.append(network) }
        }
        return result
    }
}
