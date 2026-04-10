import SwiftUI
import TestSupport
import XCTest

final class ExampleSnapshotTest: XCTestCase {

    func testExampleView() {
        let view = ExampleView()
        assertSnapshot(of: view, as: .dump)
    }
}

/// A trivial SwiftUI view used only to prove the snapshot pipeline works.
private struct ExampleView: View {
    var body: some View {
        HStack(spacing: 0) {
            Color.blue
            Color.red
        }
        .frame(width: 200, height: 100)
    }
}
