import Foundation
import Testing
@testable import BurrowKit

private func net(_ text: String) -> IPv4Network { IPv4Network(text)! }

@Test func importMovesCredentialsIntoTheProfile() {
    let config = """
    client
    remote vpn.example.com 1194
    <auth-user-pass>
    alice
    s3cret
    </auth-user-pass>
    askpass key.pass
    http-proxy proxy.example.com 8080 proxy.creds basic
    """
    let files = ["key.pass": "kp\n", "proxy.creds": "puser\nppass\n"]
    let imported = OVPNImport(config) { files[$0].map { Data($0.utf8) } }
    #expect(imported.username == "alice")
    #expect(imported.password == "s3cret")
    #expect(imported.keyPassphrase == "kp")
    #expect(imported.proxyUsername == "puser")
    #expect(imported.proxyPassword == "ppass")
    #expect(!imported.ovpn.contains("s3cret"))
    #expect(imported.ovpn.contains("\nauth-user-pass\n"))
    #expect(imported.ovpn.contains("http-proxy proxy.example.com 8080"))
    #expect(!imported.ovpn.contains("proxy.creds"))
    let summary = OVPNSummary(imported.ovpn)
    #expect(summary.needsUsernamePassword)
    #expect(summary.usesHTTPProxy)
}

@Test func importReadsACredentialsFileAndAPKCS12File() {
    let config = "client\nremote a 1\nauth-user-pass login.txt\npkcs12 me.p12\nca ca.crt\n"
    let files: [String: Data] = ["login.txt": Data("alice\npw\n".utf8), "me.p12": Data([1, 2, 3]),
                                 "ca.crt": Data("-----BEGIN CERTIFICATE-----\nCA\n-----END CERTIFICATE-----\n".utf8)]
    let imported = OVPNImport(config) { files[$0] }
    #expect(imported.username == "alice")
    #expect(imported.password == "pw")
    #expect(imported.pkcs12 == Data([1, 2, 3]))
    #expect(!imported.ovpn.contains("pkcs12"))
    #expect(imported.ovpn.contains("<ca>"))
    #expect(OVPNSummary(imported.ovpn).problem == nil)
}

@Test func pkcs12BundlesConvertWithTheSystemOpenSSL() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("burrow-p12-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    func openssl(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        process.currentDirectoryURL = folder
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
    }
    try openssl(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "k.pem", "-out", "c.pem", "-days", "1",
                 "-subj", "/CN=burrow-test"])
    try openssl(["pkcs12", "-export", "-inkey", "k.pem", "-in", "c.pem", "-out", "t.p12", "-passout", "pass:abc"])
    let data = try Data(contentsOf: folder.appendingPathComponent("t.p12"))

    let contents = try PKCS12.convert(data, password: "abc")
    #expect(contents.certificate.hasPrefix("-----BEGIN CERTIFICATE-----"))
    #expect(contents.key.contains("PRIVATE KEY-----"))
    #expect(throws: PKCS12.ConversionError.wrongPassword) { try PKCS12.convert(data, password: "wrong") }

    let ovpn = OVPNImport.adding(contents, to: "client\nremote a 1")
    let summary = OVPNSummary(ovpn)
    #expect(summary.hasInlineKey)
    #expect(!summary.keyIsEncrypted)
    #expect(summary.problem == nil)
}

@Test func staticKeyAndConcatChallengeAreRecognised() {
    #expect(OVPNSummary("client\nremote a 1\nsecret static.key\n").problem?.contains("Static-key") == true)
    let concat = "client\nremote a 1\nauth-user-pass\nstatic-challenge \"OTP\" 1 concat\n"
    #expect(OVPNSummary(concat).staticChallengeConcat)
    let profile = VPNProfile(name: "c", ovpn: concat, username: "alice", password: "pw", otpMode: .prompt)
    #expect(profile.needsCode)
    // OpenVPN 3 would send SCRV1: the tunnel drops the line and appends the answer itself.
    #expect(!TunnelConfig.ovpn(for: profile).contains("static-challenge"))
    let scrv1 = VPNProfile(name: "s", ovpn: "client\nremote a 1\nauth-user-pass\nstatic-challenge \"OTP\" 1\n")
    #expect(TunnelConfig.ovpn(for: scrv1).contains("static-challenge"))
}

