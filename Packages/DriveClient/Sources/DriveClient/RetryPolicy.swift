import Foundation

/// Exponential-backoff retry policy used by the uploader. Retries happen
/// only on transient failures: `URLError` network hiccups, HTTP 5xx, and
/// 429. Drive uses 403 for quota (`userRateLimitExceeded` /
/// `rateLimitExceeded`) — callers inspect the response body to pick out
/// those cases and treat them as transient (see `isTransient(response:)`).
public struct RetryPolicy: Sendable, Equatable {
    public let maxAttempts: Int
    public let baseDelay: Duration
    public let maxDelay: Duration

    public init(maxAttempts: Int, baseDelay: Duration, maxDelay: Duration) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    public static let `default` = RetryPolicy(
        maxAttempts: 3,
        baseDelay: .milliseconds(500),
        maxDelay: .seconds(30)
    )

    /// Deterministic delay (no jitter) for attempt `n` (1-indexed). Tests
    /// use this directly; live code layers jitter on top.
    public func delay(forAttempt n: Int) -> Duration {
        guard n >= 1 else { return .zero }
        // Duration lacks built-in multiplication, but we can multiply the
        // raw milliseconds value and reconstruct. Scale = 2^(n-1).
        let scale = UInt64(1) << UInt64(min(n - 1, 20))
        let scaled = baseDelay * scale
        return min(scaled, maxDelay)
    }
}

/// Classifies an `HTTPURLResponse` status / body as transient-retryable
/// or fatal. Exposed so the simple / resumable upload paths can share the
/// decision.
public enum DriveRetryDecision: Sendable, Equatable {
    case retry
    case fatal
    case success
}

/// Classifies a Drive HTTP response into the tri-state above.
/// - 2xx → success
/// - 5xx → retry
/// - 429 → retry
/// - 403 with `userRateLimitExceeded` or `rateLimitExceeded` in the body →
///   retry (Drive's quota signal)
/// - everything else → fatal (caller should surface it)
public func classifyDriveResponse(status: Int, body: Data) -> DriveRetryDecision {
    if (200..<300).contains(status) {
        return .success
    }
    if status >= 500 && status < 600 {
        return .retry
    }
    if status == 429 {
        return .retry
    }
    if status == 403 && bodyIndicatesQuota(body) {
        return .retry
    }
    return .fatal
}

private func bodyIndicatesQuota(_ body: Data) -> Bool {
    guard !body.isEmpty,
          let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
          let error = object["error"] as? [String: Any],
          let errors = error["errors"] as? [[String: Any]] else {
        return false
    }
    for item in errors {
        if let reason = item["reason"] as? String,
           reason == "userRateLimitExceeded" || reason == "rateLimitExceeded" {
            return true
        }
    }
    return false
}

/// Classifies a `URLError` as transient. Connection-level failures we've
/// seen under flaky networks.
public func isTransient(urlError: URLError) -> Bool {
    switch urlError.code {
    case .timedOut,
         .networkConnectionLost,
         .notConnectedToInternet,
         .cannotFindHost,
         .dnsLookupFailed,
         .resourceUnavailable,
         .cannotConnectToHost:
        return true
    default:
        return false
    }
}

/// Retries `operation` according to `policy`. `operation` either returns
/// a value (success) or throws. A throwing result is classified via
/// `shouldRetry`; when it returns `true` we sleep according to the
/// policy's schedule and try again, up to `maxAttempts`. When the budget
/// is exhausted the final error surfaces to the caller.
public func withRetry<T: Sendable>(
    policy: RetryPolicy,
    clock: any Clock<Duration> = ContinuousClock(),
    shouldRetry: @escaping @Sendable (Error) -> Bool,
    operation: @Sendable () async throws -> T
) async throws -> T {
    var attempt = 0
    while true {
        attempt += 1
        do {
            return try await operation()
        } catch {
            let isLast = attempt >= policy.maxAttempts
            if isLast || !shouldRetry(error) {
                throw error
            }
            let delay = policy.delay(forAttempt: attempt)
            try? await clock.sleep(for: delay)
        }
    }
}
