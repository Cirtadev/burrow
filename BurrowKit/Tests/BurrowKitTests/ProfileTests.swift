import Foundation
import Testing
@testable import BurrowKit

// The shape of a firewall appliance's generated client config, with placeholder keys.
private let applianceConfig = """
client
dev tun
proto tcp
verify-x509-name "C=NA, ST=NA, L=NA, O=NA, OU=NA, CN=vpn.example.com, emailAddress=na@example.com"
route remote_host 255.255.255.255 net_gateway
resolv-retry infinite
nobind
persist-key
persist-tun
<ca>
-----BEGIN CERTIFICATE-----
remote not-a-directive.example 1
-----END CERTIFICATE-----
</ca>
<cert>
-----BEGIN CERTIFICATE-----
-----END CERTIFICATE-----
</cert>
<key>
-----BEGIN PRIVATE KEY-----
-----END PRIVATE KEY-----
</key>
auth-user-pass
cipher AES-128-CBC
auth SHA256
;can_save no
;otp no
route-delay 4
verb 3
reneg-sec 0
remote vpn.example.com 443
"""

@Test func summarizesApplianceConfig() {
    let summary = OVPNSummary(applianceConfig)
    #expect(summary.remoteHost == "vpn.example.com")
    #expect(summary.remotePort == 443)
    #expect(summary.proto == "tcp")
    #expect(summary.isClient)
    #expect(summary.needsUsernamePassword)
    #expect(summary.hasInlineKey)
    #expect(summary.problem == nil)
    #expect(summary.serverDescription == "vpn.example.com:443 (TCP)")
}

@Test func remoteLineCanCarryTheProtocol() {
    let summary = OVPNSummary("client\nremote 1.2.3.4 1194 udp\n")
    #expect(summary.proto == "udp")
    #expect(summary.remotePort == 1194)
}

@Test func rejectsFilesThatAreNotClientConfigs() {
    #expect(OVPNSummary("dev tun\n").problem != nil)
    #expect(OVPNSummary("client\n").problem != nil)
}

@Test func automaticModeNeedsAValidSecret() {
    var profile = VPNProfile(name: "x", ovpn: applianceConfig, username: "alice", password: "pw", otpSecret: "not base32!")
    #expect(!profile.isUsable)
    profile.otpSecret = "JBSWY3DPEHPK3PXP"
    #expect(profile.isUsable)
    #expect(profile.isOneClick)
}

@Test func promptModeAsksForTheCodeAndMaybeThePassword() {
    var profile = VPNProfile(name: "x", ovpn: applianceConfig, username: "alice", password: "pw", otpMode: .prompt)
    #expect(profile.isUsable)
    #expect(profile.needsCode)
    #expect(!profile.needsPassword)
    #expect(!profile.isOneClick)
    profile.savePassword = false
    #expect(profile.needsPassword)
}

@Test func decodesTheSingleProfileFormat() throws {
    let json = #"{"name":"office","ovpn":"client\nremote a 1\n","username":"alice","password":"pw","otpSecret":"JBSWY3DPEHPK3PXP"}"#
    let profile = try JSONDecoder().decode(VPNProfile.self, from: Data(json.utf8))
    #expect(profile.otpMode == .automatic)
    #expect(profile.savePassword)
    #expect(profile.isOneClick)
}

