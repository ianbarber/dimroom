import Foundation
@testable import SyncEngine

/// In-memory stand-in for `CatalogUploading` used by `CatalogPublisher`
/// tests. Records every call so tests can assert on the upload
/// sequence; programmable for success, sequence, or error behaviours.
final class StubCatalogUploader: CatalogUploading, @unchecked Sendable {
    struct UploadCall: Sendable, Equatable {
        let snapshotPath: String
        let existingFileId: String?
    }

    enum Behavior: Sendable {
        case alwaysSucceed(CatalogUploadResult)
        case alwaysFail(SyncEngineError)
        case sequence([Result<CatalogUploadResult, SyncEngineError>])
    }

    private let lock = NSLock()
    private var _behavior: Behavior
    private var _uploadCalls: [UploadCall] = []
    private var _findCalls: Int = 0
    private var _downloadCalls: [(fileId: String, localPath: String)] = []

    /// Optional remote catalog returned from `findExistingCatalog`.
    private var _remoteCatalog: DriveCatalogRef?
    /// Optional error to throw from `findExistingCatalog`. When set,
    /// the stub throws this instead of returning `_remoteCatalog`.
    private var _findError: SyncEngineError?
    private var _downloadResult: Result<Int64, SyncEngineError> = .success(0)
    private var _downloadBytesToWrite: Data?

    init(behavior: Behavior) {
        self._behavior = behavior
    }

    // MARK: - CatalogUploading

    func upload(snapshotPath: String, existingFileId: String?) async throws -> CatalogUploadResult {
        lock.lock()
        _uploadCalls.append(UploadCall(snapshotPath: snapshotPath, existingFileId: existingFileId))
        let index = _uploadCalls.count - 1
        let current = _behavior
        lock.unlock()

        switch current {
        case .alwaysSucceed(let result):
            return result
        case .alwaysFail(let error):
            throw error
        case .sequence(let entries):
            let entry: Result<CatalogUploadResult, SyncEngineError>
            if index < entries.count {
                entry = entries[index]
            } else if let last = entries.last {
                entry = last
            } else {
                throw SyncEngineError.uploadFailed(underlying: "no sequence entries")
            }
            switch entry {
            case .success(let r): return r
            case .failure(let e): throw e
            }
        }
    }

    func findExistingCatalog() async throws -> DriveCatalogRef? {
        lock.lock()
        _findCalls += 1
        let err = _findError
        let value = _remoteCatalog
        lock.unlock()
        if let err { throw err }
        return value
    }

    func download(fileId: String, to localPath: String) async throws -> Int64 {
        lock.lock()
        _downloadCalls.append((fileId, localPath))
        let dataToWrite = _downloadBytesToWrite
        let result = _downloadResult
        lock.unlock()

        if let dataToWrite {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: localPath).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try dataToWrite.write(to: URL(fileURLWithPath: localPath))
        }

        switch result {
        case .success(let bytes): return bytes
        case .failure(let error): throw error
        }
    }

    // MARK: - Configuration

    func setRemoteCatalog(_ ref: DriveCatalogRef?) {
        lock.lock(); _remoteCatalog = ref; lock.unlock()
    }

    func setFindError(_ error: SyncEngineError?) {
        lock.lock(); _findError = error; lock.unlock()
    }

    func setDownloadBytes(_ data: Data) {
        lock.lock(); _downloadBytesToWrite = data; lock.unlock()
    }

    func setDownloadResult(_ result: Result<Int64, SyncEngineError>) {
        lock.lock(); _downloadResult = result; lock.unlock()
    }

    // MARK: - Assertion helpers

    var uploadCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _uploadCalls.count
    }

    var uploadCalls: [UploadCall] {
        lock.lock(); defer { lock.unlock() }
        return _uploadCalls
    }

    var lastUpload: UploadCall? {
        lock.lock(); defer { lock.unlock() }
        return _uploadCalls.last
    }

    var findCalls: Int {
        lock.lock(); defer { lock.unlock() }
        return _findCalls
    }

    var downloadCalls: [(fileId: String, localPath: String)] {
        lock.lock(); defer { lock.unlock() }
        return _downloadCalls
    }
}
