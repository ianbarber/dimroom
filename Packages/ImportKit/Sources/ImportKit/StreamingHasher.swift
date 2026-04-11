import CryptoKit
import Foundation

/// Streaming SHA-256 for files that may be much larger than available memory.
///
/// Files are read in fixed-size chunks (64 KiB by default) and fed into
/// `CryptoKit.SHA256` incrementally. The file handle is always closed, even
/// on throw.
public enum StreamingHasher {
    /// Hashes the file at `url` and returns the lowercase hex-encoded SHA-256
    /// digest.
    ///
    /// - Parameters:
    ///   - url: Location of the file to hash.
    ///   - chunkSize: Number of bytes to read per iteration. Must be > 0.
    /// - Throws: Any error thrown by `FileHandle` while opening or reading.
    public static func sha256Hex(
        of url: URL,
        chunkSize: Int = 64 * 1024
    ) throws -> String {
        precondition(chunkSize > 0, "chunkSize must be positive")

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
