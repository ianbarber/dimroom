import SwiftUI
import TestSupport
import XCTest

final class ExampleSnapshotTest: XCTestCase {

    func testExampleView() {
        let view = NSHostingController(
            rootView: ExampleView()
        )
        view.view.frame = NSRect(x: 0, y: 0, width: 200, height: 100)

        assertSnapshot(of: view, as: .image(perceptualPrecision: 0.98))
    }
}

/// A trivial SwiftUI view used only to prove the snapshot pipeline works.
private struct ExampleView: View {
    var body: some View {
        ZStack {
            Color.blue
            Text("Snapshot OK")
                .foregroundStyle(.white)
                .font(.system(size: 16, weight: .bold, design: .monospaced))
        }
        .frame(width: 200, height: 100)
    }
}
