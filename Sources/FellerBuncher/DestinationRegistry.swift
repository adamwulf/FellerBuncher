import Foundation
import Logging

public final class DestinationRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var destinations: [any LogDestination]

    /// The global minimum level. It is the source of truth for the handler gate
    /// and is mirrored into every destination's `FilterConfig` by `setGlobalLevel`.
    private let levelLock = NSLock()
    private var globalLevelValue: Logger.Level
    private var levelObservers: [(Logger.Level) -> Void] = []

    public init(
        destinations: [any LogDestination] = [],
        globalLevel: Logger.Level = .info
    ) {
        self.destinations = destinations
        self.globalLevelValue = globalLevel
    }

    /// The effective global minimum level (the handler gate).
    public func globalLevel() -> Logger.Level {
        levelLock.lock()
        defer { levelLock.unlock() }
        return globalLevelValue
    }

    /// Writes `level` into the global gate and into **every** destination's
    /// `FilterConfig` (atomically per destination), then notifies observers on
    /// the calling thread. A destination added afterward inherits the level via
    /// `addDestination`.
    public func setGlobalLevel(_ level: Logger.Level) {
        let observers: [(Logger.Level) -> Void]
        let changed: Bool

        levelLock.lock()
        changed = globalLevelValue != level
        globalLevelValue = level
        observers = levelObservers
        levelLock.unlock()

        for destination in snapshot() {
            var config = destination.filterConfig()
            config.minimumLevel = level
            destination.setFilterConfig(config)
        }

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
        return globalLevelValue
    }

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

        // A destination added after a `setGlobalLevel` call inherits the level.
        var config = destination.filterConfig()
        config.minimumLevel = globalLevel()
        destination.setFilterConfig(config)
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
        // tearDown runs drain+close on the destination's own serial queue, so
        // every prior `receive` is flushed (FIFO) before the close — this is the
        // "drain before teardown" the plan calls for, satisfied by queue order.
        removed.tearDown(completion: completion)
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

    func hasForceIncludedCategories() -> Bool {
        snapshot().contains {
            !$0.filterConfig().forceInclude.isEmpty
        }
    }

    func forceIncludes(_ category: LogCategory) -> Bool {
        snapshot().contains {
            $0.filterConfig().forceInclude.contains(category)
        }
    }
}
