import Foundation

public enum DriveUploadError: Error, Equatable {
    case missingLocalFile(UUID)
    case folderCreationFailed(status: Int)
    case listFailed(status: Int)
    case uploadFailed(status: Int, body: String)
    case resumableSessionLost
    case retryBudgetExhausted
    case invalidServerResponse(String)
}
