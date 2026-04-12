import Catalog
import Foundation
import ImportKit
import Previews

/// Orchestrates a two-phase import flow: folder import followed by
/// preview generation. Publishes progress state that the UI layer
/// observes to drive a progress overlay.
///
/// Pure coordination logic — no SwiftUI dependency. Testable via
/// `swift test` with in-memory catalog and temp directories.
@MainActor
public final class ImportCoordinator: ObservableObject {

    // MARK: - Published state

    public enum Phase: Equatable, Sendable {
        case idle
        case importing
        case generatingPreviews
        case done
        case failed(String)

        public static func == (lhs: Phase, rhs: Phase) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.importing, .importing),
                 (.generatingPreviews, .generatingPreviews), (.done, .done):
                return true
            case (.failed(let a), .failed(let b)):
                return a == b
            default:
                return false
            }
        }
    }

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var currentItem: Int = 0
    @Published public private(set) var totalItems: Int = 0

    public init() {}

    /// Whether the coordinator is actively running an import.
    public var isActive: Bool {
        switch phase {
        case .importing, .generatingPreviews:
            return true
        case .idle, .done, .failed:
            return false
        }
    }

    // MARK: - Run

    /// Runs the full import-then-preview-generation flow.
    ///
    /// 1. Sets phase to `.importing`, calls `importer.importFolder`.
    /// 2. Sets phase to `.generatingPreviews`, iterates newly imported
    ///    assets and calls `previewStore.generate(for:sourceURL:)` for
    ///    each, updating `currentItem` as it goes.
    /// 3. Sets phase to `.done`, or `.failed` if an error is thrown.
    public func run(
        folderURL: URL,
        importer: FolderImporter,
        previewStore: PreviewStore
    ) async {
        phase = .importing
        currentItem = 0
        totalItems = 0

        let result: ImportResult
        do {
            result = try await importer.importFolder(folderURL)
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }

        let assets = result.importedAssets
        phase = .generatingPreviews
        currentItem = 0
        totalItems = assets.count

        for asset in assets {
            guard let localPath = asset.localPath else { continue }
            let sourceURL = URL(fileURLWithPath: localPath)
            do {
                try await previewStore.generate(for: asset, sourceURL: sourceURL)
            } catch {
                // Preview generation failure for a single asset is
                // non-fatal — the grid will show a placeholder.
            }
            currentItem += 1
        }

        phase = .done
    }

    /// Resets the coordinator back to idle so it can be reused.
    public func reset() {
        phase = .idle
        currentItem = 0
        totalItems = 0
    }
}
