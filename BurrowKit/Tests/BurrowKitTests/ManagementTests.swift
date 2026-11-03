import Foundation
import Testing
@testable import BurrowKit

// Lines as they appear in the user's OpenVPN log and in OpenVPN's management-notes.txt.

@Test func parsesStateNotifications() {
    #expect(ManagementParser.parse(">STATE:1792478462,RESOLVE,,,,,,\r\n") == .state(StateUpdate(
        time: Date(timeIntervalSince1970: 1_792_478_462), name: "RESOLVE", detail: "", localIP: "", remoteIP: "")))
    let connected = ManagementParser.parse(">STATE:1792478481,CONNECTED,SUCCESS,10.8.0.2,203.0.113.10,443,172.20.10.2,63192")
    #expect(connected == .state(StateUpdate(
        time: Date(timeIntervalSince1970: 1_792_478_481), name: "CONNECTED", detail: "SUCCESS",
        localIP: "10.8.0.2", remoteIP: "203.0.113.10")))
}

@Test func parsesStateCommandReply() {
    guard case .state(let update) = ManagementParser.parse("1792478447,CONNECTING,,,,,,") else {
        Issue.record("not a state line")
        return
    }
    #expect(update.name == "CONNECTING")
    #expect(ManagementParser.parse("END") == .other("END"))
}

@Test func parsesPasswordPrompts() {
    #expect(ManagementParser.parse(">PASSWORD:Need 'Auth' username/password")
        == .needPassword(PasswordRequest(type: "Auth", staticChallenge: nil)))
    #expect(ManagementParser.parse(">PASSWORD:Need 'Auth' username/password SC:1,Enter your OTP")
        == .needPassword(PasswordRequest(type: "Auth", staticChallenge: .init(echo: true, text: "Enter your OTP"))))
    #expect(ManagementParser.parse(">PASSWORD:Need 'Private Key' password")
        == .needPassword(PasswordRequest(type: "Private Key", staticChallenge: nil)))
    #expect(ManagementParser.parse(">PASSWORD:Verification Failed: 'Auth'")
        == .verificationFailed(type: "Auth", detail: ""))
    #expect(ManagementParser.parse(">PASSWORD:Verification Failed: 'Auth' ['CRV1:R,E:Om01u7Fh4LrGBS7uh0SWmzwabUiGiW6l:YWJv:Enter PIN']")
        == .verificationFailed(type: "Auth", detail: "['CRV1:R,E:Om01u7Fh4LrGBS7uh0SWmzwabUiGiW6l:YWJv:Enter PIN']"))
}

@Test func parsesMiscellaneousLines() {
    #expect(ManagementParser.parse(">HOLD:Waiting for hold release:0") == .hold)
    #expect(ManagementParser.parse(">BYTECOUNT:12345,678") == .byteCount(received: 12345, sent: 678))
    #expect(ManagementParser.parse("SUCCESS: pid=52237") == .pid(52237))
    #expect(ManagementParser.parse("ENTER PASSWORD:SUCCESS: password is correct") == .success("password is correct"))
    #expect(ManagementParser.parse(">INFO:OpenVPN Management Interface Version 5 -- type 'help' for more info")
        == .info("OpenVPN Management Interface Version 5 -- type 'help' for more info"))
    #expect(ManagementParser.parse(">FATAL:Cannot open TUN/TAP dev") == .fatal("Cannot open TUN/TAP dev"))
    #expect(ManagementParser.parse("ERROR: unknown command") == .error("unknown command"))
}

@Test func escapesLikeTunnelblick() {
    #expect(ManagementCommand.escape("a\"b\\c\r\nd") == "a\\\"b\\\\cd")
    #expect(ManagementCommand.username("alice") == "username \"Auth\" \"alice\"")
    #expect(ManagementCommand.password("pa\"ss123456") == "password \"Auth\" \"pa\\\"ss123456\"")
    #expect(ManagementCommand.staticChallengeResponse(password: "pass", response: "123456")
        == "password \"Auth\" \"SCRV1:cGFzcw==:MTIzNDU2\"")
    #expect(ManagementCommand.fitsLimit(String(repeating: "x", count: 250)))
    #expect(!ManagementCommand.fitsLimit(String(repeating: "\"", count: 126)))
}
