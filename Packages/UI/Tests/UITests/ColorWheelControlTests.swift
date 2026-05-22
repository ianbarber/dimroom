import CoreGraphics
import XCTest
@testable import UI

final class ColorWheelControlTests: XCTestCase {
    private let size = CGSize(width: 100, height: 100)

    func test_centre_returns_zero_hue_and_saturation() {
        let (hue, sat) = ColorWheelControl.pointToPolar(
            point: CGPoint(x: 50, y: 50),
            inSize: size
        )
        XCTAssertEqual(hue, 0, accuracy: 1e-9)
        XCTAssertEqual(sat, 0, accuracy: 1e-9)
    }

    func test_right_edge_is_hue_zero_sat_one_hundred() {
        let (hue, sat) = ColorWheelControl.pointToPolar(
            point: CGPoint(x: 100, y: 50),
            inSize: size
        )
        XCTAssertEqual(hue, 0, accuracy: 1e-9)
        XCTAssertEqual(sat, 100, accuracy: 1e-9)
    }

    /// 0° at 3 o'clock and clockwise → 90° hits the bottom edge.
    /// Matches `AngularGradient`'s default sweep direction.
    func test_bottom_edge_is_hue_ninety() {
        let (hue, sat) = ColorWheelControl.pointToPolar(
            point: CGPoint(x: 50, y: 100),
            inSize: size
        )
        XCTAssertEqual(hue, 90, accuracy: 1e-9)
        XCTAssertEqual(sat, 100, accuracy: 1e-9)
    }

    func test_left_edge_is_hue_one_eighty() {
        let (hue, sat) = ColorWheelControl.pointToPolar(
            point: CGPoint(x: 0, y: 50),
            inSize: size
        )
        XCTAssertEqual(hue, 180, accuracy: 1e-9)
        XCTAssertEqual(sat, 100, accuracy: 1e-9)
    }

    /// 12 o'clock — clockwise from 3 o'clock that's 270°, i.e. the
    /// `atan2(-1, 0)` branch is normalised to `[0, 360)`.
    func test_top_edge_is_hue_two_seventy() {
        let (hue, sat) = ColorWheelControl.pointToPolar(
            point: CGPoint(x: 50, y: 0),
            inSize: size
        )
        XCTAssertEqual(hue, 270, accuracy: 1e-9)
        XCTAssertEqual(sat, 100, accuracy: 1e-9)
    }

    /// Drags past the edge clamp saturation to 100 but keep tracking
    /// hue — matches how Capture One's wheel behaves so a fast drag
    /// off-control still picks a hue.
    func test_outside_disc_clamps_saturation_to_one_hundred() {
        let (_, sat) = ColorWheelControl.pointToPolar(
            point: CGPoint(x: 200, y: 50),
            inSize: size
        )
        XCTAssertEqual(sat, 100, accuracy: 1e-9)
    }

    /// Round-trip a handful of (hue, sat) values through
    /// `polarToPoint` → `pointToPolar` to lock the inverse math.
    func test_polar_to_point_round_trip() {
        let cases: [(hue: Double, sat: Double)] = [
            (0, 0),
            (0, 50),
            (45, 25),
            (90, 80),
            (180, 100),
            (270, 60),
            (359, 99)
        ]
        for (hue, sat) in cases {
            let point = ColorWheelControl.polarToPoint(
                hue: hue,
                saturation: sat,
                inSize: size
            )
            let (h2, s2) = ColorWheelControl.pointToPolar(
                point: point,
                inSize: size
            )
            if sat == 0 {
                XCTAssertEqual(s2, 0, accuracy: 1e-6, "sat 0 should round-trip to 0")
            } else {
                XCTAssertEqual(h2, hue, accuracy: 1e-6, "hue \(hue) should round-trip")
                XCTAssertEqual(s2, sat, accuracy: 1e-6, "sat \(sat) should round-trip")
            }
        }
    }

    func test_polar_to_point_centre_at_sat_zero() {
        let point = ColorWheelControl.polarToPoint(
            hue: 200,
            saturation: 0,
            inSize: size
        )
        XCTAssertEqual(point.x, 50, accuracy: 1e-9)
        XCTAssertEqual(point.y, 50, accuracy: 1e-9)
    }

    func test_polar_to_point_clamps_saturation_above_one_hundred() {
        let inside = ColorWheelControl.polarToPoint(hue: 0, saturation: 100, inSize: size)
        let above = ColorWheelControl.polarToPoint(hue: 0, saturation: 250, inSize: size)
        XCTAssertEqual(inside, above)
    }

    func test_zero_size_is_safe() {
        let (hue, sat) = ColorWheelControl.pointToPolar(
            point: CGPoint(x: 0, y: 0),
            inSize: .zero
        )
        XCTAssertEqual(hue, 0)
        XCTAssertEqual(sat, 0)
    }
}
