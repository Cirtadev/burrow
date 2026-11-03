import Foundation
import Testing
@testable import BurrowKit

private let office = TunnelblickConfiguration(
    displayName: "office", location: .shared,
    tblkPath: "/Library/Application Support/Tunnelblick/Shared/office.tblk")

@Test func startArgumentsMatchTunnelblick() {
    var options = StartOptions()
    options.openvpnVersion = "2.6.14-openssl-3.0.16"
    // From the user's Tunnelblick log:
    // openvpnstart start office.tblk 63637 0x00000301 0 3 0 0x0210c130 -ptADGNWradsgnw 2.6.14-openssl-3.0.16 <password>
    #expect(Tunnelblick.startArguments(for: office, port: 63637, managementPassword: "PW", options: options) == [
        "start", "office.tblk", "63637", "0x00000301", "0", "3", "0", "0x0210c130", "-ptADGNWradsgnw",
        "2.6.14-openssl-3.0.16", "PW",
    ])
}

@Test func encodesPathsLikeTheDownScript() {
    #expect(Tunnelblick.encodeSlashesAndPeriods("/Library/Application Support/Tunnelblick/Shared/my-vpn.tblk/Contents/Resources")
        == "-SLibrary-SApplication Support-STunnelblick-SShared-Smy--vpn-Dtblk-SContents-SResources")
    #expect(Tunnelblick.expectDisconnectArguments(for: office) == [
        "expectDisconnect", "1",
        "-SLibrary-SApplication Support-STunnelblick-SShared-Soffice-Dtblk-SContents-SResources",
    ])
}

@Test func daemonRequestFraming() throws {
    #expect(try TunnelblickDaemon.request(for: ["test"]) == Data("openvpnstart: test\n".utf8))
    #expect(try TunnelblickDaemon.request(for: ["kill", "123"]) == Data("openvpnstart: kill\t123\n".utf8))
    #expect(throws: DaemonError.invalidArgument("a\tb")) { try TunnelblickDaemon.request(for: ["a\tb"]) }
    #expect(throws: DaemonError.requestTooLong(2047)) {
        try TunnelblickDaemon.request(for: [String(repeating: "x", count: 2032)])
    }
}

@Test func daemonReplyParsing() throws {
    #expect(try TunnelblickDaemon.parseReply(Data("0 0 0\n\0".utf8)) == DaemonReply(status: 0, stdout: "", stderr: ""))
    let reply = try TunnelblickDaemon.parseReply(Data("248 2 9\nokfailed ü\0".utf8))
    #expect(reply == DaemonReply(status: 248, stdout: "ok", stderr: "failed ü"))
    #expect(throws: (any Error).self) { try TunnelblickDaemon.parseReply(Data("garbage".utf8)) }
}

@Test func managementPasswordIsSafeForTheDaemon() {
    let password = Tunnelblick.makeManagementPassword()
    #expect(password.count == 64)
    #expect(password.allSatisfy { $0.isLetter || $0.isNumber })
}

@Test func freePortIsEphemeral() throws {
    let port = try LocalPort.free()
    #expect(port >= 49152)
}
