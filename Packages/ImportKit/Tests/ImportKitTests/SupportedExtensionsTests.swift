import XCTest
@testable import ImportKit

final class SupportedExtensionsTests: XCTestCase {
    func testAllSupportedExtensionsRecognised() {
        let all = [
            "jpg", "jpeg", "heic", "heif", "png",
            "tiff", "tif",
            "dng", "cr2", "cr3", "nef", "arw", "raf", "rw2", "orf",
        ]
        for ext in all {
            XCTAssertTrue(SupportedExtensions.isSupported(ext), "\(ext) should be supported")
            XCTAssertTrue(SupportedExtensions.isSupported(ext.uppercased()))
            XCTAssertTrue(SupportedExtensions.isSupported(".\(ext)"))
        }
    }

    func testUnsupportedExtensions() {
        for ext in ["txt", "mov", "mp4", "xmp", "aae", "", "gif", "bmp"] {
            XCTAssertFalse(SupportedExtensions.isSupported(ext), "\(ext) should be unsupported")
        }
    }

    func testRawSubset() {
        XCTAssertTrue(SupportedExtensions.isRaw("dng"))
        XCTAssertTrue(SupportedExtensions.isRaw("CR3"))
        XCTAssertTrue(SupportedExtensions.isRaw(".nef"))
        XCTAssertFalse(SupportedExtensions.isRaw("jpg"))
        XCTAssertFalse(SupportedExtensions.isRaw("heic"))
    }
}
