import Foundation

public enum OriginalsCacheError: Error, Equatable {
    /// Drive did not respond or the underlying HTTP call threw.
    case unreachable
    /// Drive responded with a non-2xx status during download.
    case downloadFailed(status: Int)
    /// Filesystem I/O (mkdir, rename, index write) failed.
    case ioFailure
}
