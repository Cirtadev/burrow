import Foundation

/// A question the server asks during sign-in, shown by the app: a dynamic challenge (`CRV1`, the session ends
/// and the answer goes with the next one) or `CR_TEXT` (the session waits for `CR_RESPONSE`).
public struct TunnelChallenge: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case dynamic
        case crText
    }

    /// Counts the questions of one tunnel, so an answer can't land on a newer question.
    public var id: Int
    public var kind: Kind
    public var text: String
    /// The answer may be shown while typed (not a secret).
    public var echo: Bool
    public var responseRequired: Bool

    public init(id: Int, kind: Kind, text: String, echo: Bool, responseRequired: Bool) {
        self.id = id
        self.kind = kind
        self.text = text
        self.echo = echo
        self.responseRequired = responseRequired
    }
}

/// `CRV1:<flags>:<state id>:<base64 username>:<text>`, the reason of an AUTH_FAILED that asks a question.
/// OpenVPN builds the reply (`CRV1::<state id>::<answer>`) from the cookie itself.
public struct DynamicChallenge: Equatable, Sendable {
    public var cookie: String
    public var stateID: String
    public var username: String
    public var text: String
    public var echo: Bool
    public var responseRequired: Bool

    public init?(cookie: String) {
        let parts = cookie.split(separator: ":", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 5, parts[0] == "CRV1",
              let name = Data(base64Encoded: parts[3]).map({ String(decoding: $0, as: UTF8.self) }) else { return nil }
        let flags = Set(parts[1].split(separator: ","))
        self.cookie = cookie
        stateID = parts[2]
        username = name
        text = parts[4]
        echo = flags.contains("E")
        responseRequired = flags.contains("R")
    }
}

/// What an INFO / INFO_PRE message from the server asks for.
public enum ServerInfo: Equatable, Sendable {
    /// `OPEN_URL:<url>` or `WEB_AUTH:<flags>:<url>`: sign in on a web page; the server goes on by itself.
    case webAuth(URL, flags: [String])
    /// `CR_TEXT:<flags>:<text>`: answer with `CR_RESPONSE`.
    case crText(text: String, echo: Bool, responseRequired: Bool)
    case other

    /// Only web pages: a server must not make Burrow open a file or another app.
    public static func webURL(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host() != nil else {
            return nil
        }
        return url
    }

    public init(_ message: String) {
        if message.hasPrefix("OPEN_URL:"), let url = Self.webURL(String(message.dropFirst("OPEN_URL:".count))) {
            self = .webAuth(url, flags: [])
        } else if message.hasPrefix("WEB_AUTH:") {
            let rest = message.dropFirst("WEB_AUTH:".count).split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            if rest.count == 2, let url = Self.webURL(String(rest[1])) {
                self = .webAuth(url, flags: rest[0].split(separator: ",").map(String.init))
            } else {
                self = .other
            }
        } else if message.hasPrefix("CR_TEXT:") {
            let rest = message.dropFirst("CR_TEXT:".count).split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard rest.count == 2 else {
                self = .other
                return
            }
            let flags = Set(rest[0].split(separator: ","))
            self = .crText(text: String(rest[1]), echo: flags.contains("E"), responseRequired: flags.contains("R"))
        } else {
            self = .other
        }
    }

    /// The control-channel reply to `CR_TEXT`.
    public static func crResponse(_ answer: String) -> String {
        "CR_RESPONSE," + Data(answer.utf8).base64EncodedString()
    }
}

/// What the app asks the tunnel (`NETunnelProviderSession.sendProviderMessage`).
public enum TunnelMessage: Equatable, Sendable {
    case snapshot
    case log
    /// The user's answer to `TunnelChallenge.id`.
    case answer(id: Int, response: String)
    /// New routing choices for the running tunnel (`VPNProfile.alwaysViaVPN`, `alwaysLocal`).
    case routes(viaVPN: String, local: String)
    /// What the app found on the local network in the ranges it shares with the VPN (`LocalDeviceScan`).
    case devices([LocalDevices])

    public var data: Data {
        switch self {
        case .snapshot: Data("snapshot".utf8)
        case .log: Data("log".utf8)
        case .answer(let id, let response): Data("answer\n\(id)\n\(response)".utf8)
        case .routes(let via, let local): Data("routes\n\(Self.oneLine(via))\n\(Self.oneLine(local))".utf8)
        case .devices(let scans): Data((["devices"] + scans.map(\.line)).joined(separator: "\n").utf8)
        }
    }

    private static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: ", ")
    }

    public init(_ data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        if text == "log" {
            self = .log
            return
        }
        if text == "devices" || text.hasPrefix("devices\n") {
            self = .devices(text.split(separator: "\n").dropFirst().compactMap { LocalDevices(line: String($0)) })
            return
        }
        let parts = text.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
        if parts.count == 3, parts[0] == "answer", let id = Int(parts[1]) {
            self = .answer(id: id, response: String(parts[2]))
        } else if parts.count == 3, parts[0] == "routes" {
            self = .routes(viaVPN: String(parts[1]), local: String(parts[2]))
        } else {
            self = .snapshot
        }
    }
}
