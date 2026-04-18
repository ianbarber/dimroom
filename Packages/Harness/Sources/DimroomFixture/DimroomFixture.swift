import ArgumentParser
import Catalog
import CryptoKit
import Foundation
import ImageIO
import Previews
import UniformTypeIdentifiers

/// Seeds a catalog and its preview cache from a folder of JPEG fixtures,
/// for harness flows that need to show a populated library.
///
/// Unlike the real `FolderImporter` in `ImportKit`, this tool is
/// deliberately dumb: it hashes each file, writes an `Asset` row, and
/// asks `PreviewStore` to generate previews. That's enough for the
/// library grid to light up, and it keeps Layer C flow scripts
/// independent of importer changes.
@main
struct DimroomFixture: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dimroom-fixture",
        abstract: "Seed a Dimroom catalog and preview cache from a folder of JPEGs.",
        subcommands: [Seed.self]
    )
}

extension DimroomFixture {
    struct Seed: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "seed",
            abstract: "Populate a catalog + preview cache from a seed folder."
        )

        @Option(name: .long, help: "Output path for the SQLite catalog file.")
        var catalog: String

        @Option(name: .long, help: "Output directory for the preview cache.")
        var cache: String

        @Option(
            name: .customLong("seed-dir"),
            help: "Directory of JPEGs to seed the catalog from."
        )
        var seedDir: String

        @Option(
            name: .long,
            help: "Repeat each seed JPEG N times with distinct hashes and staggered dates."
        )
        var duplicate: Int = 1

        func run() async throws {
            let fm = FileManager.default
            let catalogURL = URL(fileURLWithPath: catalog)
            let cacheURL = URL(fileURLWithPath: cache)
            let seedURL = URL(fileURLWithPath: seedDir)

            try fm.createDirectory(
                at: catalogURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fm.createDirectory(
                at: cacheURL,
                withIntermediateDirectories: true
            )

            let db = try CatalogDatabase(path: catalogURL.path)
            let store = PreviewStore(cacheDirectory: cacheURL)

            let contents = try fm.contentsOfDirectory(
                at: seedURL,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            )
            let jpegs = contents
                .filter { $0.pathExtension.lowercased() == "jpg" || $0.pathExtension.lowercased() == "jpeg" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }

            var imported = 0
            var skipped = 0

            // Deterministic capture dates so `reload`'s sort order is
            // stable and fixture flows can assert on ordering later.
            let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

            let copies = max(1, duplicate)
            var assetIndex = 0
            for url in jpegs {
                let fileData = try Data(contentsOf: url)
                let (width, height) = Self.pixelSize(of: url) ?? (800, 600)
                let size = (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

                for copy in 0..<copies {
                    let hashInput: Data
                    if copy == 0 {
                        hashInput = fileData
                    } else {
                        hashInput = fileData + Data([UInt8(copy)])
                    }
                    let hash = SHA256.hash(data: hashInput)
                        .map { String(format: "%02x", $0) }.joined()
                    if try db.fetchAsset(byHash: hash) != nil {
                        skipped += 1
                        assetIndex += 1
                        continue
                    }
                    let asset = Asset(
                        contentHash: hash,
                        originalFilename: url.lastPathComponent,
                        captureDate: baseDate.addingTimeInterval(Double(assetIndex) * 3600),
                        importedDate: baseDate,
                        sourceType: .digital,
                        width: width,
                        height: height,
                        bytes: Int64(size)
                    )
                    try db.insertAsset(asset)
                    try await store.generate(for: asset, sourceURL: url)
                    imported += 1
                    assetIndex += 1
                }
            }

            // Emit a one-line summary so flow logs are readable.
            print("dimroom-fixture: imported=\(imported) skipped=\(skipped) from \(seedURL.path)")
        }

        private static func pixelSize(of url: URL) -> (Int, Int)? {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? Int,
                  let h = props[kCGImagePropertyPixelHeight] as? Int else {
                return nil
            }
            return (w, h)
        }
    }
}
