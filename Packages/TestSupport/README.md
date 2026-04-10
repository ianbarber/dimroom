# TestSupport

Shared test utilities for dimroom packages. Provides snapshot testing via [swift-snapshot-testing](https://github.com/pointfreeco/swift-snapshot-testing).

## Adding snapshot tests to a package

1. Add `TestSupport` as a test dependency in your package's `Package.swift`:

```swift
.testTarget(
    name: "MyPackageTests",
    dependencies: [
        "MyPackage",
        .product(name: "TestSupport", package: "TestSupport"),
    ]
)
```

2. Add a package dependency on `TestSupport` at the top level:

```swift
dependencies: [
    .package(path: "../TestSupport"),
]
```

3. Import `TestSupport` in your test file — this gives you all `SnapshotTesting` assertions:

```swift
import TestSupport
import XCTest

final class MyViewSnapshotTest: XCTestCase {
    func testMyView() {
        let view = NSHostingController(rootView: MyView())
        view.view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)

        assertSnapshot(of: view, as: .image)
    }
}
```

## Snapshot strategies

**Text-based (`.dump`, `.description`):** Fully deterministic across machines. Prefer these when proving structure or testing non-visual behavior. The example test in this package uses `.dump`.

**Image-based (`.image`):** Renders the view to a PNG and compares pixels. Use for real view regression testing. Note that image snapshots can vary across machines due to GPU differences, anti-aliasing, and font rasterization — even for pure-geometry views. Always use precision tolerances with `.image`:

- **`perceptualPrecision`** — per-pixel color similarity threshold. `0.98` tolerates minor anti-aliasing differences.
- **`precision`** — fraction of pixels that must match. `0.99` tolerates up to 1% of pixels being completely different (e.g., text at a slightly different sub-pixel position).

```swift
assertSnapshot(of: view, as: .image(precision: 0.99, perceptualPrecision: 0.98))
```

## How it works

- **First run:** No golden exists yet, so the test records a snapshot and fails. This is expected.
- **Commit the golden:** The PNG is written to `Tests/<Target>Tests/__Snapshots__/<TestClass>/<testMethod>.1.png`. Commit it.
- **Subsequent runs:** The test compares new renders against the committed golden. If the image differs, the test fails and writes the new image next to the golden for inspection.

## Updating goldens

If you intentionally change a view, delete the golden PNG and re-run the test. It will record a new golden. Commit the updated file.

## Where goldens live

Each package keeps its own goldens:

```
Packages/
  MyPackage/
    Tests/
      MyPackageTests/
        __Snapshots__/
          MyViewSnapshotTest/
            testMyView.1.png
```

This is the `swift-snapshot-testing` default — no extra configuration needed.
