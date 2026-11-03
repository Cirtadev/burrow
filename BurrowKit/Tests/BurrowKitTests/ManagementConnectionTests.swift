import Darwin
import Foundation
import Testing
@testable import BurrowKit

/// A one-shot TCP server that plays OpenVPN's side of a management session from a script.
private final class FakeManagementServer: @unchecked Sendable {
    enum Step { case send(String), expect(String) }

    let port: UInt16
    private let listener: Int32
    private let lock = NSLock()
    private var _received: [String] = []
    var received: [String] { lock.withLock { _received } }

    init(script: [Step]) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 ? getsockname(fd, $0, &length) : -1
            }
        }
        listener = fd
        port = UInt16(bigEndian: address.sin_port)
        guard listen(fd, 1) == 0 else { throw POSIXError(.EADDRINUSE) }
        Thread.detachNewThread { [self] in serve(script) }
    }

    private func serve(_ script: [Step]) {
        let client = accept(listener, nil, nil)
        defer { close(client); close(listener) }
        var pending = Data()
        for step in script {
            switch step {
            case .send(let text):
                _ = text.utf8CString.withUnsafeBufferPointer { write(client, $0.baseAddress, $0.count - 1) }
            case .expect(let line):
                while !pending.contains(0x0a) {
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    let count = read(client, &buffer, buffer.count)
                    guard count > 0 else { return }
                    pending.append(contentsOf: buffer[0..<count])
                }
                let newline = pending.firstIndex(of: 0x0a)!
                let got = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                pending.removeSubrange(pending.startIndex...newline)
                lock.withLock { _received.append(got) }
                if got != line + "\r" { return }
            }
        }
    }
}

@MainActor
private final class Recorder {
    var messages: [ManagementMessage] = []
    var closed = false
    var wasReady = false
}

@MainActor
@Test func conversationWithFakeOpenVPN() async throws {
    let server = try FakeManagementServer(script: [
        .send("ENTER PASSWORD:"),
        .expect("mgmt-secret"),
        .send("SUCCESS: password is correct\r\n"),
        .expect("pid"),
        .send(">INFO:OpenVPN Management Interface Version 5 -- type 'help' for more info\r\n"),
        .send("SUCCESS: pid=4242\r\n>HOLD:Waiting for hold release:0\r\n"),
        .expect("hold release"),
        .send(">PASSWORD:Need 'Auth' username/password\r\n"),
        .expect(#"username "Auth" "alice""#),
        .expect(#"password "Auth" "pw123456""#),
        .send(">STATE:1792478481,CONNECTED,SUCCESS,10.8.0.2,203.0.113.10,443,,\r\n"),
    ])

    let recorder = Recorder()
    let connection = ManagementConnection(port: server.port)
    connection.onEvent = { event in
        switch event {
        case .ready:
            connection.send("mgmt-secret")
            connection.send("pid")
        case .message(let message):
            recorder.messages.append(message)
            switch message {
            case .hold: connection.send("hold release")
            case .needPassword:
                connection.send(ManagementCommand.username("alice"))
                connection.send(ManagementCommand.password("pw123456"))
            default: break
            }
        case .closed(let wasReady, _):
            recorder.wasReady = wasReady
            recorder.closed = true
        }
    }
    connection.open()

    for _ in 0..<100 where !recorder.closed { try await Task.sleep(for: .milliseconds(50)) }

    #expect(recorder.closed)
    #expect(recorder.wasReady)
    #expect(server.received == [
        "mgmt-secret\r", "pid\r", "hold release\r", #"username "Auth" "alice""# + "\r", #"password "Auth" "pw123456""# + "\r",
    ])
    #expect(recorder.messages == [
        .success("password is correct"),
        .info("OpenVPN Management Interface Version 5 -- type 'help' for more info"),
        .pid(4242),
        .hold,
        .needPassword(PasswordRequest(type: "Auth", staticChallenge: nil)),
        .state(StateUpdate(time: Date(timeIntervalSince1970: 1_792_478_481), name: "CONNECTED", detail: "SUCCESS",
                           localIP: "10.8.0.2", remoteIP: "203.0.113.10")),
    ])
}

@MainActor
@Test func refusedConnectionReportsNotReady() async throws {
    let port = try LocalPort.free() // nothing listens here
    let recorder = Recorder()
    let connection = ManagementConnection(port: port)
    connection.onEvent = { event in
        if case .closed(let wasReady, _) = event {
            recorder.wasReady = wasReady
            recorder.closed = true
        }
    }
    connection.open()
    for _ in 0..<100 where !recorder.closed { try await Task.sleep(for: .milliseconds(50)) }
    #expect(recorder.closed)
    #expect(!recorder.wasReady)
}
