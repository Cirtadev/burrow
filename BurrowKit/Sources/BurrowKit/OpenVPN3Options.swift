import Foundation

/// OpenVPN 3 Core 3.11 refuses to connect when a configuration has OpenVPN 2 directives it doesn't use (3.6
/// ignored them). Burrow leaves out of the tunnel's copy the ones that only matter to an OpenVPN 2 process or
/// that the server pushes anyway, translates `ns-cert-type server`, and names the ones it can't leave out safely.
/// The saved configuration stays as imported.
public enum OpenVPN3Options {
    /// A directive OpenVPN 3 can't honour, and what to do about it.
    public struct Unsupported: Equatable, Sendable {
        public var name: String
        public var hint: String
    }

    /// Left out of the tunnel's copy: log and status files, daemon and process settings, Windows-only and
    /// Linux-only options, timers and retries OpenVPN 3 handles itself, options the server pushes, and options
    /// removed from OpenVPN. (`management…` directives are left out too.)
    public static let leftOut: Set<String> = [
        // Logs, status files, the OpenVPN 2 process
        "log", "log-append", "status", "status-version", "syslog", "daemon", "writepid", "cd", "chroot",
        "errors-to-stderr", "memstats", "up-restart", "single-session",
        // Burrow asks for the private key's passphrase itself.
        "askpass",
        // Windows or Linux only
        "register-dns", "dhcp-renew", "dhcp-release", "win-sys", "iproute", "dev-node", "lladdr",
        // Timers and retries
        "ping-timer-rem", "ping-exit", "http-proxy-retry", "socks-proxy-retry", "connect-freq",
        // Compression tuning (OpenVPN 3 doesn't compress what it sends)
        "comp-noadapt",
        // Pushed by the server in client mode
        "topology", "route-gateway", "ifconfig", "ifconfig-ipv6", "auth-token-user",
        // Removed from OpenVPN: ciphers are negotiated anyway
        "ncp-disable",
        // HTTP proxy request tweaks (version, user agent, extra headers)
        "http-proxy-option",
    ]

    /// Directives OpenVPN 3 can't honour and that change how the server is checked or where the traffic goes:
    /// the configuration can't be used until they're removed. The value says what to do.
    public static let unsupported: [String: String] = [
        "socks-proxy": "Burrow can't connect through a SOCKS proxy",
        "fragment": "the server must not use it either",
        "verify-hash": "use the CA certificate (ca) instead",
        "peer-fingerprint": "use the CA certificate (ca) instead",
        "capath": "put the CA certificates inline (<ca>)",
        "x509-username-field": "remove it",
    ]

    /// The configuration's lines as OpenVPN 3 takes them, and what was changed (for the tunnel's log).
    public static func adapt(_ lines: [String]) -> (lines: [String], notes: [String]) {
        let hasRemoteCertTLS = lines.contains { directive(of: $0)?.name == "remote-cert-tls" }
        var output: [String] = []
        var notes: [String] = []
        var inBlock: String?
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let block = inBlock {
                if trimmed == "</\(block)>" { inBlock = nil }
                // Only <connection> blocks hold directives; the others hold keys and certificates.
                if block != "connection" || trimmed == "</\(block)>" {
                    output.append(line)
                    continue
                }
            } else if trimmed.hasPrefix("<"), trimmed.hasSuffix(">"), !trimmed.hasPrefix("</") {
                inBlock = String(trimmed.dropFirst().dropLast())
                output.append(line)
                continue
            }
            guard let (name, words) = directive(of: line) else {
                output.append(line)
                continue
            }
            if name == "ns-cert-type", words.count == 2, words[1] == "server" {
                // Mbed TLS 3 has no ns-cert-type. remote-cert-tls checks the same thing (the server's certificate
                // is a server certificate, not another client's) with the key-usage extensions instead.
                if hasRemoteCertTLS {
                    notes.append("left out ns-cert-type server (remote-cert-tls is set)")
                } else {
                    output.append("remote-cert-tls server")
                    notes.append("ns-cert-type server → remote-cert-tls server")
                }
            } else if leftOut.contains(name) || name.hasPrefix("management") {
                notes.append("left out \(name) (not used by OpenVPN 3)")
            } else {
                output.append(line)
            }
        }
        return (output, notes)
    }

    /// The directives in `lines` that OpenVPN 3 can't honour, in order, with what to do.
    public static func problems(in lines: [String]) -> [Unsupported] {
        var found: [Unsupported] = []
        var inBlock: String?
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let block = inBlock {
                if trimmed == "</\(block)>" { inBlock = nil }
                if block != "connection" { continue }
            } else if trimmed.hasPrefix("<"), trimmed.hasSuffix(">"), !trimmed.hasPrefix("</") {
                inBlock = String(trimmed.dropFirst().dropLast())
                continue
            }
            guard let (name, words) = directive(of: line), !found.contains(where: { $0.name == name }) else { continue }
            if let hint = unsupported[name] {
                found.append(Unsupported(name: name, hint: hint))
            } else if name == "ns-cert-type", words.count != 2 || words[1] != "server" {
                found.append(Unsupported(name: name, hint: "use remote-cert-tls server"))
            }
        }
        return found
    }

    /// The data cipher OpenVPN 3 couldn't set up, from its log line ("Client exception in transport_recv:
    /// mbedtls_cipher_error: BF-CBC: not usable"), or nil. OpenVPN 3 then retries forever without an error event.
    public static func unusableCipher(inLogLine line: String) -> String? {
        guard let range = line.range(of: "mbedtls_cipher_error: ") else { return nil }
        let rest = line[range.upperBound...]
        guard let end = rest.range(of: ": not usable") else { return nil }
        let cipher = rest[..<end.lowerBound]
        return cipher.isEmpty || cipher.contains(" ") ? nil : String(cipher)
    }

    private static func directive(of line: String) -> (name: String, words: [String])? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), !trimmed.hasPrefix(";"), !trimmed.hasPrefix("<") else { return nil }
        let words = OVPNSummary.tokens(trimmed)
        guard let first = words.first else { return nil }
        // OpenVPN also takes "--option" in a configuration file.
        let name = first.hasPrefix("--") ? String(first.dropFirst(2)) : first
        return (name, words)
    }
}
