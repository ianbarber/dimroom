import Foundation

/// Persistent slot for the Drive file id of the published catalog.
/// Caching the id avoids a `files.list` query before every publish and
/// lets restore look up the file directly. Stored outside the catalog
/// itself so it remains readable before the catalog is opened.
public protocol DriveFileIdStore: Sendable {
    func load() throws -> String?
    func save(_ fileId: String) throws
    func clear() throws
}

/// File-system-backed file id store. Default location is
/// `~/Library/Application Support/Dimroom/drive-catalog-id.txt`; the
/// directory is created on demand and a missing file reads as `nil`.
public struct FileSystemDriveFileIdStore: DriveFileIdStore {
    private let path: String

    public init(path: String) {
        self.path = path
    }

    /// Default path under the user's Application Support folder. Falls
    /// back to the temporary directory if Application Support is
    /// unavailable (extremely unlikely on macOS but keeps the init
    /// non-throwing).
    public static func defaultPath() -> String {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return appSupport
            .appendingPathComponent("Dimroom", isDirectory: true)
            .appendingPathComponent("drive-catalog-id.txt")
            .path
    }

    public func load() throws -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let trimmed = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func save(_ fileId: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(fileId.utf8).write(to: url, options: .atomic)
    }

    public func clear() throws {
        if FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }
    }
}

/// In-memory file id store used by SyncEngine tests so we don't have
/// to worry about cleaning up files in `~/Library/Application Support`.
public final class InMemoryDriveFileIdStore: DriveFileIdStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    public init(initial: String? = nil) {
        self.value = initial
    }

    public func load() throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    public func save(_ fileId: String) throws {
        lock.lock()
        value = fileId
        lock.unlock()
    }

    public func clear() throws {
        lock.lock()
        value = nil
        lock.unlock()
    }
}
