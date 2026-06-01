import Catalog
import CoreGraphics
import CoreImage
import EditEngine
import Foundation
import XCTest
@testable import Previews

/// Budget enforcement + LRU eviction for `PreviewStore` (issue #271).
final class PreviewStoreBudgetTests: XCTestCase {

    private var scratchDir: URL!
    private var cacheDir: URL!
    private var fixturesDir: URL!

    override func setUpWithError() throws {
        scratchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreviewStoreBudgetTests-\(UUID().uuidString)", isDirectory: true)
        cacheDir = scratchDir.appendingPathComponent("cache", isDirectory: true)
        fixturesDir = scratchDir.appendingPathComponent("fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixturesDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratchDir, FileManager.default.fileExists(atPath: scratchDir.path) {
            try FileManager.default.removeItem(at: scratchDir)
        }
    }

    // MARK: - Helpers

    /// Monotonically increasing clock so LRU `lastAccess` ordering is
    /// deterministic — the Nth `generate` call is stamped strictly later
    /// than the (N-1)th, with no reliance on wall-clock resolution.
    private final class StepClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current: Date
        private let step: TimeInterval
        init(start: Date = Date(timeIntervalSince1970: 1_000_000), step: TimeInterval = 60) {
            self.current = start
            self.step = step
        }
        func now() -> Date {
            lock.lock(); defer { lock.unlock() }
            let value = current
            current = current.addingTimeInterval(step)
            return value
        }
    }

    private func makeStore(
        in directory: URL? = nil,
        budgetBytes: Int64,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) -> PreviewStore {
        PreviewStore(
            cacheDirectory: directory ?? cacheDir,
            budgetBytes: budgetBytes,
            context: CIContext(options: [.useSoftwareRenderer: false]),
            fileManager: .default,
            jpegQuality: 0.85,
            clock: clock
        )
    }

    private func makeAsset(_ hash: String) -> Asset {
        Asset(
            contentHash: hash,
            originalFilename: "test.jpg",
            sourceType: .digital,
            width: 1600,
            height: 1200,
            rawFormat: nil,
            rotation: 0,
            bytes: 0
        )
    }

    private func makeSource() throws -> URL {
        let url = fixturesDir.appendingPathComponent("source-\(UUID().uuidString).jpg")
        try FixtureFactory.makeSyntheticJPEG(width: 1600, height: 1200, at: url)
        return url
    }

    /// Sum of every cached `.jpg` byte on disk — ground truth the index
    /// must agree with.
    private func onDiskBytes(in root: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "jpg" {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            total += Int64(size)
        }
        return total
    }

    private func masterFilesExist(for asset: Asset, in store: PreviewStore) -> Bool {
        store.masterThumbnailURL(for: asset) != nil && store.masterPreviewURL(for: asset) != nil
    }

    // MARK: - AC: 0 disables enforcement

    func testBudgetZeroDisablesEviction() async throws {
        let store = makeStore(budgetBytes: 0)
        let source = try makeSource()

        let assets = (0..<5).map { makeAsset("zerobudget00000000a\($0)") }
        for asset in assets {
            _ = try await store.generate(for: asset, sourceURL: source)
        }

        // Nothing evicted: every master file survives and the tracked size
        // equals the full on-disk total.
        for asset in assets {
            XCTAssertTrue(masterFilesExist(for: asset, in: store),
                "budget 0 must not evict any asset")
        }
        let tracked = await store.currentSizeBytes()
        XCTAssertEqual(tracked, onDiskBytes(in: cacheDir))
        XCTAssertGreaterThan(tracked, 0)
    }

    // MARK: - AC: generate evicts LRU when over budget

    func testGenerateEvictsLeastRecentlyGeneratedWhenOverBudget() async throws {
        let clock = StepClock()
        // Start unlimited so we can measure one asset's footprint, then
        // tighten the budget to fit ~two before the third generate trips
        // eviction of the oldest.
        let store = makeStore(budgetBytes: 0, clock: { clock.now() })
        let source = try makeSource()

        let a1 = makeAsset("lru0000000000000000a1")
        let a2 = makeAsset("lru0000000000000000a2")
        let a3 = makeAsset("lru0000000000000000a3")

        _ = try await store.generate(for: a1, sourceURL: source)   // oldest
        let perAsset = await store.currentSizeBytes()
        XCTAssertGreaterThan(perAsset, 0)

        _ = try await store.generate(for: a2, sourceURL: source)
        // Budget that comfortably fits two assets but not three.
        await store.setBudget(perAsset * 2 + perAsset / 2)

        _ = try await store.generate(for: a3, sourceURL: source)   // newest, protected

        // a1 (LRU) evicted; a2 and a3 (more recent) survive.
        XCTAssertFalse(masterFilesExist(for: a1, in: store),
            "least-recently-generated asset must be evicted first")
        XCTAssertTrue(masterFilesExist(for: a2, in: store))
        XCTAssertTrue(masterFilesExist(for: a3, in: store))

        let tracked = await store.currentSizeBytes()
        XCTAssertLessThanOrEqual(tracked, perAsset * 2 + perAsset / 2)
        XCTAssertEqual(tracked, onDiskBytes(in: cacheDir),
            "index must agree with disk after eviction")
    }

    // MARK: - AC: setting a smaller budget evicts down to fit

    func testSetBudgetEvictsImmediately() async throws {
        let clock = StepClock()
        let store = makeStore(budgetBytes: 0, clock: { clock.now() })
        let source = try makeSource()

        let a1 = makeAsset("setbudget0000000000a1")
        let a2 = makeAsset("setbudget0000000000a2")
        let a3 = makeAsset("setbudget0000000000a3")
        _ = try await store.generate(for: a1, sourceURL: source)
        let perAsset = await store.currentSizeBytes()
        _ = try await store.generate(for: a2, sourceURL: source)
        _ = try await store.generate(for: a3, sourceURL: source)
        let beforeShrink = await store.currentSizeBytes()
        XCTAssertEqual(beforeShrink, perAsset * 3)

        // Shrink to fit a single asset — no further generate.
        let budget = perAsset + perAsset / 2
        await store.setBudget(budget)

        let afterShrink = await store.currentSizeBytes()
        XCTAssertLessThanOrEqual(afterShrink, budget)
        // Only the most-recently-generated asset survives.
        XCTAssertFalse(masterFilesExist(for: a1, in: store))
        XCTAssertFalse(masterFilesExist(for: a2, in: store))
        XCTAssertTrue(masterFilesExist(for: a3, in: store))
        XCTAssertEqual(afterShrink, onDiskBytes(in: cacheDir))
    }

    // MARK: - Display-tier writes count toward the budget

    func testRegenerateWithEditCountsTowardBudget() async throws {
        let store = makeStore(budgetBytes: 0)
        let source = try makeSource()
        let asset = makeAsset("regenbudget000000000")

        _ = try await store.generate(for: asset, sourceURL: source)
        let afterGenerate = await store.currentSizeBytes()
        XCTAssertEqual(afterGenerate, onDiskBytes(in: cacheDir))

        var state = EditState()
        state.exposure = 1.5
        await store.regenerateWithEdit(for: asset, editState: state)

        let afterRegenerate = await store.currentSizeBytes()
        XCTAssertGreaterThan(afterRegenerate, afterGenerate,
            "display-tier files must be registered against the budget")
        XCTAssertEqual(afterRegenerate, onDiskBytes(in: cacheDir),
            "index must count both master and display tiers")

        // Resetting to identity deletes the display files and drops their
        // bytes from the tracked total.
        await store.regenerateWithEdit(for: asset, editState: EditState())
        let afterReset = await store.currentSizeBytes()
        XCTAssertEqual(afterReset, afterGenerate)
        XCTAssertEqual(afterReset, onDiskBytes(in: cacheDir))
    }

    // MARK: - removeAll / invalidate keep the index honest

    func testRemoveAllAndInvalidateClearIndex() async throws {
        let store = makeStore(budgetBytes: 0)
        let source = try makeSource()
        let a1 = makeAsset("clearindex000000000a1")
        let a2 = makeAsset("clearindex000000000a2")

        _ = try await store.generate(for: a1, sourceURL: source)
        _ = try await store.generate(for: a2, sourceURL: source)
        let populated = await store.currentSizeBytes()
        XCTAssertGreaterThan(populated, 0)

        await store.removeAll()
        let afterRemoveAll = await store.currentSizeBytes()
        XCTAssertEqual(afterRemoveAll, 0)
        XCTAssertEqual(onDiskBytes(in: cacheDir), 0)

        // Regenerate one asset, then invalidate it — its entries must drop
        // back to zero and stay in step with disk.
        _ = try await store.generate(for: a1, sourceURL: source)
        let single = await store.currentSizeBytes()
        XCTAssertGreaterThan(single, 0)
        XCTAssertEqual(single, onDiskBytes(in: cacheDir))

        await store.invalidate(for: a1)
        let afterInvalidate = await store.currentSizeBytes()
        XCTAssertEqual(afterInvalidate, 0)
        XCTAssertEqual(onDiskBytes(in: cacheDir), 0)
    }

    // MARK: - Index rebuild from a pre-existing cache

    func testIndexRebuildsFromDirectoryWhenMissing() async throws {
        let source = try makeSource()
        let assets = (0..<3).map { makeAsset("rebuild0000000000a\($0)") }

        // Phase 1: populate the cache and persist index.json.
        let store1 = makeStore(budgetBytes: 0)
        for asset in assets {
            _ = try await store1.generate(for: asset, sourceURL: source)
        }
        let populated = await store1.currentSizeBytes()
        XCTAssertGreaterThan(populated, 0)

        // Drop the manifest, leaving the JPEGs on disk.
        try FileManager.default.removeItem(at: cacheDir.appendingPathComponent("index.json"))

        // Phase 2: a fresh store must rebuild its accounting from disk.
        let store2 = makeStore(budgetBytes: 0)
        let rebuilt = await store2.currentSizeBytes()
        XCTAssertEqual(rebuilt, populated,
            "rebuilt index must account for every pre-existing cache byte")
        XCTAssertEqual(rebuilt, onDiskBytes(in: cacheDir))

        // And eviction must operate on those rebuilt bytes.
        let budget = populated / 3 + populated / 6   // ~ half an asset over one third
        await store2.setBudget(budget)
        let afterEvict = await store2.currentSizeBytes()
        XCTAssertLessThanOrEqual(afterEvict, budget)
        XCTAssertLessThan(afterEvict, populated,
            "eviction must shrink a rebuilt-from-disk cache")
        XCTAssertEqual(afterEvict, onDiskBytes(in: cacheDir))
    }
}
