import Catalog
import CoreImage
import EditEngine
import Foundation

/// Orchestrates a batch export flow: iterates assets, resolves source
/// URLs, queries edit states, calls `Exporter` for each, and publishes
/// progress state that the UI layer observes to drive a progress overlay.
///
/// Follows the same pattern as `ImportCoordinator`: pure coordination
/// logic with no SwiftUI dependency, testable headless.
@MainActor
public final class ExportCoordinator: ObservableObject {

    // MARK: - Published state

    public enum Phase: Equatable, Sendable {
        case idle
        case exporting
        /// Terminal success phase. `exported` is the number of files
        /// written, `skipped` counts assets we couldn't export (missing
        /// local original, per-file write failure), and `failures` carries
        /// a short human-readable reason per skipped asset so the UI can
        /// surface them in the completion alert.
        case done(exported: Int, skipped: Int, failures: [String])
        /// Terminal failure phase for errors that prevent the batch from
        /// running at all (e.g. unwritable destination directory).
        case failed(String)

        public static func == (lhs: Phase, rhs: Phase) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.exporting, .exporting):
                return true
            case (.done(let le, let ls, let lf), .done(let re, let rs, let rf)):
                return le == re && ls == rs && lf == rf
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
    /// Streaming download progress (0.0...1.0) for the asset currently
    /// being fetched from Drive, or `nil` when the active asset's
    /// bytes were already local. Reset to `nil` once the asset is
    /// written so the next iteration starts clean.
    @Published public private(set) var currentItemProgress: Double?

    public init() {}

    /// Whether the coordinator is actively running an export.
    public var isActive: Bool {
        if case .exporting = phase { return true }
        return false
    }

    // MARK: - Run

    /// Exports all provided assets to the destination directory.
    ///
    /// - Parameters:
    ///   - assets: The assets to export.
    ///   - catalog: Used to look up edit states.
    ///   - format: Export format (original, jpeg, tiff).
    ///   - jpegQuality: JPEG quality 0-100. Ignored for non-JPEG.
    ///   - applyEdits: Whether to bake edits into the output.
    ///   - destinationDirectory: Directory to write exported files into.
    ///   - originalFetcher: Optional coordinator used to pull originals
    ///     from Drive on demand when the asset isn't present locally.
    ///     When `nil`, missing-local assets are skipped as before.
    public func run(
        assets: [Asset],
        catalog: CatalogDatabase,
        format: ExportFormat,
        jpegQuality: Int,
        applyEdits: Bool,
        destinationDirectory: URL,
        originalFetcher: (any OriginalFetcher)? = nil
    ) async {
        phase = .exporting
        currentItem = 0
        totalItems = assets.count

        // Guard the whole batch against an unwritable destination before
        // we start touching Core Image. `isWritableFile(atPath:)` returns
        // false for both "doesn't exist" and "exists but unwritable", so
        // we also check `fileExists` + `isDirectory` to give a precise
        // error message rather than a generic per-file failure.
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: destinationDirectory.path,
            isDirectory: &isDir
        )
        if !exists {
            phase = .failed("Destination directory does not exist: \(destinationDirectory.path)")
            return
        }
        if !isDir.boolValue {
            phase = .failed("Destination is not a directory: \(destinationDirectory.path)")
            return
        }
        if !FileManager.default.isWritableFile(atPath: destinationDirectory.path) {
            phase = .failed("Destination directory is not writable: \(destinationDirectory.path)")
            return
        }

        let context = CIContext(options: [.useSoftwareRenderer: false])
        var existingNames = Self.existingFilenames(in: destinationDirectory)
        var exportedCount = 0
        var skippedCount = 0
        var failureReasons: [String] = []

        for asset in assets {
            var resolvedLocalPath = asset.localPath
            if resolvedLocalPath == nil, let fetcher = originalFetcher {
                let assetId = asset.id
                let progress: @Sendable (Double) -> Void = { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        // The export pipeline ticks one asset at a time,
                        // so we only need to clamp monotonically within
                        // the current asset's window. Resets to nil
                        // happen below after the asset is written.
                        let clamped = min(max(fraction, 0), 1)
                        let existing = self.currentItemProgress ?? 0
                        if clamped >= existing {
                            self.currentItemProgress = clamped
                        }
                    }
                }
                if let url = await fetcher.fetchOriginal(assetId: assetId, progress: progress) {
                    resolvedLocalPath = url.path
                }
            }
            guard let localPath = resolvedLocalPath else {
                skippedCount += 1
                failureReasons.append("\(asset.originalFilename): no local copy available")
                currentItemProgress = nil
                currentItem += 1
                await Task.yield()
                continue
            }

            let sourceURL = URL(fileURLWithPath: localPath)
            let editState: EditState?
            if applyEdits {
                editState = try? catalog.latestEditState(for: asset.id)
            } else {
                editState = nil
            }

            let ext = Self.fileExtension(for: format, original: asset.originalFilename)
            let stem = (asset.originalFilename as NSString).deletingPathExtension
            let baseName = "\(stem).\(ext)"
            let safeName = Exporter.collisionFreeName(baseName: baseName, existingNames: existingNames)
            existingNames.insert(safeName)

            let destinationURL = destinationDirectory.appendingPathComponent(safeName)
            let config = ExportConfiguration(
                format: format,
                jpegQuality: jpegQuality,
                applyEdits: applyEdits,
                destinationURL: destinationURL
            )

            do {
                try Exporter.export(
                    sourceURL: sourceURL,
                    editState: editState,
                    config: config,
                    context: context
                )
                exportedCount += 1
            } catch {
                skippedCount += 1
                let reason = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                failureReasons.append("\(asset.originalFilename): \(reason)")
            }

            currentItemProgress = nil
            currentItem += 1
            await Task.yield()
        }

        phase = .done(
            exported: exportedCount,
            skipped: skippedCount,
            failures: failureReasons
        )
    }

    /// Resets the coordinator back to idle so it can be reused.
    public func reset() {
        phase = .idle
        currentItem = 0
        totalItems = 0
        currentItemProgress = nil
    }

    // MARK: - Test helpers

    /// Sets the phase directly. Used by snapshot tests.
    func setPhaseForTesting(_ newPhase: Phase) {
        phase = newPhase
    }

    /// Sets progress counters directly for snapshot tests.
    func setProgressForTesting(current: Int, total: Int) {
        currentItem = current
        totalItems = total
    }

    /// Sets the per-asset download fraction for snapshot tests so the
    /// "downloading original…" bar can be captured deterministically.
    func setCurrentItemProgressForTesting(_ value: Double?) {
        currentItemProgress = value
    }

    // MARK: - Private

    /// Determine the file extension for the export format, falling back to
    /// the original file's extension for `.original` format.
    private static func fileExtension(for format: ExportFormat, original filename: String) -> String {
        switch format {
        case .original:
            let ext = (filename as NSString).pathExtension
            return ext.isEmpty ? "bin" : ext
        case .jpeg:
            return "jpg"
        case .tiff:
            return "tiff"
        }
    }

    /// Scan the destination directory and return the set of existing filenames.
    private static func existingFilenames(in directory: URL) -> Set<String> {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(contents)
    }
}
