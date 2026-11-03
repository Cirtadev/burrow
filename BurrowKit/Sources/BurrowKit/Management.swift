import Foundation

/// One `>STATE:` notification (or a line of the reply to the `state` command).
public struct StateUpdate: Sendable, Equatable {
    public let time: Date?
    /// CONNECTING, RESOLVE, TCP_CONNECT, WAIT, AUTH, AUTH_PENDING, GET_CONFIG, ASSIGN_IP, ADD_ROUTES,
    /// CONNECTED, RECONNECTING, EXITING.
    public let name: String
    /// For CONNECTED: SUCCESS or ERROR; for RECONNECTING/EXITING: the reason (ping-restart, SIGTERM, …).
    public let detail: String
    public let localIP: String
    public let remoteIP: String
}

public struct PasswordRequest: Sendable, Equatable {
    public struct StaticChallenge: Sendable, Equatable {
        public let echo: Bool
        public let text: String
    }

    /// `Auth` for username/password, `Private Key` for a key passphrase.
    public let type: String
    public let staticChallenge: StaticChallenge?
}

public enum ManagementMessage: Sendable, Equatable {
    case info(String)
    case hold
    case needPassword(PasswordRequest)
    /// `detail` is the rest of the line, e.g. `['CRV1:…']` for a dynamic challenge.
    case verificationFailed(type: String, detail: String)
    case state(StateUpdate)
    case byteCount(received: UInt64, sent: UInt64)
    case pid(Int32)
    case success(String)
    case error(String)
    case fatal(String)
    case infoMessage(String)
    case other(String)
}

/// Parser for lines from OpenVPN's management interface (management-notes.txt, interface version 5).
public enum ManagementParser {
    public static func parse(_ rawLine: String) -> ManagementMessage {
        var line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
        // OpenVPN prompts "ENTER PASSWORD:" without a newline, so it is glued to the next line.
        while line.hasPrefix("ENTER PASSWORD:") { line.removeFirst("ENTER PASSWORD:".count) }

        if let rest = line.dropPrefix(">STATE:") { return state(rest).map(ManagementMessage.state) ?? .other(line) }
        if let rest = line.dropPrefix(">BYTECOUNT:") {
            let parts = rest.split(separator: ",").compactMap { UInt64($0) }
            return parts.count == 2 ? .byteCount(received: parts[0], sent: parts[1]) : .other(line)
        }
        if line.hasPrefix(">HOLD:") { return .hold }
        if let rest = line.dropPrefix(">PASSWORD:") { return password(rest) ?? .other(line) }
        if let rest = line.dropPrefix(">FATAL:") { return .fatal(rest) }
        if let rest = line.dropPrefix(">INFOMSG:") { return .infoMessage(rest) }
        if let rest = line.dropPrefix(">INFO:") { return .info(rest) }
        if let rest = line.dropPrefix("SUCCESS: pid="), let pid = Int32(rest.trimmingCharacters(in: .whitespaces)) {
            return .pid(pid)
        }
        if let rest = line.dropPrefix("SUCCESS:") { return .success(rest.trimmingCharacters(in: .whitespaces)) }
        if let rest = line.dropPrefix("ERROR:") { return .error(rest.trimmingCharacters(in: .whitespaces)) }
        // Reply lines of the `state` command carry no prefix: "1792478481,CONNECTED,SUCCESS,…".
        if let first = line.first, first.isNumber, let update = state(line) { return .state(update) }
        return .other(line)
    }

    static func state(_ text: String) -> StateUpdate? {
        let fields = text.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 2, let seconds = TimeInterval(fields[0]),
              !fields[1].isEmpty, fields[1].allSatisfy({ $0.isUppercase || $0 == "_" }) else { return nil }
        func field(_ index: Int) -> String { fields.indices.contains(index) ? fields[index] : "" }
        return StateUpdate(
            time: Date(timeIntervalSince1970: seconds), name: fields[1], detail: field(2),
            localIP: field(3), remoteIP: field(4))
    }

    static func password(_ text: String) -> ManagementMessage? {
        if let rest = text.dropPrefix("Need '") {
            guard let quote = rest.firstIndex(of: "'") else { return nil }
            let type = String(rest[..<quote])
            var challenge: PasswordRequest.StaticChallenge?
            if let range = rest.range(of: " SC:") {
                let spec = rest[range.upperBound...]
                let comma = spec.firstIndex(of: ",") ?? spec.endIndex
                let flags = Int(spec[..<comma]) ?? 0
                let challengeText = comma < spec.endIndex ? String(spec[spec.index(after: comma)...]) : ""
                challenge = .init(echo: flags & 1 == 1, text: challengeText)
            }
            return .needPassword(PasswordRequest(type: type, staticChallenge: challenge))
        }
        if let rest = text.dropPrefix("Verification Failed: '") {
            guard let quote = rest.firstIndex(of: "'") else { return nil }
            let detail = rest[rest.index(after: quote)...].trimmingCharacters(in: .whitespaces)
            return .verificationFailed(type: String(rest[..<quote]), detail: detail)
        }
        return nil
    }
}

/// Commands Burrow sends, formatted the way Tunnelblick sends them (re/REA-FINDINGS.md §4).
public enum ManagementCommand {
    /// Tunnelblick's limit for an escaped username or password.
    public static let maximumFieldBytes = 250

    /// Tunnelblick's `_escaped`: `\` → `\\`, `"` → `\"`, CR and LF dropped.
    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }

    public static func username(_ username: String, type: String = "Auth") -> String {
        "username \"\(escape(type))\" \"\(escape(username))\""
    }

    public static func password(_ password: String, type: String = "Auth") -> String {
        "password \"\(escape(type))\" \"\(escape(password))\""
    }

    /// Response to a static challenge (`SC:`): `SCRV1:<base64 password>:<base64 response>`.
    public static func staticChallengeResponse(password: String, response: String) -> String {
        let encodedPassword = Data(password.utf8).base64EncodedString()
        let encodedResponse = Data(response.utf8).base64EncodedString()
        return "password \"Auth\" \"SCRV1:\(encodedPassword):\(encodedResponse)\""
    }

    public static func fitsLimit(_ text: String) -> Bool { escape(text).utf8.count <= maximumFieldBytes }
}

extension String {
    func dropPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