@Test func proxyLoginIsAddedForTheTunnel() {
    var profile = VPNProfile(name: "p", ovpn: "client\nremote a 1\nhttp-proxy proxy.example.com 8080\n",
                             proxyUsername: "puser", proxyPassword: "ppass")
    #expect(TunnelConfig.ovpn(for: profile).hasSuffix("<http-proxy-user-pass>\npuser\nppass\n</http-proxy-user-pass>"))
    profile.proxyUsername = ""
    #expect(!TunnelConfig.ovpn(for: profile).contains("http-proxy-user-pass"))
}

@Test func halvesAndContainment() {
    #expect(net("192.168.1.0/24").halves == [net("192.168.1.0/25"), net("192.168.1.128/25")])
    #expect(net("192.168.1.20").halves == [net("192.168.1.20")])
    #expect(net("0.0.0.0/0").halves == [net("0.0.0.0/1"), net("128.0.0.0/1")])
    #expect(net("10.0.0.0/8").contains(net("10.1.0.0/16")))
    #expect(!net("10.1.0.0/16").contains(net("10.0.0.0/8")))
}

@Test func routePlanAppliesTheChoices() {
    let pushed = [net("192.168.1.0/24"), net("192.168.40.0/24"), net("0.0.0.0/0")]
    let plan = RoutePlan.make(pushed: pushed, viaVPN: [net("192.168.1.20"), net("10.9.0.0/16")],
                              local: [net("192.168.40.0/24")])
    #expect(plan.included == [net("192.168.1.0/24"), net("0.0.0.0/0"), net("192.168.1.20"),
                              net("10.9.0.0/17"), net("10.9.128.0/17")])
    #expect(plan.excluded == [net("192.168.40.0/24")])
}

@Test func routingTableRowsAndLists() {
    let pushed = [net("192.168.1.0/24"), net("192.168.40.0/24"), net("0.0.0.0/0")]
    let local = [(interface: "en0", network: net("192.168.1.0/24"))]
    var rows = RouteChoices.rows(pushed: pushed, local: local, viaVPN: [net("192.168.1.20")], alwaysLocal: [])
    #expect(rows.map(\.id) == ["192.168.1.0/24", "192.168.40.0/24", "192.168.1.20"])
    #expect(rows[0].isClash)
    #expect(rows[0].side == .automatic) // small enough to look for the local devices
    #expect(rows[1].side == .vpn)
    #expect(rows[2].origin == .added)

    // Automatic is the default and isn't stored; a clash decided by hand is.
    #expect(RouteChoices.lists(rows) == (viaVPN: "192.168.1.20", local: ""))
    rows[0].side = .local
    rows[1].side = .local
    #expect(RouteChoices.lists(rows) == (viaVPN: "192.168.1.20", local: "192.168.1.0/24, 192.168.40.0/24"))
    rows[0].side = .vpn
    #expect(RouteChoices.lists(rows).viaVPN == "192.168.1.0/24, 192.168.1.20")

    // A single address sent to the VPN leaves the rest of the range on automatic.
    #expect(RouteChoices.automatic(pushed: pushed, local: local, viaVPN: [net("192.168.1.20")], alwaysLocal: []).count == 1)
    #expect(RouteChoices.automatic(pushed: pushed, local: local, viaVPN: [], alwaysLocal: [net("192.168.1.0/24")]).isEmpty)
    #expect(RouteChoices.undecided(pushed: pushed, local: local, viaVPN: [], alwaysLocal: []).isEmpty)
}

@Test func onlyLargeClashesNeedAChoice() {
    let wide = [(interface: "en0", network: net("10.0.0.0/8"))]
    #expect(RouteChoices.undecided(pushed: [net("10.0.0.0/8")], local: wide, viaVPN: [], alwaysLocal: []).count == 1)
    #expect(RouteChoices.automatic(pushed: [net("10.0.0.0/8")], local: wide, viaVPN: [], alwaysLocal: []).isEmpty)
    let tie = RouteChoices.rows(pushed: [net("10.0.0.0/8")], local: wide, viaVPN: [], alwaysLocal: [])
    #expect(tie.first?.side == .local) // the local network wins a tie
    let narrower = RouteChoices.rows(pushed: [net("10.1.0.0/16")], local: wide, viaVPN: [], alwaysLocal: [])
    #expect(narrower.first?.side == .vpn) // the more specific route wins
    // A /24 inside a wide local network is small enough to split.
    let rows = RouteChoices.rows(pushed: [net("10.1.2.0/24")], local: wide, viaVPN: [], alwaysLocal: [])
    #expect(rows.first?.side == .automatic)
    #expect(rows.first?.splittable == net("10.1.2.0/24"))
}

