import Darwin
import Foundation

/// Output of one `tunnelblick-helper` run, as relayed by tunnelblickd.
public struct DaemonReply: Sendable, Equatable {
    public let status: Int
    public let stdout: String
    public let stderr: String

    public init(status: Int, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum DaemonError: Error, LocalizedError, Equatable {
    case notInstalled
    case invalidArgument(String)
    case requestTooLong(Int)
    case socket(String)
    case malformedReply(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled: "Tunnelblick's helper daemon is not installed (tunnelblickd socket missing)."
        case .invalidArgument(let argument): "Argument contains a tab or newline: \(argument.debugDescription)"
        case .requestTooLong(let length): "Request is \(length) bytes; tunnelblickd reads at most 2046."
        case .socket(let message): "tunnelblickd: \(message)"
        case .malformedReply(let reply): "Unexpected reply from tunnelblickd: \(reply.prefix(120))"
        }
    }
}

/// Client for Tunnelblick's root daemon. A request is `openvpnstart: ` + tab-separated arguments + `\n`;
/// tunnelblickd runs `tunnelblick-helper <arguments>` as the calling user and replies
/// `"<status> <stdout length> <stderr length>\n" + stdout + stderr + NUL`.
/// See docs/tunnelblick-protocol.md.
public struct TunnelblickDaemon: Sendable {
    public static let defaultSocketPath = "/var/run/net.tunnelblick.tunnelblick.tunnelblickd.socket"
    static let header = "openvpnstart: "
    static let maximumRequestBytes = 2046

    public var socketPath: String
    public var timeout: TimeInterval

    public init(socketPath: String = TunnelblickDaemon.defaultSocketPath, timeout: TimeInterval = 90) {
        self.socketPath = socketPath
        self.timeout = timeout
    }

    public var isAvailable: Bool { FileManager.default.fileExists(atPath: socketPath) }

    static func request(for arguments: [String]) throws -> Data {
        for argument in arguments where argument.contains(where: { $0 == "\t" || $0 == "\n" || $0 == "\r" }) {
            throw DaemonError.invalidArgument(argument)
        }
        let data = Data((header + arguments.joined(separator: "\t") + "\n").utf8)
        guard data.count <= maximumRequestBytes else { throw DaemonError.requestTooLong(data.count) }
        return data
    }

    static func parseReply(_ data: Data) throws -> DaemonReply {
        guard let newline = data.firstIndex(of: 0x0a),
              let head = String(data: data[data.startIndex..<newline], encoding: .utf8) else {
            throw DaemonError.malformedReply(String(decoding: data, as: UTF8.self))
        }
        let fields = head.split(separator: " ").compactMap { Int($0) }
        guard fields.count == 3, fields[1] >= 0, fields[2] >= 0 else { throw DaemonError.malformedReply(head) }

        var body = Data(data[data.index(after: newline)...])
        if body.last == 0 { body.removeLast() }
        // Lengths are NSString lengths (UTF-16 units), not bytes.
        let utf16 = Array(String(decoding: body, as: UTF8.self).utf16)
        let outEnd = min(fields[1], utf16.count)
        let errEnd = min(outEnd + fields[2], utf16.count)
        return DaemonReply(
            status: fields[0],
            stdout: String(decoding: utf16[0..<outEnd], as: UTF16.self),
            stderr: String(decoding: utf16[outEnd..<errEnd], as: UTF16.self))
    }

    /// Blocking: call it off the main thread.
    public func run(_ arguments: [String]) throws -> DaemonReply {
        guard isAvailable else { throw DaemonError.notInstalled }
        let request = try Self.request(for: arguments)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DaemonError.socket("socket(): \(String(cString: strerror(errno)))") }
        defer { close(fd) }

        var value: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw DaemonError.socket("socket path too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw DaemonError.socket("connect(): \(String(cString: strerror(errno)))") }

        // tunnelblickd does a single read(), so the request must go out in one write.
        let written = request.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == request.count else {
            throw DaemonError.socket("write(): \(String(cString: strerror(errno)))")
        }

        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                reply.append(contentsOf: buffer[0..<count])
            } else if count == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                throw DaemonError.socket("read(): \(String(cString: strerror(errno)))")
            }
        }
        return try Self.parseReply(reply)
    }
}
