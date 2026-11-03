import Foundation
import Testing
@testable import BurrowKit

@Test func parsesHostsAndRanges() throws {
    let host = try #require(IPv4Network("192.168.1.20"))
    #expect(host.prefix == 32)
    #expect(host.description == "192.168.1.20")
    #expect(host.maskString == "255.255.255.255")
    let range = try #require(IPv4Network(" 192.168.1.77/24 "))
    #expect(range.description == "192.168.1.0/24")
    #expect(range.maskString == "255.255.255.0")
    #expect(IPv4Network(address: "192.168.40.0", mask: "255.255.255.0") == IPv4Network("192.168.40.0/24"))
    for bad in ["", "192.168.1", "192.168.1.300", "server", "10.0.0.0/33", "1.2.3.4/x"] {
        #expect(IPv4Network(bad) == nil, "\(bad)")
    }
}

@Test func parsesTheSettingsList() {
    let parsed = IPv4Network.parseList("192.168.1.20, 192.168.1.40\n10.1.0.0/16;server 192.168.1.20")
    #expect(parsed.networks.map(\.description) == ["192.168.1.20", "192.168.1.40", "10.1.0.0/16"])
    #expect(parsed.invalid == ["server"])
    #expect(IPv4Network.parseList("  ").networks.isEmpty)
}

@Test func overlapCoversContainmentBothWays() throws {
    let lan = try #require(IPv4Network("192.168.1.0/24"))
    #expect(lan.overlaps(try #require(IPv4Network("192.168.1.20"))))
    #expect(try #require(IPv4Network("192.168.1.20")).overlaps(lan))
    #expect(lan.overlaps(try #require(IPv4Network("192.168.0.0/16"))))
    #expect(!lan.overlaps(try #require(IPv4Network("192.168.40.0/24"))))
}

@Test func findsTheClashFromTodaysNetwork() throws {
    // The VPN pushes 192.168.1.0/24, .2.0/24 and .10.0/24; the wired network is 192.168.1.0/24.
    let routes = ["192.168.1.0/24", "192.168.40.0/24", "192.168.30.0/24", "192.168.1.20", "0.0.0.0/0"]
        .compactMap(IPv4Network.init)
    let local = [(interface: "en0", network: try #require(IPv4Network("192.168.1.175/24")))]
    let clashes = RouteClash.find(vpnRoutes: routes, local: local)
    #expect(clashes == [RouteClash(vpnRoute: try #require(IPv4Network("192.168.1.0/24")),
                                   localNetwork: try #require(IPv4Network("192.168.1.0/24")), interface: "en0")])
    let hotspot = [(interface: "en0", network: try #require(IPv4Network("172.20.10.2/28")))]
    #expect(RouteClash.find(vpnRoutes: routes, local: hotspot).isEmpty)
}

@Test func alwaysViaVPNTravelsToTheTunnel() throws {
    let profile = VPNProfile(name: "office", ovpn: "client\nremote vpn.example.com 443\n", username: "alice",
                             password: "pw", otpSecret: "JBSWY3DPEHPK3PXP", alwaysViaVPN: "192.168.1.20, 192.168.1.40")
    let received = try #require(TunnelStartRequest(options: TunnelStartRequest(profile: profile).options))
    #expect(received.profile.alwaysViaVPN == "192.168.1.20, 192.168.1.40")
    let decoded = try JSONDecoder().decode(VPNProfile.self, from: JSONEncoder().encode(profile))
    #expect(decoded.alwaysViaVPN == profile.alwaysViaVPN)
}
