import Foundation

/// Resolves `["PhotoTool", "library", "YYYY", "YYYY-MM-DD", "digital"]`
/// to a Drive folder ID, creating any missing segments along the way.
/// Segment IDs are memoised inside the actor so concurrent uploads on
/// the same day only pay the `files.list` / `files.create` cost once.
///
/// The actor also serialises work per-path, which matters for the
/// create-if-missing step: two tasks kicking off uploads for the same
/// folder from a cold cache won't each `POST files` and end up with
/// duplicate folders.
public actor DriveFolderResolver {

    public enum Root: Sendable {
        /// Walk the folder chain starting from the user's `My Drive` root.
        /// This is what production uses — Drive exposes it as the
        /// literal string `"root"` in the v3 API.
        case myDrive
        /// Start from a known folder ID (used by tests so we don't have
        /// to stub out the `"root"` value specifically).
        case folderId(String)

        fileprivate var id: String {
            switch self {
            case .myDrive: return "root"
            case .folderId(let id): return id
            }
        }
    }

    private let session: AuthorizedSession
    private let root: Root
    private let retryPolicy: RetryPolicy
    private let clock: any Clock<Duration>

    /// Maps `parentID + name` → resolved folder ID. Keyed by the pair so
    /// two different parents with the same child name don't collide.
    private var cache: [CacheKey: String] = [:]

    /// In-flight resolution tasks. If a second call arrives while the
    /// first is still walking the chain, it joins the same task instead
    /// of duplicating work.
    private var inflight: [CacheKey: Task<String, Error>] = [:]

    public init(
        session: AuthorizedSession,
        root: Root = .myDrive,
        retryPolicy: RetryPolicy = .default,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.session = session
        self.root = root
        self.retryPolicy = retryPolicy
        self.clock = clock
    }

    /// Returns the Drive folder ID for `segments`, creating any missing
    /// subfolders along the way. `segments` must be non-empty.
    public func resolve(segments: [String]) async throws -> String {
        precondition(!segments.isEmpty, "DriveFolderResolver.resolve called with empty segment list")
        var parentId = root.id
        for segment in segments {
            parentId = try await resolveChild(name: segment, parentId: parentId)
        }
        return parentId
    }

    private func resolveChild(name: String, parentId: String) async throws -> String {
        let key = CacheKey(parentId: parentId, name: name)
        if let cached = cache[key] {
            return cached
        }
        if let existing = inflight[key] {
            return try await existing.value
        }
        let task = Task<String, Error> { [session, retryPolicy, clock] in
            try await resolveChildUncached(
                name: name,
                parentId: parentId,
                session: session,
                retryPolicy: retryPolicy,
                clock: clock
            )
        }
        inflight[key] = task
        defer { inflight[key] = nil }
        let id = try await task.value
        cache[key] = id
        return id
    }

    /// Uncached variant. Kept as a free function so the actor doesn't
    /// hold its own isolation over the network call.
    private nonisolated func resolveChildUncached(
        name: String,
        parentId: String,
        session: AuthorizedSession,
        retryPolicy: RetryPolicy,
        clock: any Clock<Duration>
    ) async throws -> String {
        // 1. Look up existing folder.
        let listRequest = DriveFilesAPI.listFolderRequest(name: name, parentId: parentId)
        let listResult = try await sendWithRetry(
            request: listRequest,
            session: session,
            retryPolicy: retryPolicy,
            clock: clock
        )
        if let existing = firstFolderID(from: listResult.data) {
            return existing
        }

        // 2. Not present — create it.
        let createRequest = try DriveFilesAPI.createFolderRequest(name: name, parentId: parentId)
        let createResult = try await sendWithRetry(
            request: createRequest,
            session: session,
            retryPolicy: retryPolicy,
            clock: clock
        )
        guard (200..<300).contains(createResult.response.statusCode) else {
            throw DriveUploadError.folderCreationFailed(status: createResult.response.statusCode)
        }
        let decoded = try JSONDecoder().decode(DriveFilesAPI.DriveFile.self, from: createResult.data)
        return decoded.id
    }

    private nonisolated func firstFolderID(from data: Data) -> String? {
        guard let list = try? JSONDecoder().decode(DriveFilesAPI.DriveFileList.self, from: data) else {
            return nil
        }
        return list.files.first?.id
    }

    private struct CacheKey: Hashable {
        let parentId: String
        let name: String
    }
}

/// Wraps `AuthorizedSession.data(for:)` in the retry policy + Drive
/// status-code classification. Shared by the folder resolver and the
/// upload paths. The caller receives the final response (success or the
/// fatal one that stopped the loop); retry-budget exhaustion surfaces as
/// `DriveUploadError.retryBudgetExhausted`.
struct DriveHTTPResult {
    let data: Data
    let response: HTTPURLResponse
}

func sendWithRetry(
    request: URLRequest,
    session: AuthorizedSession,
    retryPolicy: RetryPolicy,
    clock: any Clock<Duration>
) async throws -> DriveHTTPResult {
    var attempt = 0
    while true {
        attempt += 1
        let isLast = attempt >= retryPolicy.maxAttempts
        do {
            let (data, response) = try await session.data(for: request)
            let decision = classifyDriveResponse(status: response.statusCode, body: data)
            switch decision {
            case .success, .fatal:
                return DriveHTTPResult(data: data, response: response)
            case .retry:
                if isLast {
                    throw DriveUploadError.retryBudgetExhausted
                }
            }
        } catch let urlError as URLError {
            if !isTransient(urlError: urlError) || isLast {
                throw urlError
            }
        }
        let delay = retryPolicy.delay(forAttempt: attempt)
        try? await clock.sleep(for: delay)
    }
}
