import Foundation
import Testing
@testable import BurrowKit

/// An OpenVPN 2 era configuration (Tunnelblick style) with directives OpenVPN 3.11 refuses.
private let legacyConfig = """
client
dev tun
proto udp
remote vpn.example.com 1194
resolv-retry infinite
nobind
persist-key
persist-tun
ns-cert-type server
cipher AES-128-CBC
auth SHA1
comp-lzo
verb 3
log /var/log/openvpn.log
status openvpn-status.log
management 127.0.0.1 7505
management-query-passwords
topology subnet
ping-timer-rem
ncp-disable
auth-user-pass
<ca>
-----BEGIN CERTIFICATE-----
log this-line-is-certificate-data
-----END CERTIFICATE-----
</ca>
"""

@Test func directivesOpenVPN3RefusesAreLeftOutOfTheTunnelCopy() {
    let profile = VPNProfile(name: "legacy", ovpn: legacyConfig)
    #expect(profile.summary.problem == nil)
    let prepared = TunnelConfig.prepared(for: profile)
    let lines = prepared.ovpn.components(separatedBy: "\n")
    for gone in ["log /var/log/openvpn.log", "status openvpn-status.log", "management 127.0.0.1 7505",
                 "management-query-passwords", "topology subnet", "ping-timer-rem", "ncp-disable", "ns-cert-type server"] {
        #expect(!lines.contains(gone), "\(gone) should be left out")
    }
    // What OpenVPN 3 uses stays as it was, and so does the content of inline blocks.
    for kept in ["cipher AES-128-CBC", "auth SHA1", "comp-lzo", "persist-key", "verb 3",
                 "log this-line-is-certificate-data", "remote vpn.example.com 1194"] {
        #expect(lines.contains(kept), "\(kept) should stay")
    }
    #expect(lines.contains("remote-cert-tls server"))
    #expect(prepared.notes.contains("ns-cert-type server → remote-cert-tls server"))
    #expect(prepared.notes.contains("left out management (not used by OpenVPN 3)"))
    // The saved configuration is not changed.
    #expect(profile.ovpn == legacyConfig)
}

@Test func nsCertTypeIsDroppedWhenRemoteCertTLSIsThere() {
    let ovpn = "client\nremote a 1\nremote-cert-tls server\nns-cert-type server\n"
    let prepared = TunnelConfig.prepared(for: VPNProfile(name: "n", ovpn: ovpn))
    #expect(prepared.ovpn.components(separatedBy: "\n").filter { $0.hasPrefix("remote-cert-tls") }.count == 1)
    #expect(!prepared.ovpn.contains("ns-cert-type"))
}

@Test func directivesInsideConnectionBlocksAreAdaptedToo() {
    let ovpn = "client\n<connection>\nremote a 1 udp\nhttp-proxy-retry\n</connection>\n"
    let prepared = TunnelConfig.prepared(for: VPNProfile(name: "c", ovpn: ovpn))
    #expect(prepared.ovpn == "client\n<connection>\nremote a 1 udp\n</connection>\n")
}

@Test func unsafeDirectivesMakeTheConfigurationUnusable() {
    let socks = OVPNSummary("client\nremote a 1\nsocks-proxy 127.0.0.1 1080\n")
    #expect(socks.problem?.contains("socks-proxy") == true)
    #expect(socks.problem?.contains("SOCKS") == true)
    #expect(OVPNSummary("client\nremote a 1\nfragment 1300\n").problem?.contains("fragment") == true)
    #expect(OVPNSummary("client\nremote a 1\nverify-hash 00:11\n").problem?.contains("verify-hash") == true)
    #expect(OVPNSummary("client\nremote a 1\nns-cert-type client\n").problem?.contains("remote-cert-tls") == true)
    // Commented out or inside a certificate, it doesn't count.
    #expect(OVPNSummary("client\nremote a 1\n# socks-proxy 127.0.0.1 1080\n").problem == nil)
    #expect(OVPNSummary("client\nremote a 1\n<ca>\nfragment 1300\n</ca>\n").problem == nil)
}

@Test func aModernConfigurationIsPassedThroughUnchanged() {
    let ovpn = "client\ndev tun\nremote a 1\nremote-cert-tls server\ncipher AES-256-GCM\nverb 3\n<ca>\nx\n</ca>"
    let prepared = TunnelConfig.prepared(for: VPNProfile(name: "m", ovpn: ovpn))
    #expect(prepared.ovpn == ovpn)
    #expect(prepared.notes.isEmpty)
}

@Test func anUnusableDataCipherIsFoundInTheLog() {
    #expect(OpenVPN3Options.unusableCipher(
        inLogLine: "Client exception in transport_recv: mbedtls_cipher_error: BF-CBC: not usable") == "BF-CBC")
    #expect(OpenVPN3Options.unusableCipher(inLogLine: "Session is ACTIVE") == nil)
    #expect(OpenVPN3Options.unusableCipher(inLogLine: "mbedtls_cipher_error: mbedtls_cipher_setup") == nil)
}
