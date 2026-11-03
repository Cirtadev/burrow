import Foundation
import Network

/// A line-oriented TCP client for OpenVPN's management interface on 127.0.0.1.
/// Runs on the main queue; the interface is chatty only while connecting.
@MainActor
public final class ManagementConnection {
    public enum Event: Sendable {
        case ready
        case message(ManagementMessage)
        /// The socket closed or could not be opened. `wasReady` tells which.
        case closed(wasReady: Bool, reason: String?)
    }

    public let port: UInt16
    public var onEvent: ((Event) -> Void)?
    public private(set) var isReady = false

    private var connection: NWConnection?
    private var buffer = Data()
    private var finished = false

    public init(port: UInt16) {
        self.port = port
    }

    public func open() {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            finish(reason: "invalid port \(port)")
            return
        }
        let connection = NWConnection(host: "127.0.0.1", port: endpointPort, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.handle(state) }
        }
        connection.start(queue: .main)
    }

    /// Sends one command; the CR LF terminator is added here.
    public func send(_ command: String) {
        guard let connection, isReady else { return }
        connection.send(content: Data((command + "\r\n").utf8), completion: .contentProcessed { _ in })
    }

    public func close() {
        connection?.cancel()
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            isReady = true
            onEvent?(.ready)
            receive()
        case .waiting(let error), .failed(let error):
            // "Connection refused" while OpenVPN is still starting lands here; the caller retries.
            finish(reason: error.localizedDescription)
        case .cancelled:
            finish(reason: nil)
        default:
            break
        }
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.buffer.append(data)
                    self.drainLines()
                }
                if isComplete || error != nil {
                    self.finish(reason: error?.localizedDescription)
                } else {
                    self.receive()
                }
            }
        }
    }

    private func drainLines() {
        while let newline = buffer.firstIndex(of: 0x0a) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            let line = String(decoding: lineData, as: UTF8.self)
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            onEvent?(.message(ManagementParser.parse(line)))
        }
    }

    private func finish(reason: String?) {
        guard !finished else { return }
        finished = true
        let wasReady = isReady
        isReady = false
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        onEvent?(.closed(wasReady: wasReady, reason: reason))
    }
}
