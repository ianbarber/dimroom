import XCTest
@testable import EditEngine

final class LensProfileLibraryTests: XCTestCase {

    func testBundledJSONLoads() {
        XCTAssertFalse(
            LensProfileLibrary.allProfiles.isEmpty,
            "lens-profiles.json should bundle as a package resource"
        )
    }

    func testBundleContainsNoTestFixtureEntries() {
        // Synthetic `_test_*` profiles must never ship in the bundled
        // resource: they'd surface in `allProfiles` in production and
        // pollute the real lens catalogue. Renderer tests construct their
        // `LensProfile` values directly, so the bundle needs no fixtures.
        let leaked = LensProfileLibrary.allProfiles.keys.filter { $0.hasPrefix("_test_") }
        XCTAssertTrue(
            leaked.isEmpty,
            "lens-profiles.json must not contain synthetic test entries, found: \(leaked)"
        )
    }

    func testKnownLensReturnsProfile() {
        let profile = LensProfileLibrary.lookup(for: "RF 50mm F1.2 L USM")
        XCTAssertNotNil(profile)
        // Bundled file commits to a small (<1%) per-channel CA shift on
        // this lens — sanity-check the magnitudes to catch broken
        // JSON / decoding.
        if let profile {
            XCTAssertLessThan(profile.caRedScale, 1.0)
            XCTAssertGreaterThan(profile.caBlueScale, 1.0)
            XCTAssertLessThan(profile.vignetteIntensity, 0.0)
            XCTAssertGreaterThan(profile.vignetteRadius, 0.0)
        }
    }

    func testUnknownLensReturnsNil() {
        XCTAssertNil(LensProfileLibrary.lookup(for: "Imaginary 35mm F0.7"))
    }

    func testNilInputReturnsNil() {
        XCTAssertNil(LensProfileLibrary.lookup(for: nil))
    }

    func testEmptyStringReturnsNil() {
        XCTAssertNil(LensProfileLibrary.lookup(for: ""))
    }

    func testLookupIsExactMatchOnly() {
        // v1 is exact match: a trailing space or rearranged spacing must
        // not silently resolve to the canonical entry. This pins the
        // current behaviour so a future fuzzy-matching change has to
        // update this test deliberately.
        XCTAssertNil(LensProfileLibrary.lookup(for: "RF 50mm F1.2 L USM "))
        XCTAssertNil(LensProfileLibrary.lookup(for: "RF50mm F1.2 L USM"))
    }
}
