import Catalog
import Foundation

/// Walks a folder, extracts metadata, copies originals into a staging
/// directory, and writes one `Asset` + one `ImportSession` row per call.
///
/// The importer is deliberately conservative about failures: if a single file
/// fails to hash or copy, the error propagates out and the caller decides
/// what to do. Dedup against the existing catalog is a pre-insert
/// `fetchAsset(byHash:)` check.
public final class FolderImporter {
    private let catalog: CatalogDatabase
    private let originalsDirectory: URL
    private let fileManager: FileManager

    public init(
        catalog: CatalogDatabase,
        originalsDirectory: URL,
        fileManager: FileManager = .default
    ) {
        self.catalog = catalog
        self.originalsDirectory = originalsDirectory
        self.fileManager = fileManager
    }

    /// Imports every supported image file under `folderURL`, recursively.
    ///
    /// Hidden files (anything whose name starts with `.`) and unsupported
    /// extensions are silently ignored and do not count toward either the
    /// `importedCount` or `skippedCount` in the result.
    public func importFolder(_ folderURL: URL) async throws -> ImportResult {
        let session = ImportSession(sourceKind: "folder", sourceDevice: nil)
        try catalog.insertImportSession(session)

        try fileManager.createDirectory(
            at: originalsDirectory,
            withIntermediateDirectories: true
        )

        let candidates = try enumerateCandidates(in: folderURL)

        var importedCount = 0
        var skippedCount = 0

        for fileURL in candidates {
            let hash = try StreamingHasher.sha256Hex(of: fileURL)

            if try catalog.fetchAsset(byHash: hash) != nil {
                skippedCount += 1
                continue
            }

            let ext = fileURL.pathExtension.lowercased()
            let metadata = ExifExtractor.extract(from: fileURL)
            let stagedURL = try copyToStaging(fileURL, hash: hash, ext: ext)
            let byteCount = try fileSize(of: fileURL)

            let asset = Asset(
                contentHash: hash,
                originalFilename: fileURL.lastPathComponent,
                captureDate: metadata.captureDate,
                sourceType: .digital,
                sourceDevice: metadata.sourceDevice,
                width: metadata.width,
                height: metadata.height,
                rawFormat: SupportedExtensions.isRaw(ext) ? ext : nil,
                rotation: metadata.rotationDegrees,
                localPath: stagedURL.path,
                bytes: byteCount
            )

            try catalog.insertAsset(asset)
            importedCount += 1
        }

        return ImportResult(
            importedCount: importedCount,
            skippedCount: skippedCount,
            sessionId: session.id
        )
    }

    // MARK: - Private helpers

    /// Returns a deterministic (path-sorted) list of supported files under
    /// `folderURL`, excluding hidden files.
    private func enumerateCandidates(in folderURL: URL) throws -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isHiddenKey]
        guard let enumerator = fileManager.enumerator(
            at: folderURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var results: [URL] = []
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else { continue }
            if fileURL.lastPathComponent.hasPrefix(".") { continue }
            guard SupportedExtensions.isSupported(fileURL.pathExtension) else { continue }
            results.append(fileURL)
        }
        results.sort { $0.path < $1.path }
        return results
    }

    /// Copies `source` to `<originalsDirectory>/<hash[0..2]>/<hash>.<ext>` and
    /// returns the destination URL. If the destination already exists (e.g. a
    /// prior partial import), it is reused — the byte content is keyed by the
    /// hash so an existing file is equivalent.
    private func copyToStaging(_ source: URL, hash: String, ext: String) throws -> URL {
        let prefix = String(hash.prefix(2))
        let bucket = originalsDirectory.appendingPathComponent(prefix, isDirectory: true)
        try fileManager.createDirectory(at: bucket, withIntermediateDirectories: true)

        let filename = ext.isEmpty ? hash : "\(hash).\(ext)"
        let destination = bucket.appendingPathComponent(filename)

        if !fileManager.fileExists(atPath: destination.path) {
            try fileManager.copyItem(at: source, to: destination)
        }
        return destination
    }

    private func fileSize(of url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }
}
