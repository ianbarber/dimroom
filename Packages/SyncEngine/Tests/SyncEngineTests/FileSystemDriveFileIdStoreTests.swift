import XCTest
@testable import SyncEngine

final class FileSystemDriveFileIdStoreTests: XCTestCase {

    private func tempPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dimroom-fileidstore-\(UUID().uuidString)")
            .appendingPathComponent("drive-catalog-id.txt")
            .path
    }

    private func cleanup(_ path: String) {
        let parent = (path as NSString).deletingLastPathComponent
        try? FileManager.default.removeItem(atPath: parent)
    }

    func testRoundTrip() throws {
        let path = tempPath()
        defer { cleanup(path) }
        let store = FileSystemDriveFileIdStore(path: path)

        try store.save("drive-id-123")
        XCTAssertEqual(try store.load(), "drive-id-123")
    }

    func testMissingFileLoadsAsNil() throws {
        let path = tempPath()
        defer { cleanup(path) }
        let store = FileSystemDriveFileIdStore(path: path)

        XCTAssertNil(try store.load())
    }

    func testClearRemovesFile() throws {
        let path = tempPath()
        defer { cleanup(path) }
        let store = FileSystemDriveFileIdStore(path: path)

        try store.save("drive-id-clear-me")
        XCTAssertEqual(try store.load(), "drive-id-clear-me")
        try store.clear()
        XCTAssertNil(try store.load())
        // Idempotent — clearing again with no file must succeed.
        try store.clear()
    }

    func testSaveCreatesParentDirectory() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("dimroom-fileidstore-\(UUID().uuidString)")
            .appendingPathComponent("nested")
            .appendingPathComponent("deeper")
        let path = parent.appendingPathComponent("drive-catalog-id.txt").path
        defer {
            try? FileManager.default.removeItem(
                at: parent.deletingLastPathComponent().deletingLastPathComponent()
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.path))

        let store = FileSystemDriveFileIdStore(path: path)
        try store.save("drive-id-nested")
        XCTAssertEqual(try store.load(), "drive-id-nested")
    }

    func testWhitespaceIsTrimmedOnLoad() throws {
        let path = tempPath()
        defer { cleanup(path) }
        // Simulate a sidecar where the previous writer added a newline.
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try Data("  drive-id-padded\n".utf8).write(to: URL(fileURLWithPath: path))

        let store = FileSystemDriveFileIdStore(path: path)
        XCTAssertEqual(try store.load(), "drive-id-padded")
    }

    func testEmptyFileLoadsAsNil() throws {
        let path = tempPath()
        defer { cleanup(path) }
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try Data().write(to: URL(fileURLWithPath: path))

        let store = FileSystemDriveFileIdStore(path: path)
        XCTAssertNil(try store.load())
    }
}
