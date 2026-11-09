import Foundation

/// Prepares a `.ovpn` at import. The tunnel extension can't read files, and credentials belong in the keychain,
/// not in the config: named files are inlined, and the logins and passphrase a config carries move into the
/// profile.
public struct OVPNImport: Equatable, Sendable {
    public var ovpn: String
    public var username: String?
    public var password: String?
    public var keyPassphrase: String?
    public var proxyUsername: String?
    public var proxyPassword: String?
    /// A PKCS#12 bundle (`pkcs12 file` or `<pkcs12>`) still to convert with `PKCS12.convert`.
    public var pkcs12: Data?

    /// `file` reads a file the config names, relative to its folder (nil if missing).
    public init(_ text: String, file: (String) -> Data?) {
        ovpn = text
        func string(_ name: String) -> String? { file(name).map { String(decoding: $0, as: UTF8.self) } }
        var named: [String: String] = [:]
        for name in OVPNSummary(text).missingFiles { named[name] = string(name) }
        let inlined = TunnelblickImport.inline(text, files: named.compactMapValues { $0 })

        var output: [String] = []
        var block: (name: String, lines: [String])?
        for raw in inlined.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if var open = block {
                if line == "</\(open.name)>" {
                    block = nil
                    take(block: open.name, lines: open.lines, into: &output)
                } else {
                    open.lines.append(raw)
                    block = open
                }
                continue
            }
            if line.hasPrefix("<"), line.hasSuffix(">"), !line.hasPrefix("</") {
                let name = String(line.dropFirst().dropLast())
                if ["auth-user-pass", "http-proxy-user-pass", "pkcs12"].contains(name) {
                    block = (name, [])
                    continue
                }
            }
            let words = OVPNSummary.tokens(line)
            guard let keyword = words.first, !line.hasPrefix("#"), !line.hasPrefix(";") else {
                output.append(raw)
                continue
            }
            let argument = words.count > 1 && words[1] != "[inline]" ? words[1] : nil
            switch keyword {
            case "auth-user-pass" where argument != nil:
                if let lines = string(argument!).map(Self.lines) {
                    username = lines.first
                    password = lines.dropFirst().first
                }
                output.append("auth-user-pass")
            case "askpass" where argument != nil:
                if let first = string(argument!).map(Self.lines)?.first { keyPassphrase = first }
                output.append("askpass")
            case "http-proxy-user-pass" where argument != nil:
                if let lines = string(argument!).map(Self.lines) {
                    proxyUsername = lines.first
                    proxyPassword = lines.dropFirst().first
                }
            case "http-proxy" where words.count > 3 && !["auto", "auto-nct", "stdin", "none"].contains(words[3]):
                // `http-proxy host port <authfile> [method]`: the login moves to the profile.
                if let lines = string(words[3]).map(Self.lines) {
                    proxyUsername = lines.first
                    proxyPassword = lines.dropFirst().first
                }
                output.append("http-proxy \(words[1]) \(words[2])")
            case "pkcs12" where argument != nil:
                pkcs12 = file(argument!)
                if pkcs12 == nil { output.append(raw) }
            default:
                output.append(raw)
            }
        }
        ovpn = output.joined(separator: "\n")
    }

    private mutating func take(block name: String, lines: [String], into output: inout [String]) {
        let values = Self.lines(lines.joined(separator: "\n"))
        switch name {
        case "auth-user-pass":
            username = values.first
            password = values.dropFirst().first
            output.append("auth-user-pass")
        case "http-proxy-user-pass":
            proxyUsername = values.first
            proxyPassword = values.dropFirst().first
        default: // pkcs12: base64 DER
            pkcs12 = Data(base64Encoded: values.joined(), options: .ignoreUnknownCharacters)
        }
    }

    private static func lines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Puts the certificate and key from a converted PKCS#12 bundle into the config; its CA certificates become
    /// `<ca>` unless the config has one, else `<extra-certs>` (intermediates).
    public static func adding(_ contents: PKCS12.Contents, to ovpn: String) -> String {
        let hasCA = ovpn.components(separatedBy: .newlines).contains {
            let line = $0.trimmingCharacters(in: .whitespaces)
            return line == "<ca>" || OVPNSummary.tokens(line).first == "ca"
        }
        var text = ovpn.hasSuffix("\n") ? ovpn : ovpn + "\n"
        func block(_ name: String, _ body: String) { text += "<\(name)>\n\(body.trimmingCharacters(in: .newlines))\n</\(name)>\n" }
        block("cert", contents.certificate)
        block("key", contents.key)
        if !contents.authorities.isEmpty {
            block(hasCA ? "extra-certs" : "ca", contents.authorities.joined(separator: "\n"))
        }
        return text
    }
}

