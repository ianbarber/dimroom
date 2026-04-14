import Foundation

public enum DriveClientError: Error, Equatable {
    case clientIDNotConfigured
    case authorizationDenied(String)
    case tokenExchangeFailed(status: Int, body: String)
    case refreshFailed
    case notAuthenticated
    case redirectServerFailed(String)
    case invalidRedirect(String)
    case authorizationTimedOut
    case stateMismatch
    case keychainFailure(OSStatus)
    case downloadFailed(status: Int)
}
