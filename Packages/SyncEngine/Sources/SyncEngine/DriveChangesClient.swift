import DriveClient
import Foundation

/// Production `DriveChangesFetching` backed by an `AuthorizedSession`.
/// Reuses the same Drive-aware retry classification as
/// `DriveCatalogUploader.sendWithCatalogRetry` so transient 5xx / 429 /
/// quota failures are retried instead of bubbling up.
public actor DriveChangesClient: DriveChangesFetching {
    private let session: AuthorizedSession
    private let retryPolicy: RetryPolicy
    private let clock: any Clock<Duration>

    public init(
        session: AuthorizedSession,
        retryPolicy: RetryPolicy = .default,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.session = session
        self.retryPolicy = retryPolicy
        self.clock = clock
    }

    public func startPageToken() async throws -> String {
        let (data, response) = try await sendWithRetry(
            request: DriveChangesAPI.startPageTokenRequest()
        )
        guard (200..<300).contains(response.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SyncEngineError.changesFetchFailed(
                underlying: "startPageToken failed status=\(response.statusCode) body=\(body)"
            )
        }
        do {
            let decoded = try JSONDecoder().decode(
                DriveChangesAPI.StartPageTokenResponse.self,
                from: data
            )
            return decoded.startPageToken
        } catch {
            throw SyncEngineError.changesFetchFailed(
                underlying: "startPageToken decode failed: \(error)"
            )
        }
    }

    public func listChanges(pageToken: String) async throws -> DriveChangesPage {
        let (data, response) = try await sendWithRetry(
            request: DriveChangesAPI.changesListRequest(pageToken: pageToken)
        )
        guard (200..<300).contains(response.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SyncEngineError.changesFetchFailed(
                underlying: "changes.list failed status=\(response.statusCode) body=\(body)"
            )
        }
        let decoded: DriveChangesAPI.ChangeList
        do {
            decoded = try JSONDecoder().decode(
                DriveChangesAPI.ChangeList.self,
                from: data
            )
        } catch {
            throw SyncEngineError.changesFetchFailed(
                underlying: "changes.list decode failed: \(error)"
            )
        }
        let mapped = decoded.changes.compactMap(Self.mapChange)
        return DriveChangesPage(
            changes: mapped,
            nextPageToken: decoded.nextPageToken,
            newStartPageToken: decoded.newStartPageToken
        )
    }

    private static func mapChange(_ change: DriveChangesAPI.Change) -> DriveChange? {
        let id = change.fileId ?? change.file?.id
        guard let id else { return nil }
        return DriveChange(
            fileId: id,
            removed: change.removed ?? false,
            trashed: change.file?.trashed ?? false,
            name: change.file?.name,
            mimeType: change.file?.mimeType,
            modifiedTime: change.file?.modifiedTime,
            parents: change.file?.parents ?? [],
            appProperties: change.file?.appProperties ?? [:]
        )
    }

    private func sendWithRetry(request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            attempt += 1
            let isLast = attempt >= retryPolicy.maxAttempts
            do {
                let (data, response) = try await session.data(for: request)
                let decision = classifyDriveResponse(status: response.statusCode, body: data)
                switch decision {
                case .success, .fatal:
                    return (data, response)
                case .retry:
                    if isLast {
                        throw SyncEngineError.changesFetchFailed(
                            underlying: "retry budget exhausted at status=\(response.statusCode)"
                        )
                    }
                }
            } catch let urlError as URLError {
                if !isTransient(urlError: urlError) || isLast {
                    throw SyncEngineError.changesFetchFailed(
                        underlying: "network error: \(urlError.localizedDescription)"
                    )
                }
            } catch {
                throw error
            }
            let delay = retryPolicy.delay(forAttempt: attempt)
            try? await clock.sleep(for: delay)
        }
    }
}
