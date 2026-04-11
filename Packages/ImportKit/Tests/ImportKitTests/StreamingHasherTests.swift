import CryptoKit
import XCTest
@testable import ImportKit

final class StreamingHasherTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StreamingHasherTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testKnownHashOfSingleZeroByte() throws {
        // Pin against the published SHA-256 of a single 0x00 byte — well-known constant.
        let file = tmpDir.appendingPathComponent("single.bin")
        try Data([0x00]).write(to: file)

        let hex = try StreamingHasher.sha256Hex(of: file)
        XCTAssertEqual(
            hex,
            "6e340b9cffb37a989ca544e6bb780a2c78901d3fb33738768511a30617afa01d"
        )
    }

    func testMatchesOneShotCryptoKitHash() throws {
        // Sanity: hashing byte-by-byte via the streaming path must match a
        // single-shot `SHA256.hash(data:)` over the whole file.
        let file = tmpDir.appendingPathComponent("oneshot.bin")
        let data = Data((0..<4096).map { UInt8($0 % 251) })
        try data.write(to: file)

        let streamed = try StreamingHasher.sha256Hex(of: file)
        let oneShot = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(streamed, oneShot)
    }

    func testChunkBoundaryCorrectness() throws {
        // Produce a file a few times larger than the default chunk size so
        // the streaming loop has to cross chunk boundaries, and verify the
        // digest still matches a one-shot hash of the full buffer.
        let chunk = 1024
        let totalBytes = chunk * 7 + 17  // deliberately not a multiple
        var bytes = [UInt8]()
        bytes.reserveCapacity(totalBytes)
        for i in 0..<totalBytes {
            bytes.append(UInt8((i * 131 + 7) % 256))
        }
        let data = Data(bytes)
        let file = tmpDir.appendingPathComponent("boundary.bin")
        try data.write(to: file)

        let streamed = try StreamingHasher.sha256Hex(of: file, chunkSize: chunk)
        let expected = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(streamed, expected)
    }

    func testEmptyFileHash() throws {
        // SHA-256 of an empty string — well-known constant.
        let file = tmpDir.appendingPathComponent("empty.bin")
        try Data().write(to: file)

        let hex = try StreamingHasher.sha256Hex(of: file)
        XCTAssertEqual(
            hex,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    func testMissingFileThrows() {
        let missing = tmpDir.appendingPathComponent("does-not-exist.bin")
        XCTAssertThrowsError(try StreamingHasher.sha256Hex(of: missing))
    }
}
