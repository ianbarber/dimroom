import Foundation

/// Per-lens correction parameters used by `Renderer` when `chromaticAberration`
/// / `lensVignette` are enabled on an asset whose EXIF lens model resolves to
/// a known profile.
///
/// v1 carries a single set of parameters per lens — treat as the lens's
/// wide-open / worst-case behaviour. Real corrections vary by focal length
/// and aperture; aperture / focal-length-aware interpolation is a follow-up
/// (see issue #253 plan, "Out of scope").
public struct LensProfile: Sendable, Equatable, Codable {
    /// Per-channel radial scale for chromatic-aberration correction. The R
    /// channel is scaled toward the centre (typically < 1.0); the B channel
    /// is scaled outward (typically > 1.0). Identity = (1.0, 1.0).
    public var caRedScale: Double
    public var caBlueScale: Double

    /// `CIVignette` parameters for lens-vignette correction. Intensity is
    /// negative to brighten corners (inverting the natural falloff);
    /// radius is the filter's input radius in normalised units.
    public var vignetteIntensity: Double
    public var vignetteRadius: Double

    public init(
        caRedScale: Double,
        caBlueScale: Double,
        vignetteIntensity: Double,
        vignetteRadius: Double
    ) {
        self.caRedScale = caRedScale
        self.caBlueScale = caBlueScale
        self.vignetteIntensity = vignetteIntensity
        self.vignetteRadius = vignetteRadius
    }
}

/// JSON-backed lens-profile lookup. Loads `Resources/lens-profiles.json`
/// from the package bundle on first use and caches the parsed table for the
/// life of the process.
///
/// Lookup is exact-match on the EXIF `LensModel` string. EXIF strings vary
/// across firmwares ("RF 50mm F1.2 L USM" vs "RF50mm F1.2 L USM"); fuzzy /
/// normalised matching is a follow-up.
public enum LensProfileLibrary {
    /// Returns the profile registered for `model`, or `nil` if either the
    /// model is unknown / nil or the bundled JSON failed to load.
    public static func lookup(for model: String?) -> LensProfile? {
        guard let model, !model.isEmpty else { return nil }
        return loadedProfiles[model]
    }

    /// Snapshot of the full bundled profile table. Exposed for tests; not
    /// intended for production use.
    public static var allProfiles: [String: LensProfile] {
        loadedProfiles
    }

    private static let loadedProfiles: [String: LensProfile] = {
        guard let url = Bundle.module.url(forResource: "lens-profiles", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: LensProfile].self, from: data)
        else {
            return [:]
        }
        return decoded
    }()
}
