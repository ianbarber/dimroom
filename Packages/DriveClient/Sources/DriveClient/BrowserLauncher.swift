import Foundation
#if canImport(AppKit)
import AppKit
#endif

public protocol BrowserLauncher: Sendable {
    func open(_ url: URL) throws
}

public struct NSWorkspaceBrowserLauncher: BrowserLauncher {
    public init() {}

    public func open(_ url: URL) throws {
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #else
        throw DriveClientError.redirectServerFailed("no NSWorkspace available")
        #endif
    }
}
