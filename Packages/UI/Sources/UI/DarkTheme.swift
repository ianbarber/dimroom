import SwiftUI

extension View {
    /// Dark-theme contrast convention for system-styled controls that sit
    /// on the app's hardcoded dark backgrounds (`Color(white:0.05…0.12)`).
    ///
    /// Applies `.colorScheme(.dark)` — deliberately **not**
    /// `.foregroundStyle(.white)`/`.tint(.white)`. The recurring
    /// "control X is dark-on-dark" bug (#74, #241, #319, #325) comes from
    /// AppKit-backed controls: a `.segmented` `Picker` is an
    /// `NSSegmentedControl` and a `.menu`/`.borderlessButton` `Menu` is an
    /// `NSPopUpButton`, and both render their labels through the system
    /// control foreground path, which **ignores** `.foregroundStyle`
    /// applied to the SwiftUI subtree. Forcing the dark colour scheme is
    /// the proven lever that makes those system-supplied labels render
    /// light against the dark background.
    ///
    /// Reach for this on segmented / menu `Picker`s and borderless `Menu`s.
    /// It does **not** fit a `.bordered` `Button` that carries a custom
    /// dark `.tint` (e.g. the crop toggle): there the label inherits the
    /// tint colour, and the fix is a per-call `.foregroundStyle(.white)` on
    /// the label's children instead — see `DevelopView.cropToggle`.
    ///
    /// Because the regression lives in the live AppKit rendering path, an
    /// offline `ImageRenderer`/`cacheDisplay` snapshot can't catch a
    /// dropped modifier; the load-bearing guard is the structural test
    /// (`DarkThemeControlStructureTests` and friends) that asserts the
    /// `.colorScheme(.dark)` environment value stays attached.
    func darkThemeControl() -> some View {
        self.colorScheme(.dark)
    }
}
