import Foundation
import DriveClient

public final class StubTokenProvider: AccessTokenProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String]
    private let refreshError: Error?
    private var _currentCalls: Int = 0
    private var _refreshCalls: Int = 0

    public init(accessTokens: [String], refreshError: Error? = nil) {
        self.tokens = accessTokens
        self.refreshError = refreshError
    }

    public var currentCalls: Int {
        lock.lock(); defer { lock.unlock() }
        return _currentCalls
    }

    public var refreshCalls: Int {
        lock.lock(); defer { lock.unlock() }
        return _refreshCalls
    }

    public func currentAccessToken() async throws -> String {
        lock.lock(); defer { lock.unlock() }
        _currentCalls += 1
        return tokens.first ?? ""
    }

    public func forceRefreshAccessToken() async throws -> String {
        lock.lock(); defer { lock.unlock() }
        _refreshCalls += 1
        if let refreshError {
            throw refreshError
        }
        if tokens.count > 1 {
            tokens.removeFirst()
        }
        return tokens.first ?? ""
    }
}
