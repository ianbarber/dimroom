import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum IconWriter {

    public static func pngData(from image: CGImage) -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            fatalError("Failed to create PNG image destination")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            fatalError("Failed to finalize PNG image destination")
        }
        return data as Data
    }

    public static func writePNG(_ image: CGImage, to url: URL) throws {
        let data = pngData(from: image)
        try data.write(to: url)
    }
}
