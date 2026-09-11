import XCTest
@testable import SecretBox

final class TOTPEngineTests: XCTestCase {
    // RFC 6238 Appendix B seed (ASCII "12345678901234567890"), base32-encoded.
    let rfcSeed = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"

    func testRFC6238SHA1EightDigitVectors() {
        // (unix time, expected 8-digit code) straight from RFC 6238 Appendix B.
        let vectors: [(TimeInterval, String)] = [
            (59, "94287082"),
            (1111111109, "07081804"),
            (1111111111, "14050471"),
            (1234567890, "89005924"),
            (2000000000, "69279037"),
            (20000000000, "65353130"),
        ]
        for (timestamp, expected) in vectors {
            let secret = TOTPSecret(secret: rfcSeed, digits: 8, period: 30, algorithm: .sha1)
            XCTAssertEqual(
                TOTPEngine.code(for: secret, at: Date(timeIntervalSince1970: timestamp)),
                expected,
                "vector at T=\(Int(timestamp))"
            )
        }
    }

    func testSixDigitCodeMatchesTruncatedVector() {
        let secret = TOTPSecret(secret: rfcSeed, digits: 6, period: 30, algorithm: .sha1)
        XCTAssertEqual(TOTPEngine.code(for: secret, at: Date(timeIntervalSince1970: 59)), "287082")
    }

    func testCodesRotatePerPeriodBoundary() {
        let secret = TOTPSecret(secret: rfcSeed)
        let before = TOTPEngine.code(for: secret, at: Date(timeIntervalSince1970: 59.9))
        let after = TOTPEngine.code(for: secret, at: Date(timeIntervalSince1970: 60.1))
        XCTAssertEqual(before, "287082")
        XCTAssertNotEqual(before, after, "the counter step at T=59/60 must produce a new code")
    }

    func testCustomPeriodAndAlgorithm() {
        // RFC 6238 Appendix B SHA256 seed (ASCII "12345678901234567890123456789012"),
        // 8 digits, T=1111111109 → 68084774.
        let sha256Secret = TOTPSecret(
            secret: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQGEZA====",
            digits: 8,
            period: 30,
            algorithm: .sha256
        )
        XCTAssertEqual(
            TOTPEngine.code(for: sha256Secret, at: Date(timeIntervalSince1970: 1111111109)),
            "68084774"
        )
    }

    func testBase32DecodingTolerance() {
        // "JBSWY3DPEHPK3PXP" is the canonical "Hello!" + deadbeef example.
        let expected = Data([0x48, 0x65, 0x6C, 0x6C, 0x6F, 0x21, 0xDE, 0xAD, 0xBE, 0xEF])
        XCTAssertEqual(TOTPEngine.base32Decode("JBSWY3DPEHPK3PXP"), expected)
        XCTAssertEqual(TOTPEngine.base32Decode("jbswy3dpehpk3pxp"), expected, "lowercase must be accepted")
        XCTAssertEqual(TOTPEngine.base32Decode("jbsw y3dp ehpk 3pxp"), expected, "embedded spaces must be ignored")
        XCTAssertEqual(TOTPEngine.base32Decode("JBSWY3DPEHPK3PXP===="), expected, "padding must be tolerated")
        XCTAssertNil(TOTPEngine.base32Decode("1NVAL!D"))
        XCTAssertNil(TOTPEngine.base32Decode(""))
    }

    func testParseFullOTPAuthURI() {
        let uri = "otpauth://totp/GitHub:ops-bot%40example.com?secret=JBSWY3DPEHPK3PXP&issuer=GitHub&digits=8&period=60&algorithm=SHA256"
        let parsed = TOTPEngine.parseOTPAuthURI(uri)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.secret, "JBSWY3DPEHPK3PXP")
        XCTAssertEqual(parsed?.issuer, "GitHub")
        XCTAssertEqual(parsed?.account, "ops-bot@example.com")
        XCTAssertEqual(parsed?.digits, 8)
        XCTAssertEqual(parsed?.period, 60)
        XCTAssertEqual(parsed?.algorithm, .sha256)
    }

    func testParseMinimalURIDefaultsAndLabelFallback() {
        let parsed = TOTPEngine.parseOTPAuthURI("otpauth://totp/?secret=jbswy3dpehpk3pxp")
        XCTAssertEqual(parsed?.secret, "jbswy3dpehpk3pxp")
        XCTAssertEqual(parsed?.digits, 6)
        XCTAssertEqual(parsed?.period, 30)
        XCTAssertEqual(parsed?.algorithm, .sha1)

        let labeled = TOTPEngine.parseOTPAuthURI("otpauth://totp/Example:alice?secret=JBSWY3DPEHPK3PXP")
        XCTAssertEqual(labeled?.issuer, "Example")
        XCTAssertEqual(labeled?.account, "alice")
    }

    func testParseRejectsInvalidURIs() {
        XCTAssertNil(TOTPEngine.parseOTPAuthURI("otpauth://hotp/alice?secret=JBSWY3DPEHPK3PXP"), "counter-based hotp is out of scope")
        XCTAssertNil(TOTPEngine.parseOTPAuthURI("otpauth://totp/alice"), "missing secret")
        XCTAssertNil(TOTPEngine.parseOTPAuthURI("otpauth://totp/alice?secret=NOTBASE32!!"))
        XCTAssertNil(TOTPEngine.parseOTPAuthURI("otpauth://totp/alice?secret=JBSWY3DPEHPK3PXP&digits=9"), "digits out of range")
        XCTAssertNil(TOTPEngine.parseOTPAuthURI("otpauth://totp/alice?secret=JBSWY3DPEHPK3PXP&period=5"), "period out of range")
        XCTAssertNil(TOTPEngine.parseOTPAuthURI("https://example.com/secret"))
    }

    func testFromUserInputAcceptsBareSeedAndNormalizes() {
        let bare = TOTPSecret.fromUserInput(" jbsw y3dp ")
        XCTAssertEqual(bare?.secret, "JBSWY3DP")
        XCTAssertEqual(TOTPSecret.fromUserInput("  "), nil)
        XCTAssertEqual(TOTPSecret.fromUserInput("short!"), nil)
        let viaURI = TOTPSecret.fromUserInput("otpauth://totp/X?secret=JBSWY3DPEHPK3PXP")
        XCTAssertEqual(viaURI?.secret, "JBSWY3DPEHPK3PXP")
    }

    func testSecondsRemainingNeverZero() {
        XCTAssertEqual(TOTPEngine.secondsRemaining(period: 30, at: Date(timeIntervalSince1970: 59)), 1)
        XCTAssertEqual(TOTPEngine.secondsRemaining(period: 30, at: Date(timeIntervalSince1970: 60)), 30)
        XCTAssertEqual(TOTPEngine.secondsRemaining(period: 30, at: Date(timeIntervalSince1970: 0)), 30)
    }
}
