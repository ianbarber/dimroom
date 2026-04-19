import Foundation

/// Maps a filename to a Drive-friendly MIME type. RAW types use the
/// de-facto `image/x-vendor-format` names — Drive stores bytes regardless,
/// so an unknown extension just falls back to `application/octet-stream`.
public enum DriveMimeType {
    private static let byExtension: [String: String] = [
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "png": "image/png",
        "tif": "image/tiff",
        "tiff": "image/tiff",
        "heic": "image/heic",
        "heif": "image/heif",
        "cr2": "image/x-canon-cr2",
        "cr3": "image/x-canon-cr3",
        "nef": "image/x-nikon-nef",
        "arw": "image/x-sony-arw",
        "dng": "image/x-adobe-dng",
        "raf": "image/x-fuji-raf",
        "orf": "image/x-olympus-orf",
        "rw2": "image/x-panasonic-rw2",
    ]

    public static let fallback = "application/octet-stream"

    public static func mimeType(forFilename filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        return byExtension[ext] ?? fallback
    }
}
