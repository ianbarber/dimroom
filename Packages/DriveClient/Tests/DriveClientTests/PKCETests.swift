import XCTest
@testable import DriveClient

final class PKCETests: XCTestCase {
    func testVerifierCharsetAndDefaultLength() {
        let verifier = PKCE.generateVerifier()
        XCTAssertEqual(verifier.count, 64)
        let allowed: Set<Character> = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        for char in verifier {
            XCTAssertTrue(allowed.contains(char), "unexpected character \(char)")
        }
    }

    func testVerifierLengthBounds() {
        XCTAssertEqual(PKCE.generateVerifier(length: 43).count, 43)
        XCTAssertEqual(PKCE.generateVerifier(length: 128).count, 128)
    }

    func testChallengeMatchesRFC7636TestVector() {
        // RFC 7636 appendix B
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let challenge = PKCE.challenge(for: verifier)
        XCTAssertEqual(challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testChallengeHasNoBase64Padding() {
        let verifier = PKCE.generateVerifier()
        let challenge = PKCE.challenge(for: verifier)
        XCTAssertFalse(challenge.contains("="))
        XCTAssertFalse(challenge.contains("+"))
        XCTAssertFalse(challenge.contains("/"))
    }
}
