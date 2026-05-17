import Foundation

/// Result of a single poll of `drive.changes.list`. The AppDelegate
/// switches on this to either log silently, prompt for a catalog
/// reload, or raise a conflict alert.
public enum DeltaSyncOutcome: Sendable, Equatable {
    /// First sync — no token was stored, so we called
    /// `changes.getStartPageToken` and persisted the baseline.
    case bootstrapped(pageToken: String)
    /// Poll succeeded but there were no relevant changes.
    case noChanges(pageToken: String)
    /// Remote catalog file moved since our last publish, and no local
    /// edits are queued. Safe to prompt the user to reload.
    case catalogChanged(
        driveFileId: String,
        modifiedTime: String?,
        pageToken: String
    )
    /// Both local and remote have changes since the last sync. The
    /// poller surfaces it; the AppDelegate decides how to alert.
    case conflict(
        localPending: Bool,
        remoteFileId: String,
        modifiedTime: String?,
        pageToken: String
    )
    /// Originals (or other non-catalog files) changed on Drive; the
    /// catalog file itself did not. The Library can reload to surface
    /// any new assets once the next catalog publish lands.
    case originalsChangedOnly(addedCount: Int, pageToken: String)
}
