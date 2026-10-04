import Foundation
import Logging

public struct FilterConfig: Sendable, Equatable {
    public var minimumLevel: Logger.Level
    public var include: Set<LogCategory>
    public var exclude: Set<LogCategory>
    public var forceInclude: Set<LogCategory>
    /// When `true` (the default), `setGlobalLevel` and `addDestination`
    /// overwrite `minimumLevel` with the global level. When `false`, the
    /// destination keeps its own `minimumLevel`: for example, a specialty file
    /// that takes a few categories at `.trace` while the global level is `.info`.
    public var followsGlobalLevel: Bool

    public init(
        minimumLevel: Logger.Level = .info,
        include: Set<LogCategory> = [],
        exclude: Set<LogCategory> = [],
        forceInclude: Set<LogCategory> = [],
        followsGlobalLevel: Bool = true
    ) {
        self.minimumLevel = minimumLevel
        self.include = include
        self.exclude = exclude
        self.forceInclude = forceInclude
        self.followsGlobalLevel = followsGlobalLevel
    }

    public func shouldLog(_ record: LogRecord) -> Bool {
        if forceInclude.contains(record.category) {
            return true
        }
        guard record.level >= minimumLevel else {
            return false
        }
        guard include.isEmpty || include.contains(record.category) else {
            return false
        }
        return !exclude.contains(record.category)
    }

    /// The lowest level `shouldLog` accepts for `category`, or `nil` when it
    /// rejects the category at every level. A `nil` category stands for any
    /// category this config does not name. Mirrors `shouldLog`; the level gate
    /// is built from it.
    ///
    /// A config that follows the global level is gated at `globalLevel`, the
    /// level its `minimumLevel` is kept in sync with.
    func lowestAcceptedLevel(
        for category: LogCategory?,
        globalLevel: Logger.Level
    ) -> Logger.Level? {
        if let category, forceInclude.contains(category) {
            return .trace
        }
        if !include.isEmpty {
            guard let category, include.contains(category) else {
                return nil
            }
        }
        if let category, exclude.contains(category) {
            return nil
        }
        return followsGlobalLevel ? globalLevel : minimumLevel
    }
}

public protocol LogDestination: AnyObject, Sendable {
    func filterConfig() -> FilterConfig
    /// Replaces the filter config. The built-in destinations tell their
    /// registry, which rebuilds its level gate. A custom destination that
    /// changes its config after it is registered must call
    /// `DestinationRegistry.filterConfigDidChange()`.
    func setFilterConfig(_ config: FilterConfig)
    func shouldLog(_ record: LogRecord) -> Bool
    func receive(_ record: LogRecord)
    func tearDown(completion: @escaping @Sendable () -> Void)
    /// Flushes any buffered records, calling `completion` once the destination's
    /// pending work has drained. Non-blocking; safe from any thread.
    func drain(completion: @escaping @Sendable () -> Void)
}

extension LogDestination {
    /// In-memory destinations have nothing to flush; complete immediately.
    public func drain(completion: @escaping @Sendable () -> Void) {
        completion()
    }
}

/// Lets a registry hear about `setFilterConfig` calls that the app makes
/// directly on a registered destination, so its level gate stays current.
protocol FilterConfigObservable: AnyObject {
    /// Installs (or, with `nil`, removes) the observer stored under `key`.
    func setFilterConfigObserver(
        _ observer: (@Sendable () -> Void)?,
        for key: ObjectIdentifier
    )
}

final class LockedFilterConfig: @unchecked Sendable {
    private let lock = NSLock()
    private var config: FilterConfig
    private var observers: [ObjectIdentifier: @Sendable () -> Void] = [:]

    init(_ config: FilterConfig) {
        self.config = config
    }

    func get() -> FilterConfig {
        lock.lock()
        defer { lock.unlock() }
        return config
    }

    func set(_ config: FilterConfig) {
        lock.lock()
        self.config = config
        let observers = Array(self.observers.values)
        lock.unlock()
        // Outside the lock: an observer reads this config back.
        for observer in observers {
            observer()
        }
    }

    func setObserver(_ observer: (@Sendable () -> Void)?, for key: ObjectIdentifier) {
        lock.lock()
        observers[key] = observer
        lock.unlock()
    }
}
