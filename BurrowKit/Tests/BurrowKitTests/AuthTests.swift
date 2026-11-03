import Foundation
import Testing
@testable import BurrowKit

private let passwordConfig = "client\nremote vpn.example.com 1194\nauth-user-pass\n<key>\n-----BEGIN PRIVATE KEY-----\n-----END PRIVATE KEY-----\n</key>\n"
private let certificateConfig = "client\nremote vpn.example.com 1194\n<cert>\nX\n</cert>\n<key>\n-----BEGIN PRIVATE KEY-----\n-----END PRIVATE KEY-----\n</key>\n"

@Test func tokenizesLikeOpenVPN() {
    #expect(OVPNSummary.tokens(#"static-challenge "Enter your PIN" 1"#) == ["static-challenge", "Enter your PIN", "1"])
    #expect(OVPNSummary.tokens(#"verify-x509-name 'C=NA, CN=x' name"#) == ["verify-x509-name", "C=NA, CN=x", "name"])
    #expect(OVPNSummary.tokens(#"ca "my \"ca\".crt""#) == ["ca", #"my "ca".crt"#])
    #expect(OVPNSummary.tokens("  remote\ta.example 443  ") == ["remote", "a.example", "443"])
    #expect(OVPNSummary.tokens(#"x """#) == ["x", ""])
}

@Test func readsTheStaticChallenge() {
    let summary = OVPNSummary(passwordConfig + #"static-challenge "Enter Google Authenticator Code" 1"# + "\n")
    #expect(summary.staticChallenge == "Enter Google Authenticator Code")
    #expect(summary.staticChallengeEcho)
    #expect(OVPNSummary(passwordConfig).staticChallenge == nil)
}

@Test func spotsEncryptedKeysPKCS12AndMissingFiles() {
    let pkcs8 = "client\nremote a 1\n<key>\n-----BEGIN ENCRYPTED PRIVATE KEY-----\nAAA\n-----END ENCRYPTED PRIVATE KEY-----\n</key>\n"
    #expect(OVPNSummary(pkcs8).keyIsEncrypted)
    let pem = "client\nremote a 1\n<key>\n-----BEGIN RSA PRIVATE KEY-----\nProc-Type: 4,ENCRYPTED\n-----END RSA PRIVATE KEY-----\n</key>\n"
    #expect(OVPNSummary(pem).keyIsEncrypted)
    #expect(!OVPNSummary(passwordConfig).keyIsEncrypted)

    #expect(OVPNSummary("client\nremote a 1\npkcs12 me.p12\n").problem?.contains("PKCS#12") == true)
    #expect(OVPNSummary("client\nremote a 1\n<pkcs12>\nAAA\n</pkcs12>\n").usesPKCS12)

    let referring = OVPNSummary("client\nremote a 1\nca ca.crt\ntls-auth \"ta.key\" 1\ntls-crypt [inline]\nkey-direction 1\n")
    #expect(referring.missingFiles == ["ca.crt", "ta.key"])
    #expect(referring.problem?.contains("ca.crt") == true)
}

@Test func inlinesFilesFromTheImportFolder() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("burrow-import-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try "-----BEGIN CERTIFICATE-----\nAAA\n-----END CERTIFICATE-----\n".write(
        to: folder.appendingPathComponent("ca.crt"), atomically: true, encoding: .utf8)
    let inlined = TunnelblickImport.inline("client\nremote a 1\nca ca.crt\ncert missing.crt\n", from: folder)
    #expect(inlined.contains("<ca>\n-----BEGIN CERTIFICATE-----\nAAA\n-----END CERTIFICATE-----\n</ca>"))
    #expect(OVPNSummary(inlined).missingFiles == ["missing.crt"])
}

@Test func certificateOnlyNeedsNoAccount() {
    let profile = VPNProfile(name: "cert", ovpn: certificateConfig, savePassword: false, otpMode: .automatic)
    #expect(!profile.usesPassword)
    #expect(profile.effectiveOTPMode == .off)
    #expect(profile.problem == nil)
    #expect(!profile.needsPassword)
    #expect(profile.isOneClick)
    let request = TunnelStartRequest(profile: profile)
    #expect(request.failure == nil)
    #expect(request.options[TunnelOption.otpSecret] == nil)
}

@Test func noCodeModeIsPlainUsernameAndPassword() {
    var profile = VPNProfile(name: "plain", ovpn: passwordConfig, username: "alice", password: "pw", otpMode: .off)
    #expect(profile.problem == nil)
    #expect(profile.upFrontCode == .none)
    #expect(profile.isOneClick)
    #expect(TunnelStartRequest(profile: profile).failure == nil)
    profile.savePassword = false
    #expect(!profile.isOneClick)
    #expect(TunnelStartRequest(profile: profile).failure?.code == TunnelFailure.passwordNeeded)
}

