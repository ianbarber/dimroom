import Combine
import Foundation

/// User-tunable app-level configuration backed by `UserDefaults`.
///
/// Every key has a matching `defaultValue(for:)` that mirrors the value
/// hardcoded in the codebase before this store existed, so a fresh
/// install (no values written) reads identical numbers to the old
/// hardcoded path. `AppDelegate` constructs one of these at launch and
/// subscribes to each `@Published` property to push live updates into
/// the downstream components — `LibraryViewModel`, `OriginalsCache`,
/// `CatalogPublisher`, `DevelopViewModel`.
@MainActor
public final class SettingsStore: ObservableObject {
    /// Backing defaults — injected so tests can use an isolated
    /// `UserDefaults(suiteName:)` without touching the user's plist.
    private let defaults: UserDefaults

    // MARK: - General

    @Published public var libraryGridColumns: Int {
        didSet { defaults.set(libraryGridColumns, forKey: Keys.libraryGridColumns) }
    }

    @Published public var recentImportsLimit: Int {
        didSet { defaults.set(recentImportsLimit, forKey: Keys.recentImportsLimit) }
    }

    // MARK: - Cache

    @Published public var originalsCacheBudgetBytes: Int64 {
        didSet { defaults.set(NSNumber(value: originalsCacheBudgetBytes), forKey: Keys.originalsCacheBudgetBytes) }
    }

    /// 0 means "unset" (no enforcement). Future eviction code lands later.
    @Published public var previewCacheBudgetBytes: Int64 {
        didSet { defaults.set(NSNumber(value: previewCacheBudgetBytes), forKey: Keys.previewCacheBudgetBytes) }
    }

    // MARK: - Drive

    @Published public var driveAutoPublish: Bool {
        didSet { defaults.set(driveAutoPublish, forKey: Keys.driveAutoPublish) }
    }

    @Published public var driveAutoPublishDebounceSeconds: Int {
        didSet { defaults.set(driveAutoPublishDebounceSeconds, forKey: Keys.driveAutoPublishDebounceSeconds) }
    }

    @Published public var driveAutoUploadOriginals: Bool {
        didSet { defaults.set(driveAutoUploadOriginals, forKey: Keys.driveAutoUploadOriginals) }
    }

    /// Consumer lands with the sync-poll feature (issue #6.2). Stored
    /// today so the settings UI is complete; nothing reads it yet.
    @Published public var driveSyncPollSeconds: Int {
        didSet { defaults.set(driveSyncPollSeconds, forKey: Keys.driveSyncPollSeconds) }
    }

    // MARK: - Develop

    @Published public var developHistogramVisible: Bool {
        didSet { defaults.set(developHistogramVisible, forKey: Keys.developHistogramVisible) }
    }

    @Published public var developRenderDebounceMillis: Int {
        didSet { defaults.set(developRenderDebounceMillis, forKey: Keys.developRenderDebounceMillis) }
    }

