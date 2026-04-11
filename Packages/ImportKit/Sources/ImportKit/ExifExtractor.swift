import Foundation
import ImageIO

/// Metadata extracted from an image file during import.
public struct ExtractedMetadata: Sendable, Equatable {
    /// `DateTimeOriginal` parsed from EXIF, interpreted in the local timezone.
    /// Nil if missing or unparseable.
    public var captureDate: Date?
    /// `Make` + `Model` joined with a single space. Nil if both are missing.
    public var sourceDevice: String?
    /// Pixel width as reported by ImageIO. Zero if unavailable.
    public var width: Int
    /// Pixel height as reported by ImageIO. Zero if unavailable.
    public var height: Int
    /// Rotation in degrees (0, 90, 180, 270) derived from EXIF Orientation.
    /// Mirroring is discarded.
    public var rotationDegrees: Int

    public init(
        captureDate: Date? = nil,
        sourceDevice: String? = nil,
        width: Int = 0,
        height: Int = 0,
        rotationDegrees: Int = 0
    ) {
        self.captureDate = captureDate
        self.sourceDevice = sourceDevice
        self.width = width
        self.height = height
        self.rotationDegrees = rotationDegrees
    }
}

/// Extracts EXIF/TIFF metadata from an image file using ImageIO.
///
/// Reads properties at index 0 only — we don't care about embedded previews
/// or multi-image containers for import.
public enum ExifExtractor {
    /// Reads metadata from the file at `url`. Returns an empty struct if the
    /// file cannot be opened as an image. Never throws — failing to parse
    /// EXIF is not an import-blocking error; assets without metadata still
    /// get inserted.
    public static func extract(from url: URL) -> ExtractedMetadata {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any]
        else {
            return ExtractedMetadata()
        }

        var metadata = ExtractedMetadata()

        if let width = properties[kCGImagePropertyPixelWidth] as? Int {
            metadata.width = width
        } else if let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue {
            metadata.width = width
        }
        if let height = properties[kCGImagePropertyPixelHeight] as? Int {
            metadata.height = height
        } else if let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue {
            metadata.height = height
        }

        if let orientationRaw = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue {
            metadata.rotationDegrees = rotationDegrees(for: orientationRaw)
        }

        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            let make = (tiff[kCGImagePropertyTIFFMake] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let model = (tiff[kCGImagePropertyTIFFModel] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            metadata.sourceDevice = joinDeviceString(make: make, model: model)
        }

        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let dateString = exif[kCGImagePropertyExifDateTimeOriginal] as? String
        {
            metadata.captureDate = Self.exifDateFormatter.date(from: dateString)
        }

        return metadata
    }

    /// EXIF `DateTimeOriginal` is formatted as `"yyyy:MM:dd HH:mm:ss"` with no
    /// timezone. We parse it in the current timezone and accept the resulting
    /// ambiguity as a known limitation — real timezone handling needs GPS
    /// correlation and is out of scope for Stage 1.3.
    private static let exifDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f
    }()

    /// Maps the 8 EXIF orientation values to a rotation in degrees, dropping
    /// the mirroring axis (1/2 → 0, 3/4 → 180, 5/6 → 90, 7/8 → 270).
    static func rotationDegrees(for orientation: Int) -> Int {
        switch orientation {
        case 1, 2: return 0
        case 3, 4: return 180
        case 5, 6: return 90
        case 7, 8: return 270
        default: return 0
        }
    }

    /// Produces a "Make Model" string, de-duplicated when the model already
    /// starts with the make (e.g. "Canon Canon EOS R6" → "Canon EOS R6").
    static func joinDeviceString(make: String?, model: String?) -> String? {
        let m = make?.isEmpty == false ? make : nil
        let mo = model?.isEmpty == false ? model : nil
        switch (m, mo) {
        case (nil, nil): return nil
        case (let make?, nil): return make
        case (nil, let model?): return model
        case (let make?, let model?):
            if model.lowercased().hasPrefix(make.lowercased()) {
                return model
            }
            return "\(make) \(model)"
        }
    }
}
