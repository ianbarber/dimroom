import XCTest
@testable import SyncEngine

final class DebouncerTests: XCTestCase {

    /// Bursts of triggers within the quiet window should collapse to a
    /// single fire after the window elapses.
    func testCollapsesRapidTriggers() async throws {
        let counter = FireCounter()
        let debouncer = Debouncer(
            interval: .milliseconds(80),
            maxInterval: .seconds(10),
            clock: ContinuousClock(),
            fire: { await counter.increment() }
        )

        for _ in 0..<10 {
            await debouncer.scheduleTrigger()
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(250))

        let fires = await counter.value
        XCTAssertEqual(fires, 1, "ten rapid triggers should collapse into one fire")
    }

    /// A single trigger should fire once the quiet window elapses.
    func testQuietWindowFiresExactlyOnce() async throws {
        let counter = FireCounter()
        let debouncer = Debouncer(
            interval: .milliseconds(60),
            maxInterval: .seconds(10),
            clock: ContinuousClock(),
            fire: { await counter.increment() }
        )

        await debouncer.scheduleTrigger()
        try await Task.sleep(for: .milliseconds(200))

        let fires = await counter.value
        XCTAssertEqual(fires, 1)
    }

    /// `cancel()` before the quiet window elapses must suppress the
    /// fire entirely.
    func testCancelBeforeFireSuppresses() async throws {
        let counter = FireCounter()
        let debouncer = Debouncer(
            interval: .milliseconds(120),
            maxInterval: .seconds(10),
            clock: ContinuousClock(),
            fire: { await counter.increment() }
        )

        await debouncer.scheduleTrigger()
        try await Task.sleep(for: .milliseconds(20))
        await debouncer.cancel()
        try await Task.sleep(for: .milliseconds(250))

        let fires = await counter.value
        XCTAssertEqual(fires, 0)
    }

    /// When triggers keep arriving and the per-trigger window keeps
    /// resetting, the `maxInterval` ceiling must still force a fire.
    func testMaxIntervalCeilingForcesFire() async throws {
        let counter = FireCounter()
        let debouncer = Debouncer(
            // Per-trigger window is long enough that the ceiling is
            // what fires us; otherwise the test is racy.
            interval: .milliseconds(500),
            maxInterval: .milliseconds(150),
            clock: ContinuousClock(),
            fire: { await counter.increment() }
        )

        // Re-trigger every 20 ms for 300 ms — the per-trigger window
        // never gets a chance to elapse, but the 150 ms ceiling does.
        let stop = Date().addingTimeInterval(0.3)
        while Date() < stop {
            await debouncer.scheduleTrigger()
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(100))

        let fires = await counter.value
        XCTAssertGreaterThanOrEqual(fires, 1, "ceiling should have forced at least one fire")
    }

    /// After firing, subsequent trigger windows must be independent —
    /// the second window's quiet timer should restart from scratch.
    func testIndependentFireCycles() async throws {
        let counter = FireCounter()
        let debouncer = Debouncer(
            interval: .milliseconds(80),
            maxInterval: .seconds(10),
            clock: ContinuousClock(),
            fire: { await counter.increment() }
        )

        // First cycle
        await debouncer.scheduleTrigger()
        try await Task.sleep(for: .milliseconds(200))

        // Second cycle
        await debouncer.scheduleTrigger()
        try await Task.sleep(for: .milliseconds(200))

        let fires = await counter.value
        XCTAssertEqual(fires, 2)
    }

    /// `fireNow()` runs the fire immediately and clears pending state.
    func testFireNowRunsImmediatelyAndClears() async throws {
        let counter = FireCounter()
        let debouncer = Debouncer(
            interval: .milliseconds(80),
            maxInterval: .seconds(10),
            clock: ContinuousClock(),
            fire: { await counter.increment() }
        )

        await debouncer.scheduleTrigger()
        await debouncer.fireNow()

        let firesAfterImmediate = await counter.value
        XCTAssertEqual(firesAfterImmediate, 1, "fireNow should fire synchronously")

        try await Task.sleep(for: .milliseconds(200))
        let firesAfterWait = await counter.value
        XCTAssertEqual(firesAfterWait, 1, "the previously scheduled trigger should not fire again")
    }
}

/// Actor-backed counter so the fire closure can mutate test state
/// without data races, regardless of which task the debouncer's
/// internal wake-up lands on.
private actor FireCounter {
    private var count = 0
    var value: Int { count }
    func increment() { count += 1 }
}
