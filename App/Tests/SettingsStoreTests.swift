import XCTest
@testable import Dimroom

@MainActor
final class SettingsStoreTests: XCTestCase {

    /// Use an isolated `UserDefaults(suiteName:)` so tests can't see
    /// (or leak into) the user's real preferences file.
    private func makeIsolatedDefaults() -> UserDefaults {
        let suite = "dimroom.settings-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: - Defaults

    func testFreshStoreReadsHardcodedDefaults() {
        let store = SettingsStore(defaults: makeIsolatedDefaults())
        XCTAssertEqual(store.libraryGridColumns, SettingsStore.Defaults.libraryGridColumns)
        XCTAssertEqual(store.libraryGridColumns, 4)
        XCTAssertEqual(store.recentImportsLimit, SettingsStore.Defaults.recentImportsLimit)
        XCTAssertEqual(store.recentImportsLimit, 20)
        XCTAssertEqual(store.originalsCacheBudgetBytes, SettingsStore.Defaults.originalsCacheBudgetBytes)
        XCTAssertEqual(store.originalsCacheBudgetBytes, 10 * 1024 * 1024 * 1024)
        XCTAssertEqual(store.previewCacheBudgetBytes, SettingsStore.Defaults.previewCacheBudgetBytes)
        XCTAssertEqual(store.previewCacheBudgetBytes, 0)
        XCTAssertEqual(store.driveAutoPublish, SettingsStore.Defaults.driveAutoPublish)
        XCTAssertTrue(store.driveAutoPublish)
        XCTAssertEqual(store.driveAutoPublishDebounceSeconds, 30)
        XCTAssertEqual(store.driveAutoUploadOriginals, false)
        XCTAssertEqual(store.driveSyncPollSeconds, 300)
        XCTAssertEqual(store.developHistogramVisible, true)
        XCTAssertEqual(store.developRenderDebounceMillis, 50)
        XCTAssertEqual(store.developSaveDebounceMillis, 500)
    }

    // MARK: - Persistence

    func testWritesPersistAcrossInstances() {
        let defaults = makeIsolatedDefaults()
        let first = SettingsStore(defaults: defaults)
        first.libraryGridColumns = 6
        first.driveAutoPublish = false
        first.developRenderDebounceMillis = 80

        let second = SettingsStore(defaults: defaults)
        XCTAssertEqual(second.libraryGridColumns, 6)
        XCTAssertFalse(second.driveAutoPublish)
        XCTAssertEqual(second.developRenderDebounceMillis, 80)
    }

    func testInt64BudgetPersistsWithoutTruncation() {
        // 5 GB — too large for `defaults.integer(forKey:)` to safely
        // round-trip on a 32-bit Int system, and the NSNumber path
        // must be the one used.
        let defaults = makeIsolatedDefaults()
        let first = SettingsStore(defaults: defaults)
        first.originalsCacheBudgetBytes = 5_368_709_120
        let second = SettingsStore(defaults: defaults)
        XCTAssertEqual(second.originalsCacheBudgetBytes, 5_368_709_120)
    }

    // MARK: - reset()

    func testResetRemovesAllValues() {
        let defaults = makeIsolatedDefaults()
        let store = SettingsStore(defaults: defaults)
        store.libraryGridColumns = 7
        store.recentImportsLimit = 50
        store.driveAutoPublish = false
        store.developSaveDebounceMillis = 1000

        store.reset()

        XCTAssertEqual(store.libraryGridColumns, 4)
        XCTAssertEqual(store.recentImportsLimit, 20)
        XCTAssertTrue(store.driveAutoPublish)
        XCTAssertEqual(store.developSaveDebounceMillis, 500)

        // Backing store also cleared so a fresh instance sees defaults.
        let fresh = SettingsStore(defaults: defaults)
        XCTAssertEqual(fresh.libraryGridColumns, 4)
        XCTAssertEqual(fresh.developSaveDebounceMillis, 500)
    }

    // MARK: - Wire-key bridge

    func testValueForWireKeyMatchesPublishedProperties() {
        let store = SettingsStore(defaults: makeIsolatedDefaults())
        store.libraryGridColumns = 5
        store.developHistogramVisible = false

        XCTAssertEqual(store.value(forWireKey: "libraryGridColumns") as? Int, 5)
        XCTAssertEqual(store.value(forWireKey: "developHistogramVisible") as? Bool, false)
        XCTAssertNil(store.value(forWireKey: "garbage"))
    }

    func testSetValueForWireKeyAcceptsCoercibleTypes() {
        let store = SettingsStore(defaults: makeIsolatedDefaults())

        XCTAssertTrue(store.setValue(forWireKey: "libraryGridColumns", value: 7))
        XCTAssertEqual(store.libraryGridColumns, 7)

        // JSON-decoded numerics arrive as NSNumber sometimes.
        XCTAssertTrue(store.setValue(forWireKey: "recentImportsLimit", value: NSNumber(value: 33)))
        XCTAssertEqual(store.recentImportsLimit, 33)

        XCTAssertTrue(store.setValue(forWireKey: "driveAutoPublish", value: false))
        XCTAssertFalse(store.driveAutoPublish)

        XCTAssertTrue(store.setValue(forWireKey: "originalsCacheBudgetBytes", value: NSNumber(value: 4_294_967_296)))
        XCTAssertEqual(store.originalsCacheBudgetBytes, 4_294_967_296)
    }

    func testSetValueForWireKeyRejectsUnknownKey() {
        let store = SettingsStore(defaults: makeIsolatedDefaults())
        XCTAssertFalse(store.setValue(forWireKey: "garbage", value: 1))
    }

    func testSetValueForWireKeyRejectsTypeMismatch() {
        let store = SettingsStore(defaults: makeIsolatedDefaults())
        // String that isn't a number can't become Int.
        XCTAssertFalse(store.setValue(forWireKey: "libraryGridColumns", value: "hello"))
        XCTAssertEqual(store.libraryGridColumns, 4)
    }

    // MARK: - Keys table

    func testKeysListContainsEveryDefinedKey() {
        // Each key string starts with the `dimroom.settings.` prefix.
        XCTAssertEqual(SettingsStore.Keys.all.count, 14)
        for key in SettingsStore.Keys.all {
            XCTAssertTrue(key.hasPrefix("dimroom.settings."), "\(key) is missing the dimroom.settings. prefix")
        }
        // No duplicates — typo regression guard.
        XCTAssertEqual(Set(SettingsStore.Keys.all).count, SettingsStore.Keys.all.count)
    }
}
