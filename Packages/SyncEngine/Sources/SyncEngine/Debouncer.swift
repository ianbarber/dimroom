import Foundation

/// Collapses bursts of `scheduleTrigger()` calls into a single `fire`
/// invocation after `interval` has elapsed without any new triggers.
/// A `maxInterval` ceiling guarantees forward progress when triggers
/// keep arriving — otherwise continuous editing would defer the publish
/// indefinitely.
///
/// The first trigger of a quiet window records the "first signal" time;
/// the ceiling fires once `now() - firstSignal >= maxInterval` even if
/// new triggers keep arriving.
actor Debouncer {
    private let interval: Duration
    private let maxInterval: Duration
    private let clock: any Clock<Duration>
    private let fire: @Sendable () async -> Void

    /// Increments on every `scheduleTrigger()` so the wake-up task can
    /// detect "newer trigger arrived while I was sleeping" and skip
    /// firing. `nil` means the most-recent fire was actually run and
    /// the debouncer is idle.
    private var pendingGeneration: UInt64 = 0
    /// Generation the current wake-up task is scheduled to fire for.
    /// When it wakes and finds `pendingGeneration != scheduledGeneration`
    /// it reschedules instead of firing.
    private var scheduledGeneration: UInt64?
    private var firstSignalAt: ContinuousClock.Instant?
    private var wakeUpTask: Task<Void, Never>?

    init(
        interval: Duration,
        maxInterval: Duration,
        clock: any Clock<Duration>,
        fire: @escaping @Sendable () async -> Void
    ) {
        self.interval = interval
        self.maxInterval = maxInterval
        self.clock = clock
        self.fire = fire
    }

    /// Record a new trigger. Bumps the generation and reschedules the
    /// wake-up task so the fire happens `interval` after this call (or
    /// `maxInterval` after the first pending trigger, whichever comes
    /// first).
    func scheduleTrigger() {
        pendingGeneration &+= 1
        if firstSignalAt == nil {
            firstSignalAt = ContinuousClock.now
        }
        reschedule()
    }

    /// Cancel any pending fire. The next `scheduleTrigger()` starts a
    /// fresh window.
    func cancel() {
        wakeUpTask?.cancel()
        wakeUpTask = nil
        scheduledGeneration = nil
        firstSignalAt = nil
    }

    /// Cancel the pending fire (if any) and run `fire` synchronously
    /// once. Used by `CatalogPublisher.publishNow()` to short-circuit
    /// debounce when the harness forces an immediate publish.
    func fireNow() async {
        wakeUpTask?.cancel()
        wakeUpTask = nil
        scheduledGeneration = nil
        firstSignalAt = nil
        await fire()
    }

    private func reschedule() {
        wakeUpTask?.cancel()
        let generation = pendingGeneration
        scheduledGeneration = generation
        let delay = nextDelay()
        let clock = self.clock
        wakeUpTask = Task { [weak self] in
            try? await clock.sleep(for: delay)
            await self?.onWakeUp(generation: generation)
        }
    }

    private func onWakeUp(generation: UInt64) async {
        // Cancelled or superseded? Skip.
        if Task.isCancelled { return }
        if scheduledGeneration != generation { return }
        if pendingGeneration != generation {
            // A newer trigger arrived after this wake-up was scheduled
            // but the reschedule() landed before us; defer to it.
            return
        }
        // Reset book-keeping before firing so a trigger that arrives
        // *during* the publish enqueues a fresh window after it
        // finishes.
        scheduledGeneration = nil
        firstSignalAt = nil
        wakeUpTask = nil
        await fire()
    }

    private func nextDelay() -> Duration {
        guard let firstSignalAt else { return interval }
        let elapsed = ContinuousClock.now - firstSignalAt
        let remainingCeiling = maxInterval - elapsed
        if remainingCeiling <= .zero {
            return .zero
        }
        return min(interval, remainingCeiling)
    }
}
