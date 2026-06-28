import Dispatch
import Foundation
import Logging

/// The runtime control surface returned by `bootstrap`.
///
/// Wraps the `DestinationRegistry` and exposes the lifecycle affordances an app
/// needs after startup: runtime destination add/remove, the global level toggle
/// (backing a shipping "Enable Debug Logging" feature), and drain.
public final class LoggingHandle: @unchecked Sendable {
    public let fileDestination: FileDestination
    public let memoryDestination: MemoryDestination?
    public let registry: DestinationRegistry

    private let observerLock = NSLock()
    private var levelChangeObserver: (@Sendable (Logger.Level) -> Void)?

    init(
        fileDestination: FileDestination,
        memoryDestination: MemoryDestination?,
        registry: DestinationRegistry
    ) {
        self.fileDestination = fileDestination
        self.memoryDestination = memoryDestination
        self.registry = registry

        // Register exactly one registry observer that dispatches to whatever
        // closure `onEffectiveLevelChange` currently holds. This keeps callback
        // swapping cheap (no re-registration) and preserves the registry's
        // contract: the callback fires on the thread that called setGlobalLevel.
        registry.addLevelObserver { [weak self] level in
            guard let self else {
                return
            }
            observerLock.lock()
            let observer = levelChangeObserver
            observerLock.unlock()
            observer?(level)
        }
    }

    public var destinations: [any LogDestination] {
        registry.snapshot()
    }

    // MARK: Runtime registry mutation

    /// Adds a destination at runtime. It inherits the current global level.
    public func addDestination(_ destination: any LogDestination) {
        registry.addDestination(destination)
    }

    /// Removes a destination at runtime, draining and tearing it down before
    /// `completion` fires.
    public func removeDestination(
        _ destination: any LogDestination,
        completion: @escaping @Sendable () -> Void = {}
    ) {
        registry.removeDestination(destination, completion: completion)
    }

    // MARK: Global level control

    /// Writes `level` into the handler gate **and** every destination's
    /// `FilterConfig`, so the level reaches the destinations, not just the
    /// handler. Backs a shipping "Enable Debug Logging" toggle. Fires
    /// `onEffectiveLevelChange` on the calling thread.
    public func setGlobalLevel(_ level: Logger.Level) {
        registry.setGlobalLevel(level)
    }

    /// The current global minimum level — a readback for a settings toggle and
    /// for slaving closed SDKs (Setapp/Sparkle) to one sink.
    public var effectiveLevel: Logger.Level {
        registry.globalLevel()
    }

    /// Fires when the global level changes, **delivered on the thread that
    /// called `setGlobalLevel`** (the app hops to main itself if its SDK setter
    /// needs it).
    public var onEffectiveLevelChange: (@Sendable (Logger.Level) -> Void)? {
        get {
            observerLock.lock()
            defer { observerLock.unlock() }
            return levelChangeObserver
        }
        set {
            observerLock.lock()
            levelChangeObserver = newValue
            observerLock.unlock()
        }
    }

    // MARK: Drain

    /// A blocking barrier flushing every destination. **Test / known-safe-thread
    /// only** — never from `main` at shutdown or from an `async` context.
    public func drain() {
        let semaphore = DispatchSemaphore(value: 0)
        drain {
            semaphore.signal()
        }
        semaphore.wait()
    }

    /// Non-blocking drain: flushes every destination, calling `completion` once
    /// all have flushed. The source of truth and the production shutdown call.
    public func drain(completion: @escaping @Sendable () -> Void) {
        let destinations = registry.snapshot()
        guard !destinations.isEmpty else {
            completion()
            return
        }
        let group = DispatchGroup()
        for destination in destinations {
            group.enter()
            destination.drain {
                group.leave()
            }
        }
        group.notify(queue: DispatchQueue.global()) {
            completion()
        }
    }

    /// Async drain, derived from the callback form so the two can't drift.
    public func drain() async {
        await withCheckedContinuation { continuation in
            drain {
                continuation.resume()
            }
        }
    }
}