@Test func parsesATunnelblickDump() {
    let dump = """
    \(TunnelblickImport.marker)config.ovpn
    client
    remote vpn.example.com 1194
    ca ca.crt
    tls-auth "ta.key" 1

    \(TunnelblickImport.marker)ca.crt
    -----BEGIN CERTIFICATE-----
    AAA
    -----END CERTIFICATE-----

    \(TunnelblickImport.marker)ta.key
    KEYDATA

    """
    let files = TunnelblickImport.parseDump(dump)
    #expect(Set(files.keys) == ["config.ovpn", "ca.crt", "ta.key"])
    let config = TunnelblickImport.configuration(fromFiles: files)
    #expect(config == """
    client
    remote vpn.example.com 1194
    <ca>
    -----BEGIN CERTIFICATE-----
    AAA
    -----END CERTIFICATE-----
    </ca>
    <tls-auth>
    KEYDATA
    </tls-auth>
    key-direction 1

    """)
}

@Test func inlineLeavesExistingBlocksAlone() {
    let config = "client\n<ca>\nca not-a-file\n</ca>\nremote a 1\n"
    #expect(TunnelblickImport.inline(config, files: ["not-a-file": "X"]) == config)
}

@Test func dumpCommandQuotesThePath() {
    #expect(TunnelblickImport.dumpCommand(for: "/a b/it's") .hasPrefix(#"cd '/a b/it'\''s' && "#))
}

@Test func reconnectPolicyFollowsErrorCodes() {
    #expect(TunnelFailure.allowsReconnect(nil))
    #expect(TunnelFailure.allowsReconnect(TunnelFailure.error(TunnelFailure.connectionFailed, "x")))
    #expect(!TunnelFailure.allowsReconnect(TunnelFailure.error(TunnelFailure.credentialsRejected, "x")))
    #expect(TunnelFailure.allowsReconnect(NSError(domain: "other", code: 1)))
}

@Test func startRequestSurvivesTheOptionsDictionary() throws {
    let profile = VPNProfile(name: "office", ovpn: applianceConfig, username: "alice", password: "pw",
                             otpSecret: "JBSWY3DPEHPK3PXP")
    let sent = TunnelStartRequest(profile: profile)
    let received = try #require(TunnelStartRequest(options: sent.options))
    #expect(received == sent)
    #expect(received.profile.ovpn == applianceConfig)
    #expect(received.profile.otpSecret == "JBSWY3DPEHPK3PXP")
    #expect(received.failure == nil)
}

@Test func startedWithoutOptionsHasNoRequest() {
    #expect(TunnelStartRequest(options: nil) == nil)
    #expect(TunnelStartRequest(options: [TunnelOption.profileID: UUID().uuidString as NSString]) == nil)
    #expect(!TunnelFailure.allowsReconnect(TunnelFailure.startedWithoutAppError))
}

@Test func promptModeSendsTheTypedCodeButNotTheSecret() throws {
    let profile = VPNProfile(name: "lab", ovpn: applianceConfig, username: "alice", password: "pw", otpMode: .prompt,
                             otpSecret: "JBSWY3DPEHPK3PXP")
    let sent = TunnelStartRequest(profile: profile, code: "123456")
    #expect(sent.options[TunnelOption.otpSecret] == nil)
    let received = try #require(TunnelStartRequest(options: sent.options))
    #expect(received.code == "123456")
    #expect(received.profile.otpSecret.isEmpty)
    #expect(received.failure == nil)

    let noCode = try #require(TunnelStartRequest(options: TunnelStartRequest(profile: profile, code: "").options))
    #expect(noCode.failure?.code == TunnelFailure.codeNeeded)
}

@Test func typedPasswordWinsAndAnUnsavedOneIsNeverSent() throws {
    var profile = VPNProfile(name: "lab", ovpn: applianceConfig, username: "alice", password: "stale", savePassword: false,
                             otpSecret: "JBSWY3DPEHPK3PXP")
    #expect(TunnelStartRequest(profile: profile).profile.password.isEmpty)
    #expect(TunnelStartRequest(profile: profile).failure?.code == TunnelFailure.passwordNeeded)
    #expect(TunnelStartRequest(profile: profile, password: "typed").profile.password == "typed")
    profile.savePassword = true
    #expect(TunnelStartRequest(profile: profile).profile.password == "stale")
}

@Test func unusableConfigurationIsReportedBeforeConnecting() {
    let request = TunnelStartRequest(profile: VPNProfile(name: "x", ovpn: "dev tun\n", username: "alice", password: "pw"))
    #expect(request.failure?.code == TunnelFailure.notConfigured)
}
