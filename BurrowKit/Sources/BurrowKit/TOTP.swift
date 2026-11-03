import CryptoKit
import Foundation

/// RFC 6238 time-based one-time passwords, as produced by authenticator apps.
public struct TOTP: Sendable, Equatable {
    public enum Algorithm: String, Sendable, CaseIterable {
        case sha1 = "SHA1", sha256 = "SHA256", sha512 = "SHA512"
    }

    public enum ParseError: Error, LocalizedError, Equatable {
        case empty
        case notBase32
        case unsupportedURI(String)

        public var errorDescription: String? {
            switch self {
            case .empty: "No OTP secret."
            case .notBase32: "The secret is not valid Base32."
            case .unsupportedURI(let reason): "Unsupported otpauth URI: \(reason)."
            }
        }
    }

    public var secret: Data
    public var digits: Int
    public var period: Int
    public var algorithm: Algorithm

    public init(secret: Data, digits: Int = 6, period: Int = 30, algorithm: Algorithm = .sha1) {
        self.secret = secret
        self.digits = digits
        self.period = period
        self.algorithm = algorithm
    }

    /// Accepts an `otpauth://totp/...` URI or a bare Base32 secret (spaces, dashes and lowercase are fine).
    public init(parsing text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ParseError.empty }

        guard trimmed.lowercased().hasPrefix("otpauth:") else {
            guard let secret = Base32.decode(trimmed), !secret.isEmpty else { throw ParseError.notBase32 }
            self.init(secret: secret)
            return
        }

        guard let components = URLComponents(string: trimmed) else { throw ParseError.unsupportedURI("not a URL") }
        guard components.host?.lowercased() == "totp" else {
            throw ParseError.unsupportedURI("only totp is supported, not \(components.host ?? "?")")
        }
        let query = Dictionary(
            (components.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") },
            uniquingKeysWith: { first, _ in first })
        guard let secretText = query["secret"], let secret = Base32.decode(secretText), !secret.isEmpty else {
            throw ParseError.notBase32
        }
        var algorithm = Algorithm.sha1
        if let name = query["algorithm"] {
            guard let parsed = Algorithm(rawValue: name.uppercased()) else {
                throw ParseError.unsupportedURI("algorithm \(name)")
            }
            algorithm = parsed
        }
        let digits = Int(query["digits"] ?? "") ?? 6
        let period = Int(query["period"] ?? "") ?? 30
        guard (6...10).contains(digits) else { throw ParseError.unsupportedURI("\(digits) digits") }
        guard period > 0 else { throw ParseError.unsupportedURI("period \(period)") }
        self.init(secret: secret, digits: digits, period: period, algorithm: algorithm)
    }

    public func counter(at date: Date) -> UInt64 {
        UInt64(max(0, (date.timeIntervalSince1970 / Double(period)).rounded(.down)))
    }

    /// Seconds until the code for `date` stops being current (1...period).
    public func secondsRemaining(at date: Date) -> Int {
        let elapsed = Int(date.timeIntervalSince1970.rounded(.down)) % period
        return period - elapsed
    }

    public func code(at date: Date) -> String { code(counter: counter(at: date)) }

    public func code(counter: UInt64) -> String {
        var bigEndian = counter.bigEndian
        let message = Data(bytes: &bigEndian, count: MemoryLayout<UInt64>.size)
        let key = SymmetricKey(data: secret)
        let mac: [UInt8] = switch algorithm {
        case .sha1: Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        case .sha256: Array(HMAC<SHA256>.authenticationCode(for: message, using: key))
        case .sha512: Array(HMAC<SHA512>.authenticationCode(for: message, using: key))
        }
        let offset = Int(mac[mac.count - 1] & 0x0f)
        let truncated = (UInt32(mac[offset] & 0x7f) << 24)
            | (UInt32(mac[offset + 1]) << 16)
            | (UInt32(mac[offset + 2]) << 8)
            | UInt32(mac[offset + 3])
        var modulus: UInt64 = 1
        for _ in 0..<digits { modulus *= 10 }
        let value = UInt64(truncated) % modulus
        let text = String(value)
        return String(repeating: "0", count: max(0, digits - text.count)) + text
    }
}

/// RFC 4648 Base32 decoding, tolerant of padding, whitespace, dashes and lowercase.
public enum Base32 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    public static func decode(_ text: String) -> Data? {
        var lookup = [Character: UInt8]()
        for (index, character) in alphabet.enumerated() { lookup[character] = UInt8(index) }

        var bytes = [UInt8]()
        var buffer: UInt32 = 0
        var bitCount = 0
        for character in text.uppercased() {
            if character == "=" || character == " " || character == "-" || character.isNewline || character == "\t" {
                continue
            }
            guard let value = lookup[character] else { return nil }
            buffer = (buffer << 5) | UInt32(value)
            bitCount += 5
            if bitCount >= 8 {
                bitCount -= 8
                bytes.append(UInt8((buffer >> UInt32(bitCount)) & 0xff))
            }
        }
        return Data(bytes)
    }
}
