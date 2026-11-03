import Foundation
import Testing
@testable import BurrowKit

// RFC 6238 appendix B test vectors (8 digits).
private let vectors: [(TimeInterval, String, String, String)] = [
    (59, "94287082", "46119246", "90693936"),
    (1_111_111_109, "07081804", "68084774", "25091201"),
    (1_111_111_111, "14050471", "67062674", "99943326"),
    (1_234_567_890, "89005924", "91819424", "93441116"),
    (2_000_000_000, "69279037", "90698825", "38618901"),
    (20_000_000_000, "65353130", "77737706", "47863826"),
]

@Test func rfc6238Vectors() {
    let sha1 = TOTP(secret: Data("12345678901234567890".utf8), digits: 8, algorithm: .sha1)
    let sha256 = TOTP(secret: Data("12345678901234567890123456789012".utf8), digits: 8, algorithm: .sha256)
    let sha512 = TOTP(
        secret: Data("1234567890123456789012345678901234567890123456789012345678901234".utf8),
        digits: 8, algorithm: .sha512)
    for (time, expected1, expected256, expected512) in vectors {
        let date = Date(timeIntervalSince1970: time)
        #expect(sha1.code(at: date) == expected1)
        #expect(sha256.code(at: date) == expected256)
        #expect(sha512.code(at: date) == expected512)
    }
}

@Test func base32SecretParses() throws {
    let totp = try TOTP(parsing: "gezd gnbv-gy3t qojq gezd gnbv gy3t qojq")
    #expect(totp.secret == Data("12345678901234567890".utf8))
    #expect(totp.digits == 6)
    #expect(totp.code(at: Date(timeIntervalSince1970: 59)) == "287082")
}

@Test func otpauthURIParses() throws {
    let totp = try TOTP(parsing: "otpauth://totp/Example:alice?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&issuer=Example&digits=8&period=60&algorithm=SHA256")
    #expect(totp.digits == 8)
    #expect(totp.period == 60)
    #expect(totp.algorithm == .sha256)
}

@Test func badSecretsAreRejected() {
    #expect(throws: TOTP.ParseError.empty) { try TOTP(parsing: "  ") }
    #expect(throws: TOTP.ParseError.notBase32) { try TOTP(parsing: "not base32!") }
    #expect(throws: (any Error).self) { try TOTP(parsing: "otpauth://hotp/x?secret=GEZDGNBV&counter=1") }
}

@Test func secondsRemainingCountsDown() {
    let totp = TOTP(secret: Data([1]))
    #expect(totp.secondsRemaining(at: Date(timeIntervalSince1970: 60)) == 30)
    #expect(totp.secondsRemaining(at: Date(timeIntervalSince1970: 89.5)) == 1)
}

@Test func schedulerNeverReusesAStep() {
    let totp = TOTP(secret: Data("12345678901234567890".utf8))
    var scheduler = OTPScheduler()
    let now = Date(timeIntervalSince1970: 999_999_995) // 25 s left in step 33333333
    guard case .send(_, let counter) = scheduler.decide(totp, now: now) else {
        Issue.record("expected a code")
        return
    }
    scheduler.markUsed(counter)
    #expect(scheduler.decide(totp, now: now.addingTimeInterval(10)) == .wait(15.25))
    if case .send(_, let next) = scheduler.decide(totp, now: now.addingTimeInterval(26)) {
        #expect(next == counter + 1)
    } else {
        Issue.record("expected the next step's code")
    }
}

@Test func schedulerWaitsWhenCodeIsAboutToExpire() {
    let totp = TOTP(secret: Data("12345678901234567890".utf8))
    let decision = OTPScheduler().decide(totp, now: Date(timeIntervalSince1970: 1_000_000_019))
    #expect(decision == .wait(1.25))
}

@Test func schedulerIgnoresAFutureStepAfterAClockChange() {
    let totp = TOTP(secret: Data("12345678901234567890".utf8))
    let now = Date(timeIntervalSince1970: 999_999_995)
    let scheduler = OTPScheduler(lastUsedCounter: totp.counter(at: now) + 500)
    if case .wait = scheduler.decide(totp, now: now) { Issue.record("should not wait for a step hours away") }
}
