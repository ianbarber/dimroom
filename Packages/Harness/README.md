# Harness

Local socket-based control surface for automated testing and agent-driven verification. Loads fixture catalogs, accepts JSON commands over a Unix socket, and enables headless smoke testing of user-facing actions.

## Pointer / gesture synthesis (`double-click-slider`)

> **Status: blocked (#348).** The command, geometry registry, coordinate
> model, scroll-into-view, and Layer C flow are all implemented and the
> computed click point lands on the target slider — but the synthetic
> pointer event does **not** currently reach SwiftUI's gesture recogniser
> in the headless harness, so the gesture never fires. SwiftUI ignores
> programmatically-built `NSEvent`s (in-process, any delivery method), and
> real `CGEvent` injection is silently dropped because the unsigned SPM
> harness binary is not Accessibility-trusted (`AXIsProcessTrusted()` is
> `false`, and CI runners won't grant trust to an unsigned binary). The
> reference flow `bin/harness-develop-gesture-reset-flow.sh` therefore
> fails its reset assertion and is **not enrolled in CI**. Resolving this
> needs an environment decision (signed/bundled app + TCC grant, or a
> different gesture-driving mechanism). The rest of this section describes
> the intended design.

Most harness commands route straight to a view-model method — e.g.
`reset-edit-parameter` calls `DevelopViewModel.resetParameter`, bypassing the
SwiftUI gesture chain in `ParameterSlider`. That leaves one class of bug —
gesture-arbitration bugs — unreachable by Layer C. The canonical example is
the Develop slider double-click reset (#265 / PR #347): the fix lives entirely
in `highPriorityGesture(TapGesture(count: 2))` vs the `Slider`'s built-in
click-to-position handling, so a view-model-level reset test passes even when
the gesture is broken.

`double-click-slider <parameter> [--at-fraction <0…1>]` closes that gap. It
posts a **genuine** left-button double-click `NSEvent` at a slider's track via
`NSWindow.sendEvent(_:)` and lets SwiftUI route it through the real gesture
recognisers — no view-model shortcut.

### How it works

1. **Geometry registry.** Each gesture-bearing `Slider` records its on-screen
   frame (SwiftUI `.global` space) into `GestureTargetRegistry` via the
   `.gestureTarget(key:)` modifier, keyed by the parameter wire-name
   (`vignetteAmount`, `exposure`, …). This is a plain dictionary write on
   layout and is **always on** — the registry is populated in production too,
   so the path the harness drives is identical to the one the UI renders
   (CLAUDE.md hard rule #4), not a parallel test code path.
2. **Scroll into view.** The handler sets `DevelopViewModel.pendingScrollToParameter`
   so off-fold controls (Vignette, Geometry — clipped in the 1024×768 harness
   window) are scrolled on-screen before the click, then waits for layout to
   settle.
3. **Coordinate model.** `PointerEventGeometry.windowPoint(globalFrame:contentHeight:fraction:)`
   converts the recorded SwiftUI frame (top-left origin) to an AppKit window
   point (bottom-left origin) by flipping Y against the content-view height.
   The pure flip math is unit-tested; the AppKit dispatch lives in the app's
   `PointerEventSynthesizer`.
4. **Click.** A down/up pair is posted twice, raising `clickCount` to 2 on the
   second pair so AppKit reports a double-click and `TapGesture(count: 2)`
   fires.

### The click-position-vs-identity rule (important)

macOS `Slider` jumps its value to the clicked position. To prove the *reset
gesture* fired — and not just that the click landed somewhere — a flow must:

- click at a **non-identity** track fraction (e.g. `--at-fraction 0.25`, which
  for the symmetric vignette sliders is ≈ −50, not the identity 0 at centre),
  and
- assert the value snapped to **identity** afterwards.

Only the reset gesture firing can explain reaching identity from a 0.25 click.
Pre-#347-fix, the `Slider`'s click-to-position would win and the value would
land near the click position, so the assertion would fail — the desired
regression signal.

`bin/harness-develop-gesture-reset-flow.sh` is the reference flow (regression
coverage for #265). It also asserts the value is genuinely off-identity
*before* the click as a negative control.

### Requirements & scope

- Needs a real window server (like the existing screenshot / Layer C flows);
  it is not a pure-headless capability. In-process `sendEvent` is used
  deliberately — no Accessibility / automation entitlement required.
- Today only a double-click against Develop sliders is supported. Drag / pan /
  scroll-wheel synthesis, other click counts, crop-overlay double-click
  (`CropOverlayView`), and the HSL panel (#318) are follow-ups that can build
  on the same registry + synthesizer.
