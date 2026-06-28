import Logging

public extension Logger {
    @_disfavoredOverload
    func debug(
        _ message: @autoclosure () -> Logger.Message,
        metadata: [String: Any?] = [:],
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        fellerBuncherLog(
            level: .debug,
            message: message,
            metadata: metadata,
            file: file,
            function: function,
            line: line
        )
    }

    func debug<Category: LogCategoryConvertible>(
        _ category: Category,
        _ message: @autoclosure () -> Logger.Message? = nil,
        metadata: [String: Any?] = [:],
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        fellerBuncherLog(
            level: .debug,
            category: category,
            message: message,
            metadata: metadata,
            file: file,
            function: function,
            line: line
        )
    }

    @_disfavoredOverload
    func info(
        _ message: @autoclosure () -> Logger.Message,
        metadata: [String: Any?] = [:],
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        fellerBuncherLog(
            level: .info,
            message: message,
            metadata: metadata,
            file: file,
            function: function,
            line: line
        )
    }

    func info<Category: LogCategoryConvertible>(
        _ category: Category,
        _ message: @autoclosure () -> Logger.Message? = nil,
        metadata: [String: Any?] = [:],
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        fellerBuncherLog(
            level: .info,
            category: category,
            message: message,
            metadata: metadata,
            file: file,
            function: function,
            line: line
        )
    }

    @_disfavoredOverload
    func warning(
        _ message: @autoclosure () -> Logger.Message,
        metadata: [String: Any?] = [:],
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        fellerBuncherLog(
            level: .warning,
            message: message,
            metadata: metadata,
            file: file,
            function: function,
            line: line
        )
    }

    func warning<Category: LogCategoryConvertible>(
        _ category: Category,
        _ message: @autoclosure () -> Logger.Message? = nil,
        metadata: [String: Any?] = [:],
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        fellerBuncherLog(
            level: .warning,
            category: category,
            message: message,
            metadata: metadata,
            file: file,
            function: function,
            line: line
        )
    }

    @_disfavoredOverload
    func error(
        _ message: @autoclosure () -> Logger.Message,
        metadata: [String: Any?] = [:],
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        fellerBuncherLog(
            level: .error,
            message: message,
            metadata: metadata,
            file: file,
            function: function,
            line: line
        )
    }

    func error<Category: LogCategoryConvertible>(
        _ category: Category,
        _ message: @autoclosure () -> Logger.Message? = nil,
        metadata: [String: Any?] = [:],
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        fellerBuncherLog(
            level: .error,
            category: category,
            message: message,
            metadata: metadata,
            file: file,
            function: function,
            line: line
        )
    }

    func custom<Category: LogCategoryConvertible>(
        level: Logger.Level,
        _ category: Category,
        _ message: @autoclosure () -> Logger.Message? = nil,
        metadata: [String: Any?] = [:],
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        fellerBuncherLog(
            level: level,
            category: category,
            message: message,
            metadata: metadata,
            file: file,
            function: function,
            line: line
        )
    }
}

private extension Logger {
    func fellerBuncherLog(
        level: Logger.Level,
        message: () -> Logger.Message,
        metadata: [String: Any?],
        file: String,
        function: String,
        line: UInt
    ) {
        guard level >= logLevel else {
            return
        }
        emitFellerBuncherLog(
            level: level,
            category: nil,
            message: message(),
            metadata: metadata,
            file: file,
            function: function,
            line: line
        )
    }

    func fellerBuncherLog<Category: LogCategoryConvertible>(
        level: Logger.Level,
        category: Category,
        message: () -> Logger.Message?,
        metadata: [String: Any?],
        file: String,
        function: String,
        line: UInt
    ) {
        guard level >= logLevel else {
            return
        }
        emitFellerBuncherLog(
            level: level,
            category: LogCategory(category),
            message: message(),
            metadata: metadata,
            file: file,
            function: function,
            line: line
        )
    }

    func emitFellerBuncherLog(
        level: Logger.Level,
        category: LogCategory?,
        message: Logger.Message?,
        metadata: [String: Any?],
        file: String,
        function: String,
        line: UInt
    ) {
        var bridgeMetadata: Logger.Metadata = [:]
        if let category {
            bridgeMetadata[FellerBuncherBridge.categoryKey] = .string(category.rawValue)
        }
        let fragment = LogRecord.renderMetadata(metadata)
        if !fragment.isEmpty {
            bridgeMetadata[FellerBuncherBridge.metadataFragmentKey] = .string(fragment)
        }
        self.log(
            level: level,
            message ?? "",
            metadata: bridgeMetadata,
            file: file,
            function: function,
            line: line
        )
    }
}