@Test func codeDeliveryDecidesWhenTheCodeIsAskedFor() {
    var profile = VPNProfile(name: "x", ovpn: passwordConfig, username: "alice", password: "pw", otpMode: .prompt)
    #expect(profile.upFrontCode == .typed)
    #expect(profile.needsCode)
    profile.codeDelivery = .challenge
    // The server asks later; the sign-in window shows its question then.
    #expect(profile.upFrontCode == .none)
    #expect(!profile.needsCode)
    #expect(!profile.isOneClick)
    #expect(!profile.asksBeforeConnecting)
    #expect(TunnelStartRequest(profile: profile).failure == nil)

    profile.ovpn = passwordConfig + #"static-challenge "PIN" 0"# + "\n"
    #expect(profile.upFrontCode == .typed)
    profile.otpMode = .off
    #expect(profile.needsCode)
    profile.otpMode = .automatic
    profile.otpSecret = "JBSWY3DPEHPK3PXP"
    #expect(profile.upFrontCode == .generated)
    #expect(profile.answersChallenges)
}

@Test func encryptedKeyAsksForThePassphrase() throws {
    let ovpn = "client\nremote a 1\n<key>\n-----BEGIN ENCRYPTED PRIVATE KEY-----\nAAA\n-----END ENCRYPTED PRIVATE KEY-----\n</key>\n"
    var profile = VPNProfile(name: "k", ovpn: ovpn)
    #expect(profile.needsPassphrase)
    #expect(!profile.isOneClick)
    #expect(TunnelStartRequest(profile: profile).failure?.code == TunnelFailure.passphraseNeeded)
    let typed = try #require(TunnelStartRequest(options: TunnelStartRequest(profile: profile, passphrase: "secret").options))
    #expect(typed.profile.keyPassphrase == "secret")
    #expect(typed.failure == nil)
    profile.keyPassphrase = "saved"
    #expect(profile.isOneClick)
    profile.savePassword = false
    #expect(TunnelStartRequest(profile: profile).profile.keyPassphrase.isEmpty)
}

@Test func parsesADynamicChallenge() throws {
    let cookie = "CRV1:R,E:Om01u7Fh4LrGBS7uh0SWmzwabUiGiW6l:" + Data("alice".utf8).base64EncodedString() + ":Enter the code: we sent it by SMS"
    let challenge = try #require(DynamicChallenge(cookie: cookie))
    #expect(challenge.stateID == "Om01u7Fh4LrGBS7uh0SWmzwabUiGiW6l")
    #expect(challenge.username == "alice")
    #expect(challenge.text == "Enter the code: we sent it by SMS")
    #expect(challenge.echo)
    #expect(challenge.responseRequired)
    #expect(DynamicChallenge(cookie: "CRV1::state:YWJv:") != nil)
    #expect(DynamicChallenge(cookie: "SCRV1:abc") == nil)
    #expect(DynamicChallenge(cookie: "CRV1:R:state:not base64!:x") == nil)
}

@Test func parsesServerInfoMessages() {
    #expect(ServerInfo("OPEN_URL:https://sso.example.com/login?s=1:2") ==
            .webAuth(URL(string: "https://sso.example.com/login?s=1:2")!, flags: []))
    #expect(ServerInfo("WEB_AUTH::https://sso.example.com/x") == .webAuth(URL(string: "https://sso.example.com/x")!, flags: []))
    #expect(ServerInfo("WEB_AUTH:hidden,external:https://a.example/") ==
            .webAuth(URL(string: "https://a.example/")!, flags: ["hidden", "external"]))
    #expect(ServerInfo("CR_TEXT:R,E:Enter your token: now") == .crText(text: "Enter your token: now", echo: true, responseRequired: true))
    #expect(ServerInfo("CR_TEXT::Approve on your phone") == .crText(text: "Approve on your phone", echo: false, responseRequired: false))
    // Only web pages: nothing that would open a file or another app.
    #expect(ServerInfo("OPEN_URL:file:///etc/passwd") == .other)
    #expect(ServerInfo("OPEN_URL:x-apple.systempreferences:com.apple") == .other)
    #expect(ServerInfo("WEB_AUTH:https://missing-flags.example") == .other)
    #expect(ServerInfo("Welcome to the office VPN") == .other)
    #expect(ServerInfo.crResponse("123456") == "CR_RESPONSE,MTIzNDU2")
}

@Test func tunnelMessagesRoundTrip() {
    for message in [TunnelMessage.snapshot, .log, .answer(id: 3, response: "line one\nline two")] {
        #expect(TunnelMessage(message.data) == message)
    }
    #expect(TunnelMessage(Data("anything".utf8)) == .snapshot)
}

@Test func newFieldsSurviveStorageAndTheTunnel() throws {
    let profile = VPNProfile(name: "x", ovpn: passwordConfig, username: "alice", password: "pw", otpMode: .off,
                             codeDelivery: .challenge, keyPassphrase: "kp")
    let decoded = try JSONDecoder().decode(VPNProfile.self, from: JSONEncoder().encode(profile))
    #expect(decoded == profile)
    let received = try #require(TunnelStartRequest(options: TunnelStartRequest(profile: profile).options))
    #expect(received.profile.codeDelivery == .challenge)
    #expect(received.profile.otpMode == .off)
    #expect(received.profile.keyPassphrase == "kp")
}

@Test func snapshotCarriesTheQuestionAndThePage() throws {
    let snapshot = TunnelSnapshot(phase: "Waiting", challenge: TunnelChallenge(id: 1, kind: .crText, text: "PIN?", echo: false,
                                                                             responseRequired: true),
                                  webAuthURL: "https://sso.example.com")
    let decoded = try JSONDecoder().decode(TunnelSnapshot.self, from: JSONEncoder().encode(snapshot))
    #expect(decoded == snapshot)
}
