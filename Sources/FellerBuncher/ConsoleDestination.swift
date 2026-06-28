import Dispatch
import Foundation
import OSLog

public enum ConsoleMode: Sendable, Equatable {
    case osLog
    case stderr
    case none
}

public final class ConsoleDestination: LogDestination, @unchecked Sendable {
    public let mode: ConsoleMode
    public let formatter: LogfmtFormatter

    private let subsystem: String
    private let maximumCachedCategories: Int
    private let queue = DispatchQueue(label: "FellerBuncher.ConsoleDestination")
    private let filter: LockedFilterConfig
    private var loggers: [String: Logger] = [:]
    private var categoryRecency: [String] = []
    private var closed = false

    public init(
        mode: ConsoleMode,
        subsystem: String,
        formatter: LogfmtFormatter = .init(),
        filterConfig: FilterConfig = .init(),
        maximumCachedCategories: Int = 64
    ) {
        self.mode = mode
        self.subsystem = subsystem
        self.formatter = formatter
        self.filter = LockedFilterConfig(filterConfig)
        self.maximumCachedCategories = max(1, maximumCachedCategories)
    }

    public func filterConfig() -> FilterConfig {
        filter.get()
    }

    public func setFilterConfig(_ config: FilterConfig) {
        filter.set(config)
    }

    public func shouldLog(_ record: LogRecord) -> Bool {
        mode != .none && filter.get().shouldLog(record)
    }

    public func receive(_ record: LogRecord) {
        queue.async { [self] in
            guard !closed else {
                return
            }
            let line = formatter.format(record)
            switch mode {
            case .osLog:
                let logger = logger(for: record.category.rawValue)
                let level: OSLogType
                switch record.level {
                case .trace, .debug:
                    level = .debug
                case .info, .notice:
                    level = .info
                case .warning:
                    level = .default
                case .error:
                    level = .error
                case .critical:
                    level = .fault
                }
                logger.log(level: level, "\(line, privacy: .public)")
            case .stderr:
                if let data = (line + "\n").data(using: .utf8) {
                    try? FileHandle.standardError.write(contentsOf: data)
                }
            case .none:
                break
            }
        }
    }

    public func tearDown(completion: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            closed = true
            loggers.removeAll()
            categoryRecency.removeAll()
            completion()
        }
    }

    func drain() {
        queue.sync {}
    }

    var cachedCategoryCount: Int {
        queue.sync { loggers.count }
    }

    var cachedCategories: Set<String> {
        queue.sync { Set(loggers.keys) }
    }

    private func logger(for category: String) -> Logger {
        if let logger = loggers[category] {
            categoryRecency.removeAll { $0 == category }
            categoryRecency.append(category)
            return logger
        }

        if loggers.count == maximumCachedCategories,
            let leastRecent = categoryRecency.first
        {
            categoryRecency.removeFirst()
            loggers.removeValue(forKey: leastRecent)
        }
        let logger = Logger(subsystem: subsystem, category: category)
        loggers[category] = logger
        categoryRecency.append(category)
        return logger
    }
}
