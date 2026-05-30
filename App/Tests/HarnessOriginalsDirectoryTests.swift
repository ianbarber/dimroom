@testable import Dimroom
import XCTest

/// Layer A coverage for #367 — defaulting the originals staging/cache
/// directory to a per-flow sandbox under the system temp dir when running
/// in `--harness` mode and neither `DIMROOM_ORIGINALS_DIR` nor
/// `--originals-cache` is supplied. The point of the knob is to isolate
/// harness flows *at the source*: a flow that forgets to scope its
/// originals dir lands in a temp sandbox instead of leaking into the
/// user's real Application Support originals cache.
///
/// These pin the pure `resolveOriginalsDirectory(isHarness:…)` overload
/// and its `stableDigest` keying so the precedence, the relaunch-stable
/// sandbox path, and the deterministic digest can't regress without a
/// test going red.
final class HarnessOriginalsDirectoryTests: XCTestCase {
    // Fixed inputs reused across cases. None of these touch the real
    // filesystem — the resolver is pure URL arithmetic.
    private let tempDir = URL(fileURLWithPath: "/var/test-tmp", isDirectory: true)
    private let appSupportFallback = URL(
        fileURLWithPath: "/Users/test/Library/Application Support/Dimroom/originals",
        isDirectory: true
    )
    private let socket = "/tmp/dimroom-harness.sock"

    // MARK: - Explicit DIMROOM_ORIGINALS_DIR always wins

    func testExplicitEnvDirWinsWhenHarness() {
        let resolved = AppDelegate.resolveOriginalsDirectory(
            isHarness: true,
            envOriginalsDir: "/explicit/originals",
            harnessSocketPath: socket,
            temporaryDirectory: tempDir,
            applicationSupportFallback: appSupportFallback
        )
        XCTAssertEqual(resolved, URL(fileURLWithPath: "/explicit/originals"))
    }

    func testExplicitEnvDirWinsWhenNotHarness() {
        let resolved = AppDelegate.resolveOriginalsDirectory(
            isHarness: false,
            envOriginalsDir: "/explicit/originals",
            harnessSocketPath: socket,
            temporaryDirectory: tempDir,
            applicationSupportFallback: appSupportFallback
        )
        XCTAssertEqual(resolved, URL(fileURLWithPath: "/explicit/originals"))
    }

    /// An empty value is treated as "unset" — matches the `!isEmpty`
    /// guard the original instance method used, so a flow that exports
    /// `DIMROOM_ORIGINALS_DIR=` doesn't pin the real App Support dir.
    func testEmptyEnvDirFallsThroughToHarnessSandbox() {
        let resolved = AppDelegate.resolveOriginalsDirectory(
            isHarness: true,
            envOriginalsDir: "",
            harnessSocketPath: socket,
            temporaryDirectory: tempDir,
            applicationSupportFallback: appSupportFallback
        )
        XCTAssertTrue(resolved.path.hasPrefix(tempDir.path))
        XCTAssertNotEqual(resolved, appSupportFallback)
    }

    // MARK: - Harness sandbox default

    func testHarnessSandboxIsUnderTempAndNotAppSupport() {
        let resolved = AppDelegate.resolveOriginalsDirectory(
            isHarness: true,
            envOriginalsDir: nil,
            harnessSocketPath: socket,
            temporaryDirectory: tempDir,
            applicationSupportFallback: appSupportFallback
        )
        XCTAssertTrue(
            resolved.path.hasPrefix(tempDir.path),
            "harness sandbox must live under the temp dir, got \(resolved.path)"
        )
        XCTAssertFalse(
            resolved.path.hasPrefix(appSupportFallback.path),
            "harness sandbox must never sit under the real App Support originals dir"
        )
    }

    func testHarnessSandboxPathShape() {
        let resolved = AppDelegate.resolveOriginalsDirectory(
            isHarness: true,
            envOriginalsDir: nil,
            harnessSocketPath: socket,
            temporaryDirectory: tempDir,
            applicationSupportFallback: appSupportFallback
        )
        let expected = tempDir
            .appendingPathComponent("dimroom-harness-originals", isDirectory: true)
            .appendingPathComponent(AppDelegate.stableDigest(socket), isDirectory: true)
        XCTAssertEqual(resolved, expected)
        // The digest must be the last path component (per-flow bucket) and
        // its parent the shared `dimroom-harness-originals` namespace.
        XCTAssertEqual(resolved.lastPathComponent, AppDelegate.stableDigest(socket))
        XCTAssertEqual(
            resolved.deletingLastPathComponent().lastPathComponent,
            "dimroom-harness-originals"
        )
    }

    /// Relaunch stability: the same socket path resolves to the same
    /// sandbox on repeated calls (the multi-launch flows depend on this).
    func testSameSocketYieldsSameSandbox() {
        func resolve() -> URL {
            AppDelegate.resolveOriginalsDirectory(
                isHarness: true,
                envOriginalsDir: nil,
                harnessSocketPath: socket,
                temporaryDirectory: tempDir,
                applicationSupportFallback: appSupportFallback
            )
        }
        XCTAssertEqual(resolve(), resolve())
    }

    /// Per-flow isolation: distinct socket paths resolve to distinct
    /// sandboxes, so two flows running back to back can't collide.
    func testDifferentSocketsYieldDifferentSandboxes() {
        let a = AppDelegate.resolveOriginalsDirectory(
            isHarness: true,
            envOriginalsDir: nil,
            harnessSocketPath: "/tmp/flow-a.sock",
            temporaryDirectory: tempDir,
            applicationSupportFallback: appSupportFallback
        )
        let b = AppDelegate.resolveOriginalsDirectory(
            isHarness: true,
            envOriginalsDir: nil,
            harnessSocketPath: "/tmp/flow-b.sock",
            temporaryDirectory: tempDir,
            applicationSupportFallback: appSupportFallback
        )
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Production (non-harness) path is untouched

    func testNonHarnessReturnsAppSupportFallback() {
        let resolved = AppDelegate.resolveOriginalsDirectory(
            isHarness: false,
            envOriginalsDir: nil,
            harnessSocketPath: socket,
            temporaryDirectory: tempDir,
            applicationSupportFallback: appSupportFallback
        )
        XCTAssertEqual(resolved, appSupportFallback)
    }

    // MARK: - Digest determinism

    /// Pins known input→output so an accidental switch to Swift's
    /// per-process-seeded `Hasher` / `String.hashValue` (which would break
    /// relaunch stability for multi-launch flows) is caught immediately.
    func testStableDigestPinsKnownOutputs() {
        XCTAssertEqual(AppDelegate.stableDigest("abc"), "e71fa2190541574b")
        XCTAssertEqual(
            AppDelegate.stableDigest("/tmp/dimroom-harness.sock"),
            "8ec34f0ca7bec322"
        )
    }

    func testStableDigestIsDeterministicAndDistinct() {
        XCTAssertEqual(
            AppDelegate.stableDigest("/tmp/flow-a.sock"),
            AppDelegate.stableDigest("/tmp/flow-a.sock")
        )
        XCTAssertNotEqual(
            AppDelegate.stableDigest("/tmp/flow-a.sock"),
            AppDelegate.stableDigest("/tmp/flow-b.sock")
        )
    }
}
