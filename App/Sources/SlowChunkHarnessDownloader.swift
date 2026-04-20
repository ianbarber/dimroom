import DriveClient
import Foundation

/// Harness-only downloader that paces a small synthetic payload across
/// many chunks so a Layer C flow can screenshot mid-stream and assert
/// the determinate `DownloadIndicatorView` is rendering. Installed by
/// `DimroomApp` only when `DIMROOM_HARNESS_STUB_DOWNLOADER=slow-chunks`
/// is set, so production never sees it.
///
/// Ignores `driveFileId`: the same payload is produced for every call.
/// The flow's job is to prove progress propagates end-to-end, not to
/// validate Drive's byte stream.
struct SlowChunkHarnessDownloader: OriginalsDownloader {
    /// Total payload size. Small on purpose — the flow doesn't render
    /// pixels, only the overlay.
    static let payloadByteCount = 2048
    /// How many `progress(fraction)` ticks the downloader emits. Picked
    /// so the gap between ticks is large enough that a state-poll loop
    /// at ~50 ms intervals reliably observes a mid-progress value.
    static let chunkCount = 10
    /// Sleep between chunks in nanoseconds. ~150 ms × 10 chunks gives
    /// ~1.5 s of wall-clock so a polling flow gets multiple windows to
    /// observe a `0 < progress < 1` value.
    static let chunkDelayNanoseconds: UInt64 = 150_000_000

    func download(
        driveFileId: String,
        to destinationURL: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destinationURL)
        defer { try? handle.close() }

        let chunkSize = Self.payloadByteCount / Self.chunkCount
        for chunkIndex in 0..<Self.chunkCount {
            let bytes = Data(repeating: UInt8(chunkIndex & 0xFF), count: chunkSize)
            try handle.write(contentsOf: bytes)
            let fraction = Double(chunkIndex + 1) / Double(Self.chunkCount)
            progress?(fraction)
            if chunkIndex < Self.chunkCount - 1 {
                try await Task.sleep(nanoseconds: Self.chunkDelayNanoseconds)
            }
        }
    }
}
