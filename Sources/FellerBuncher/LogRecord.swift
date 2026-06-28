import Foundation
import Logging
import Logfmt

public enum ThreadKind: Sendable, Hashable {
    case main
    case bg
}

/// An immutable event snapshot shared by value with every destination.
///
/// Metadata is pre-rendered to a single fragment; per-destination metadata-key
/// selection is intentionally unsupported. If a future destination needs it,
/// carry the structured `[String: Any?]` in a `Sendable` box rendered lazily.
public struct LogRecord: Sendable {
    public let timestamp: Date
    public let level: Logger.Level
    public let label: String
    public let category: LogCategory
    public let message: String?
    public let file: String
    public let function: String
    public let line: UInt
    public let thread: ThreadKind
    public let metadataFragment: String

    public init(
        timestamp: Date = Date(),
        level: Logger.Level,
        label: String,
        category: LogCategory = .default,
        message: String? = nil,
        metadata: [String: Any?] = [:],
        file: String = #fileID,
        function: String = #function,
        line: UInt = #line
    ) {
        self.init(
            timestamp: timestamp,
            level: level,
            label: label,
            category: category,
            message: message,
            metadataFragment: Self.renderMetadata(metadata),
            file: file,
            function: function,
            line: line
        )
    }

    init(
        timestamp: Date = Date(),
        level: Logger.Level,
        label: String,
        category: LogCategory = .default,
        message: String? = nil,
        metadataFragment: String,
        file: String,
        function: String,
        line: UInt
    ) {
        self.timestamp = timestamp
        self.level = level
        self.label = Self.sanitize(label)
        self.category = LogCategory(rawValue: Self.sanitize(category.rawValue))
        self.message = message.map(Self.sanitize)
        self.file = Self.sanitize(file)
        self.function = Self.sanitize(function)
        self.line = line
        self.thread = Thread.isMainThread ? .main : .bg
        self.metadataFragment = metadataFragment
    }

    static func renderMetadata(_ metadata: [String: Any?]) -> String {
        String.logfmt(Self.sanitizedMetadata(metadata))
    }

    private static func sanitizedMetadata(_ metadata: [String: Any?]) -> [String: Any] {
        Dictionary(
            metadata.map { key, value in
                (sanitize(key), sanitizedValue(value))
            },
            uniquingKeysWith: { _, replacement in replacement }
        )
    }

    private static func sanitizedValue(_ value: Any?) -> Any {
        guard let value else {
            return Optional<String>.none as Any
        }

        if let value = value as? String {
            return sanitize(value)
        }
        if let value = value as? [String: Any?] {
            return sanitizedMetadata(value)
        }
        if let value = value as? [String: Any] {
            return Dictionary(
                value.map { key, value in
                    (sanitize(key), sanitizedValue(value))
                },
                uniquingKeysWith: { _, replacement in replacement }
            )
        }
        if let value = value as? [Any?] {
            return value.map(sanitizedValue)
        }
        if let value = value as? CustomLogfmtStringConvertible {
            return sanitize(value.loggingDescription)
        }
        if let value = value as? CustomLogfmtDictionaryConvertible {
            return Dictionary(
                value.loggingDictionary.map { key, value in
                    (sanitize(key), sanitizedValue(value))
                },
                uniquingKeysWith: { _, replacement in replacement }
            )
        }
        if let value = value as? CustomStringConvertible {
            return sanitize(value.description)
        }
        if let value = value as? CustomDebugStringConvertible {
            return sanitize(value.debugDescription)
        }
        return sanitize(String(describing: value))
    }

    static func sanitize(_ value: String) -> String {
        String(
            value.unicodeScalars.filter {
                $0.properties.generalCategory != .control
            }
        )
    }
}
