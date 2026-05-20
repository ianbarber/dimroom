import Foundation
@testable import SyncEngine

/// In-memory `DriveChangesFetching` stand-in. Records every call so
/// tests can assert on the sequence; programmable for both happy-path
/// and error behaviours.
final class StubDriveChangesFetcher: DriveChangesFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var _bootstrapToken: String
    private var _bootstrapError: SyncEngineError?
    private var _bootstrapCalls = 0
    private var _listCalls: [String] = []
    /// Sequence of pages returned by successive `listChanges` calls.
    /// Once the sequence is exhausted, the last entry is replayed.
    private var _listResponses: [Result<DriveChangesPage, SyncEngineError>] = []

    init(bootstrapToken: String = "initial-token") {
        self._bootstrapToken = bootstrapToken
    }

    // MARK: - Configuration

    func setBootstrapToken(_ token: String) {
        lock.withLock { _bootstrapToken = token }
    }

    func setBootstrapError(_ error: SyncEngineError?) {
        lock.withLock { _bootstrapError = error }
    }

    func enqueueListResponse(_ page: DriveChangesPage) {
        lock.withLock { _listResponses.append(.success(page)) }
    }

    func enqueueListError(_ error: SyncEngineError) {
        lock.withLock { _listResponses.append(.failure(error)) }
    }

    // MARK: - DriveChangesFetching

    func startPageToken() async throws -> String {
        let (token, error): (String, SyncEngineError?) = lock.withLock {
            _bootstrapCalls += 1
            return (_bootstrapToken, _bootstrapError)
        }
        if let error { throw error }
        return token
    }

    func listChanges(pageToken: String) async throws -> DriveChangesPage {
        let response: Result<DriveChangesPage, SyncEngineError> = lock.withLock {
            _listCalls.append(pageToken)
            guard !_listResponses.isEmpty else {
                return .success(DriveChangesPage(
                    changes: [],
                    newStartPageToken: "auto-empty-token"
                ))
            }
            if _listResponses.count == 1 {
                return _listResponses[0]
            }
            return _listResponses.removeFirst()
        }
        switch response {
        case .success(let page): return page
        case .failure(let error): throw error
        }
    }

    // MARK: - Assertions

    var bootstrapCalls: Int { lock.withLock { _bootstrapCalls } }
    var listCalls: [String] { lock.withLock { _listCalls } }
}