/// Converts PKCS#12 (`.p12`) bundles, which OpenVPN 3 with Mbed TLS can't read, to PEM with macOS's
/// `/usr/bin/openssl` (LibreSSL).
public enum PKCS12 {
    public struct Contents: Equatable, Sendable {
        public var certificate: String
        public var key: String
        public var authorities: [String]
    }

    public enum ConversionError: Error, LocalizedError, Equatable {
        case wrongPassword
        case incomplete
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .wrongPassword: "The PKCS#12 password is wrong."
            case .incomplete: "The PKCS#12 file has no certificate with its private key."
            case .failed(let detail): "The PKCS#12 file could not be read: \(detail)"
            }
        }
    }

    public static func convert(_ data: Data, password: String) throws -> Contents {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("burrow-p12-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("bundle.p12")
        try data.write(to: input)

        func run(_ arguments: [String]) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            // The password goes through a pipe, never the command line (visible in `ps`).
            process.arguments = ["pkcs12", "-in", input.path, "-passin", "stdin"] + arguments
            let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
            stdin.fileHandleForWriting.write(Data((password + "\n").utf8))
            try? stdin.fileHandleForWriting.close()
            let output = stdout.fileHandleForReading.readDataToEndOfFile()
            let errors = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                if errors.localizedCaseInsensitiveContains("mac verify") || errors.contains("invalid password") {
                    throw ConversionError.wrongPassword
                }
                throw ConversionError.failed(errors.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return String(decoding: output, as: UTF8.self)
        }

        let certificate = pemBlocks(try run(["-nokeys", "-clcerts"])).first
        let key = pemBlocks(try run(["-nocerts", "-nodes"])).first
        let authorities = pemBlocks(try run(["-nokeys", "-cacerts"]))
        guard let certificate, let key else { throw ConversionError.incomplete }
        return Contents(certificate: certificate, key: key, authorities: authorities.filter { $0 != certificate })
    }

    /// The `-----BEGIN …-----` … `-----END …-----` blocks of openssl's output, without its "Bag Attributes".
    static func pemBlocks(_ text: String) -> [String] {
        var blocks: [String] = []
        var current: [String]?
        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("-----BEGIN ") { current = [line] } else if current != nil { current?.append(line) }
            if line.hasPrefix("-----END "), let block = current {
                blocks.append(block.joined(separator: "\n"))
                current = nil
            }
        }
        return blocks
    }
}

/// The `.ovpn` text the tunnel hands to OpenVPN 3.
public enum TunnelConfig {
    public static func ovpn(for profile: VPNProfile) -> String {
        prepared(for: profile).ovpn
    }

    /// The configuration the tunnel hands to OpenVPN 3, and what Burrow changed in it (for the tunnel's log).
    public static func prepared(for profile: VPNProfile) -> (ovpn: String, notes: [String]) {
        let summary = profile.summary
        var lines = profile.ovpn.components(separatedBy: "\n")
        if summary.staticChallengeConcat {
            // OpenVPN 3 only knows SCRV1: without the line it lets Burrow append the answer to the password.
            lines.removeAll { OVPNSummary.tokens($0.trimmingCharacters(in: .whitespaces)).first == "static-challenge" }
        }
        if summary.usesHTTPProxy, !summary.hasProxyLogin, !profile.proxyUsername.isEmpty {
            let clean = { (text: String) in text.components(separatedBy: .newlines).joined() }
            lines += ["<http-proxy-user-pass>", clean(profile.proxyUsername), clean(profile.proxyPassword),
                      "</http-proxy-user-pass>"]
        }
        let adapted = OpenVPN3Options.adapt(lines)
        return (adapted.lines.joined(separator: "\n"), adapted.notes)
    }
}
