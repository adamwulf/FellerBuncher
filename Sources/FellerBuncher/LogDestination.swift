import Foundation
import Logging

public struct FilterConfig: Sendable, Equatable {
    public var minimumLevel: Logger.Level
    public var include: Set<LogCategory>
    public var exclude: Set<LogCategory>
    public var forceInclude: Set<LogCategory>

    public init(
        minimumLevel: Logger.Level = .info,
        include: Set<LogCategory> = [],
        exclude: Set<LogCategory> = [],
        forceInclude: Set<LogCategory> = []
    ) {
        self.minimumLevel = minimumLevel
        self.include = include
        self.exclude = exclude
        self.forceInclude = forceInclude
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
}

public protocol LogDestination: AnyObject, Sendable {
    func filterConfig() -> FilterConfig
    func setFilterConfig(_ config: FilterConfig)
    func shouldLog(_ record: LogRecord) -> Bool
    func receive(_ record: LogRecord)
    func tearDown(completion: @escaping @Sendable () -> Void)
}

final class LockedFilterConfig: @unchecked Sendable {
    private let lock = NSLock()
    private var config: FilterConfig

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
        lock.unlock()
    }
}