    @Published public var developSaveDebounceMillis: Int {
        didSet { defaults.set(developSaveDebounceMillis, forKey: Keys.developSaveDebounceMillis) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.libraryGridColumns = Self.readInt(defaults, key: Keys.libraryGridColumns,
            fallback: Defaults.libraryGridColumns)
        self.recentImportsLimit = Self.readInt(defaults, key: Keys.recentImportsLimit,
            fallback: Defaults.recentImportsLimit)
        self.originalsCacheBudgetBytes = Self.readInt64(defaults, key: Keys.originalsCacheBudgetBytes,
            fallback: Defaults.originalsCacheBudgetBytes)
        self.previewCacheBudgetBytes = Self.readInt64(defaults, key: Keys.previewCacheBudgetBytes,
            fallback: Defaults.previewCacheBudgetBytes)
        self.driveAutoPublish = Self.readBool(defaults, key: Keys.driveAutoPublish,
            fallback: Defaults.driveAutoPublish)
        self.driveAutoPublishDebounceSeconds = Self.readInt(defaults,
            key: Keys.driveAutoPublishDebounceSeconds,
            fallback: Defaults.driveAutoPublishDebounceSeconds)
        self.driveAutoUploadOriginals = Self.readBool(defaults, key: Keys.driveAutoUploadOriginals,
            fallback: Defaults.driveAutoUploadOriginals)
        self.driveSyncPollSeconds = Self.readInt(defaults, key: Keys.driveSyncPollSeconds,
            fallback: Defaults.driveSyncPollSeconds)
        self.developHistogramVisible = Self.readBool(defaults, key: Keys.developHistogramVisible,
            fallback: Defaults.developHistogramVisible)
        self.developRenderDebounceMillis = Self.readInt(defaults, key: Keys.developRenderDebounceMillis,
            fallback: Defaults.developRenderDebounceMillis)
        self.developSaveDebounceMillis = Self.readInt(defaults, key: Keys.developSaveDebounceMillis,
            fallback: Defaults.developSaveDebounceMillis)
    }

    /// Remove every stored value so the next read returns the default.
    /// Used by tests; not exposed in the UI.
    public func reset() {
        for key in Keys.all {
            defaults.removeObject(forKey: key)
        }
        libraryGridColumns = Defaults.libraryGridColumns
        recentImportsLimit = Defaults.recentImportsLimit
        originalsCacheBudgetBytes = Defaults.originalsCacheBudgetBytes
        previewCacheBudgetBytes = Defaults.previewCacheBudgetBytes
        driveAutoPublish = Defaults.driveAutoPublish
        driveAutoPublishDebounceSeconds = Defaults.driveAutoPublishDebounceSeconds
        driveAutoUploadOriginals = Defaults.driveAutoUploadOriginals
        driveSyncPollSeconds = Defaults.driveSyncPollSeconds
        developHistogramVisible = Defaults.developHistogramVisible
        developRenderDebounceMillis = Defaults.developRenderDebounceMillis
        developSaveDebounceMillis = Defaults.developSaveDebounceMillis
    }

    // MARK: - Harness bridge

    /// Read a setting by its wire key (the short name without the
    /// `dimroom.settings.` prefix). Returns `nil` for unknown keys so
    /// the harness can surface a helpful error.
    public func value(forWireKey key: String) -> Any? {
        switch key {
        case "libraryGridColumns": return libraryGridColumns
        case "recentImportsLimit": return recentImportsLimit
        case "originalsCacheBudgetBytes": return originalsCacheBudgetBytes
        case "previewCacheBudgetBytes": return previewCacheBudgetBytes
        case "driveAutoPublish": return driveAutoPublish
        case "driveAutoPublishDebounceSeconds": return driveAutoPublishDebounceSeconds
        case "driveAutoUploadOriginals": return driveAutoUploadOriginals
        case "driveSyncPollSeconds": return driveSyncPollSeconds
        case "developHistogramVisible": return developHistogramVisible
        case "developRenderDebounceMillis": return developRenderDebounceMillis
        case "developSaveDebounceMillis": return developSaveDebounceMillis
        default: return nil
        }
    }

    /// Write a setting by its wire key. The harness gives us a JSON
    /// value already decoded into Foundation types — Int (or NSNumber)
    /// for numerics, Bool for toggles, etc. Returns false on unknown
    /// key or type mismatch so the harness can return an error.
    @discardableResult
    public func setValue(forWireKey key: String, value: Any) -> Bool {
        switch key {
        case "libraryGridColumns":
            guard let v = Self.asInt(value) else { return false }
            libraryGridColumns = v
        case "recentImportsLimit":
            guard let v = Self.asInt(value) else { return false }
            recentImportsLimit = v
        case "originalsCacheBudgetBytes":
            guard let v = Self.asInt64(value) else { return false }
            originalsCacheBudgetBytes = v
        case "previewCacheBudgetBytes":
            guard let v = Self.asInt64(value) else { return false }
            previewCacheBudgetBytes = v
        case "driveAutoPublish":
            guard let v = Self.asBool(value) else { return false }
            driveAutoPublish = v
        case "driveAutoPublishDebounceSeconds":
            guard let v = Self.asInt(value) else { return false }
            driveAutoPublishDebounceSeconds = v
        case "driveAutoUploadOriginals":
            guard let v = Self.asBool(value) else { return false }
            driveAutoUploadOriginals = v
        case "driveSyncPollSeconds":
            guard let v = Self.asInt(value) else { return false }
            driveSyncPollSeconds = v
        case "developHistogramVisible":
            guard let v = Self.asBool(value) else { return false }
            developHistogramVisible = v
        case "developRenderDebounceMillis":
            guard let v = Self.asInt(value) else { return false }
            developRenderDebounceMillis = v
        case "developSaveDebounceMillis":
            guard let v = Self.asInt(value) else { return false }
            developSaveDebounceMillis = v
        default:
            return false
        }
        return true
    }

    // MARK: - Defaults table

    public enum Defaults {
        public static let libraryGridColumns: Int = 4
        public static let recentImportsLimit: Int = 20
        public static let originalsCacheBudgetBytes: Int64 = 10 * 1024 * 1024 * 1024
        public static let previewCacheBudgetBytes: Int64 = 0
        public static let driveAutoPublish: Bool = true
        public static let driveAutoPublishDebounceSeconds: Int = 30
        public static let driveAutoUploadOriginals: Bool = false
        public static let driveSyncPollSeconds: Int = 300
        public static let developHistogramVisible: Bool = true
        /// Preserves the current `DevelopViewModel.scheduleRender` 50ms
        /// behaviour. Issue body says "30ms"; CLAUDE.md says defaults
        /// must match current constants. Default to 50ms; the user can
        /// drop the slider to 30ms in the UI.
        public static let developRenderDebounceMillis: Int = 50
        public static let developSaveDebounceMillis: Int = 500
    }

    public enum Keys {
        public static let libraryGridColumns = "dimroom.settings.libraryGridColumns"
        public static let recentImportsLimit = "dimroom.settings.recentImportsLimit"
        public static let originalsCacheBudgetBytes = "dimroom.settings.originalsCacheBudgetBytes"
        public static let previewCacheBudgetBytes = "dimroom.settings.previewCacheBudgetBytes"
        public static let driveAutoPublish = "dimroom.settings.driveAutoPublish"
        public static let driveAutoPublishDebounceSeconds = "dimroom.settings.driveAutoPublishDebounceSeconds"
        public static let driveAutoUploadOriginals = "dimroom.settings.driveAutoUploadOriginals"
        public static let driveSyncPollSeconds = "dimroom.settings.driveSyncPollSeconds"
        public static let developHistogramVisible = "dimroom.settings.developHistogramVisible"
        public static let developRenderDebounceMillis = "dimroom.settings.developRenderDebounceMillis"
        public static let developSaveDebounceMillis = "dimroom.settings.developSaveDebounceMillis"

        public static let all: [String] = [
            libraryGridColumns,
            recentImportsLimit,
            originalsCacheBudgetBytes,
            previewCacheBudgetBytes,
            driveAutoPublish,
            driveAutoPublishDebounceSeconds,
            driveAutoUploadOriginals,
            driveSyncPollSeconds,
            developHistogramVisible,
            developRenderDebounceMillis,
            developSaveDebounceMillis,
        ]
    }

    // MARK: - Private read helpers

    private static func readInt(_ defaults: UserDefaults, key: String, fallback: Int) -> Int {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return defaults.integer(forKey: key)
    }

    private static func readInt64(_ defaults: UserDefaults, key: String, fallback: Int64) -> Int64 {
        guard let value = defaults.object(forKey: key) as? NSNumber else { return fallback }
        return value.int64Value
    }

    private static func readBool(_ defaults: UserDefaults, key: String, fallback: Bool) -> Bool {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return defaults.bool(forKey: key)
    }

    // MARK: - Type coercion for harness writes

    private static func asInt(_ value: Any) -> Int? {
        if let v = value as? Int { return v }
        if let v = value as? Int64 { return Int(v) }
        if let v = value as? NSNumber { return v.intValue }
        if let v = value as? Double { return Int(v) }
        if let v = value as? String { return Int(v) }
        return nil
    }

    private static func asInt64(_ value: Any) -> Int64? {
        if let v = value as? Int64 { return v }
        if let v = value as? Int { return Int64(v) }
        if let v = value as? NSNumber { return v.int64Value }
        if let v = value as? Double { return Int64(v) }
        if let v = value as? String { return Int64(v) }
        return nil
    }

    private static func asBool(_ value: Any) -> Bool? {
        if let v = value as? Bool { return v }
        if let v = value as? NSNumber { return v.boolValue }
        if let v = value as? String {
            switch v.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        return nil
    }
}
