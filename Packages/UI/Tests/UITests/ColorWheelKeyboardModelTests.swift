import XCTest
@testable import UI

final class ColorWheelKeyboardModelTests: XCTestCase {
    private typealias Model = ColorWheelKeyboardModel

    // MARK: - Hue (plain arrows)

    func test_right_arrow_nudges_hue_up_by_step() {
        let (hue, sat) = Model.nudge(hue: 0, saturation: 0, key: .right, shift: false)
        XCTAssertEqual(hue, 5, accuracy: 1e-9)
        XCTAssertEqual(sat, 0, accuracy: 1e-9)
    }

    func test_left_arrow_from_zero_wraps_to_355() {
        let (hue, sat) = Model.nudge(hue: 0, saturation: 0, key: .left, shift: false)
        XCTAssertEqual(hue, 355, accuracy: 1e-9)
        XCTAssertEqual(sat, 0, accuracy: 1e-9)
    }

    func test_up_and_down_arrows_also_nudge_hue() {
        let (up, _) = Model.nudge(hue: 100, saturation: 40, key: .up, shift: false)
        XCTAssertEqual(up, 105, accuracy: 1e-9)
        let (down, _) = Model.nudge(hue: 100, saturation: 40, key: .down, shift: false)
        XCTAssertEqual(down, 95, accuracy: 1e-9)
    }

    func test_hue_wraps_past_360() {
        let (hue, sat) = Model.nudge(hue: 358, saturation: 50, key: .right, shift: false)
        XCTAssertEqual(hue, 3, accuracy: 1e-9)
        XCTAssertEqual(sat, 50, accuracy: 1e-9)
    }

    func test_plain_arrow_leaves_saturation_untouched() {
        let (_, sat) = Model.nudge(hue: 30, saturation: 73, key: .right, shift: false)
        XCTAssertEqual(sat, 73, accuracy: 1e-9)
    }

    // MARK: - Saturation (shift + arrows)

    func test_shift_right_nudges_saturation_up() {
        let (hue, sat) = Model.nudge(hue: 30, saturation: 50, key: .right, shift: true)
        XCTAssertEqual(hue, 30, accuracy: 1e-9)
        XCTAssertEqual(sat, 55, accuracy: 1e-9)
    }

    func test_shift_up_also_nudges_saturation_up() {
        let (hue, sat) = Model.nudge(hue: 30, saturation: 50, key: .up, shift: true)
        XCTAssertEqual(hue, 30, accuracy: 1e-9)
        XCTAssertEqual(sat, 55, accuracy: 1e-9)
    }

    func test_shift_left_and_down_nudge_saturation_down() {
        let (_, left) = Model.nudge(hue: 30, saturation: 50, key: .left, shift: true)
        XCTAssertEqual(left, 45, accuracy: 1e-9)
        let (_, down) = Model.nudge(hue: 30, saturation: 50, key: .down, shift: true)
        XCTAssertEqual(down, 45, accuracy: 1e-9)
    }

    func test_saturation_clamps_at_zero() {
        let (hue, sat) = Model.nudge(hue: 30, saturation: 0, key: .left, shift: true)
        XCTAssertEqual(hue, 30, accuracy: 1e-9)
        XCTAssertEqual(sat, 0, accuracy: 1e-9)
    }

    func test_saturation_clamps_at_hundred() {
        let (hue, sat) = Model.nudge(hue: 30, saturation: 100, key: .right, shift: true)
        XCTAssertEqual(hue, 30, accuracy: 1e-9)
        XCTAssertEqual(sat, 100, accuracy: 1e-9)
    }

    func test_shift_arrow_leaves_hue_untouched() {
        let (hue, _) = Model.nudge(hue: 217, saturation: 50, key: .right, shift: true)
        XCTAssertEqual(hue, 217, accuracy: 1e-9)
    }

    // MARK: - Reset

    func test_reset_returns_identity() {
        let (hue, sat) = Model.reset()
        XCTAssertEqual(hue, 0, accuracy: 1e-9)
        XCTAssertEqual(sat, 0, accuracy: 1e-9)
    }

    // MARK: - Wire-name mapping

    func test_arrow_key_wire_names() {
        XCTAssertEqual(Model.ArrowKey(wireName: "left"), .left)
        XCTAssertEqual(Model.ArrowKey(wireName: "right"), .right)
        XCTAssertEqual(Model.ArrowKey(wireName: "up"), .up)
        XCTAssertEqual(Model.ArrowKey(wireName: "down"), .down)
        XCTAssertNil(Model.ArrowKey(wireName: "diagonal"))
        XCTAssertNil(Model.ArrowKey(wireName: ""))
    }
}
