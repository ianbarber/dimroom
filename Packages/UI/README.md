# UI

SwiftUI views for Dimroom's main modes. The package is intentionally thin — a
view here is always backed by an `ObservableObject` that does its own work
against `Catalog` and `Previews`, so the views can be exercised headlessly in
Layer A tests and snapshotted in Layer B without booting the app target.

Currently ships the library grid (`LibraryView` + `LibraryViewModel`).
