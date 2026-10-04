import Foundation
import Logging

public final class DestinationRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var destinations: [any LogDestination]

    /// Serializes the global-level writers (`setGlobalLevel` and the inherit
    /// step of `addDestination`) and guards `levelObservers`.
    private let levelLock = NSLock()
    private var levelObservers: [(Logger.Level) -> Void] = []

    /// The global level and the per-category floors the handlers check before
    /// they render anything. `bootstrap` shares it with the pre-config handler.
    let gate: LevelGate

    public convenience init(
        destinations: [any LogDestination] = [],
        globalLevel: Logger.Level = .info
    ) {
        self.init(destinations: destinations, globalLevel: globalLevel, gate: LevelGate())
    }

    init(
        destinations: [any LogDestination],
        globalLevel: Logger.Level,
        gate: LevelGate
    ) {
        self.destinations = destinations
        self.gate = gate
        for destination in destinations {
            observeFilterConfig(of: destination)
        }
        rebuildGate(globalLevel: globalLevel)
    }

    /// The effective global minimum level.
    public func globalLevel() -> Logger.Level {
        gate.globalLevel()
    }

    /// Writes `level` into the gate **and** into the `FilterConfig` of every
    /// destination that follows the global level, then notifies observers on
    /// the calling thread. A destination whose config has
    /// `followsGlobalLevel == false` keeps its own level. The gate write and
    /// the per-destination fan-out happen under `levelLock` as one unit, so two
    /// concurrent setters can't leave a durable gate-vs-destination mismatch. A
    /// destination added afterward inherits the level via `addDestination`
    /// (also under `levelLock`).
    ///
    /// Lock-ordering: `levelLock` is held while rebuilding the gate (its own
    /// locks, then `snapshot()` and each destination's filter lock) and while
    /// calling `setFilterConfig`. None of those re-enters `levelLock`, so the
    /// nesting introduces no cycle.
    public func setGlobalLevel(_ level: Logger.Level) {
        let observers: [(Logger.Level) -> Void]
        let changed: Bool

        levelLock.lock()
        changed = gate.globalLevel() != level
        observers = levelObservers
        rebuildGate(globalLevel: level)
        for destination in snapshot() {
            var config = destination.filterConfig()
            guard config.followsGlobalLevel else {
                continue
            }
            config.minimumLevel = level
            destination.setFilterConfig(config)
        }
        levelLock.unlock()

        if changed {
            for observer in observers {
                observer(level)
            }
        }
    }

    /// Registers an observer fired (on the setter's thread) when the global
    /// level changes. Returns the current level so a fresh observer can sync up.
    @discardableResult
    func addLevelObserver(_ observer: @escaping (Logger.Level) -> Void) -> Logger.Level {
        levelLock.lock()
        defer { levelLock.unlock() }
        levelObservers.append(observer)
        return gate.globalLevel()
    }

    /// Adds `destination`. If its config follows the global level, it inherits
    /// the current global level; otherwise it keeps its own.
    public func addDestination(_ destination: any LogDestination) {
        let identifier = ObjectIdentifier(destination)
        lock.lock()
        let alreadyRegistered = destinations.contains {
            ObjectIdentifier($0) == identifier
        }
        if !alreadyRegistered {
            destinations.append(destination)
        }
        lock.unlock()
        guard !alreadyRegistered else {
            return
        }
        observeFilterConfig(of: destination)

        // Inherit the global level under `levelLock` so this can't race a
        // concurrent `setGlobalLevel` into a lost update on the new destination.
        levelLock.lock()
        var config = destination.filterConfig()
        if config.followsGlobalLevel {
            config.minimumLevel = gate.globalLevel()
            destination.setFilterConfig(config)
        }
        rebuildGate()
        levelLock.unlock()
    }

    public func removeDestination(
        _ destination: any LogDestination,
        completion: @escaping @Sendable () -> Void = {}
    ) {
        let identifier = ObjectIdentifier(destination)
        let removed: (any LogDestination)?

        lock.lock()
        if let index = destinations.firstIndex(
            where: { ObjectIdentifier($0) == identifier }
        ) {
            removed = destinations.remove(at: index)
        } else {
            removed = nil
        }
        lock.unlock()

        guard let removed else {
            completion()
            return
        }
        (removed as? FilterConfigObservable)?.setFilterConfigObserver(
            nil,
            for: ObjectIdentifier(self)
        )
        rebuildGate()
        // tearDown runs drain+close on the destination's own serial queue, so
        // every prior `receive` is flushed (FIFO) before the close — this is the
        // "drain before teardown" the plan calls for, satisfied by queue order.
        removed.tearDown(completion: completion)
    }

    /// Rebuilds the level gate from every destination's current filter config.
    /// The built-in destinations report their own `setFilterConfig` calls; call
    /// this after changing the config of a registered custom destination.
    public func filterConfigDidChange() {
        rebuildGate()
    }

    public func snapshot() -> [any LogDestination] {
        lock.lock()
        defer { lock.unlock() }
        return destinations
    }

    public func fanOut(_ record: LogRecord) {
        let destinations = snapshot()
        for destination in destinations where destination.shouldLog(record) {
            destination.receive(record)
        }
    }

    private func rebuildGate(globalLevel: Logger.Level? = nil) {
        gate.rebuild(globalLevel: globalLevel) {
            snapshot()
        }
    }

    private func observeFilterConfig(of destination: any LogDestination) {
        (destination as? FilterConfigObservable)?.setFilterConfigObserver(
            { [weak self] in
                self?.rebuildGate()
            },
            for: ObjectIdentifier(self)
        )
    }
}