@Test func subtractingLeavesTheOtherAddresses() {
    let parts = net("192.168.1.0/24").subtracting([net("192.168.1.0"), net("192.168.1.255")])
    #expect(parts.count == 14)
    #expect(parts.reduce(0) { $0 + (1 << (32 - $1.prefix)) } == 254)
    #expect(!parts.contains { $0.contains(net("192.168.1.0")) || $0.contains(net("192.168.1.255")) })
    #expect(net("10.0.0.0/24").subtracting([net("10.0.0.0/16")]).isEmpty)
    #expect(net("10.0.0.0/24").subtracting([net("10.1.0.0/24")]) == [net("10.0.0.0/24")])
}

@Test func automaticKeepsTheFoundDevicesLocal() {
    let range = net("192.168.1.0/24")
    let wifi = LocalDevices(range: range, localNetwork: range, found: [net("192.168.1.1"), net("192.168.1.14"), net("192.168.1.45")])
    let cable = LocalDevices(range: range, localNetwork: range, found: [net("192.168.1.1"), net("192.168.1.30")])
    let plan = RoutePlan.make(pushed: [range, net("10.9.0.0/16")], viaVPN: [net("192.168.1.14")], local: [],
                              split: [wifi, cable])
    func viaVPN(_ address: String) -> Bool { plan.included.contains { $0.contains(net(address)) } }
    #expect(!plan.included.contains(range)) // replaced by the addresses nobody answered on
    #expect(plan.included.contains(net("10.9.0.0/16")))
    #expect(viaVPN("192.168.1.20"))
    #expect(viaVPN("192.168.1.40"))
    #expect(!viaVPN("192.168.1.1"))
    #expect(!viaVPN("192.168.1.30")) // found on the other interface
    #expect(!viaVPN("192.168.1.45"))
    #expect(!viaVPN("192.168.1.0") && !viaVPN("192.168.1.255"))
    #expect(viaVPN("192.168.1.14")) // the user's own entry wins
    #expect(plan.excluded.isEmpty)

    // A choice for the whole range turns automatic off.
    let local = RoutePlan.make(pushed: [range], viaVPN: [], local: [range], split: [wifi])
    #expect(local.included.isEmpty && local.excluded == [range])
}

/// `BURROW_LIVE_SCAN=en0 swift test --filter liveScan` looks for the devices on that interface's network.
@Test func liveScan() async throws {
    guard let interface = ProcessInfo.processInfo.environment["BURROW_LIVE_SCAN"] else { return }
    let network = try #require(LocalNetworks.current().first { $0.interface == interface }?.network)
    let devices = try await LocalDeviceScan.run(RouteClash(vpnRoute: network, localNetwork: network, interface: interface))
    print("found on \(interface):", devices.found.map(\.description).joined(separator: " "))
}

@Test func hostsFileNamesAddresses() async {
    let hosts = HostNames("""
    ##
    127.0.0.1	localhost
    ::1             localhost
    # server
    192.168.1.20 server server.example.local   # build server
    10.0.0.5 nas
    """)
    #expect(hosts.name(of: net("192.168.1.20")) == "server")
    #expect(hosts.label(net("192.168.1.20")) == "192.168.1.20 (server)")
    #expect(hosts.label(net("192.168.1.0/24")) == "192.168.1.0/24")
    #expect(await hosts.addresses(of: "Server") == [net("192.168.1.20")])
    #expect(await hosts.addresses(of: "server.example.local") == [net("192.168.1.20")])
    #expect(await hosts.addresses(of: "nas") == [net("10.0.0.5")])
}

@Test func devicesMessageRoundTrips() {
    let scan = LocalDevices(range: net("192.168.1.0/24"), localNetwork: net("192.168.1.0/24"),
                            found: [net("192.168.1.1"), net("192.168.1.14")])
    #expect(TunnelMessage(TunnelMessage.devices([scan]).data) == .devices([scan]))
    #expect(TunnelMessage(TunnelMessage.devices([]).data) == .devices([]))
}

@Test func routesMessageRoundTrips() {
    let message = TunnelMessage.routes(viaVPN: "192.168.1.20, 10.0.0.0/8", local: "192.168.40.0/24")
    #expect(TunnelMessage(message.data) == message)
}
