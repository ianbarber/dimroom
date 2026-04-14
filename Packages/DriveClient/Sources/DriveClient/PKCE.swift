import CryptoKit
import Foundation

public enum PKCE {
    public static let verifierMinLength = 43
    public static let verifierMaxLength = 128

    private static let unreservedCharacters: [Character] = {
        let letters = (UInt8(ascii: "A")...UInt8(ascii: "Z")).map { Character(UnicodeScalar($0)) }
        let lower = (UInt8(ascii: "a")...UInt8(ascii: "z")).map { Character(UnicodeScalar($0)) }
        let digits = (UInt8(ascii: "0")...UInt8(ascii: "9")).map { Character(UnicodeScalar($0)) }
        return letters + lower + digits + ["-", ".", "_", "~"]
    }()

    public static func generateVerifier(length: Int = 64) -> String {
        precondition(length >= verifierMinLength && length <= verifierMaxLength,
                     "PKCE verifier length must be between \(verifierMinLength) and \(verifierMaxLength)")
        var result = ""
        result.reserveCapacity(length)
        let alphabet = unreservedCharacters
        let count = UInt32(alphabet.count)
        for _ in 0..<length {
            let index = Int(UInt32.random(in: 0..<count))
            result.append(alphabet[index])
        }
        return result
    }

    public static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncode(Data(digest))
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
