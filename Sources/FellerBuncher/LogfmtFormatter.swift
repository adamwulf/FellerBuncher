import Foundation
import Logging
import Logfmt

public struct LogfmtFormatter: Sendable {
    public enum TimestampStyle: Sendable, Hashable {
        case iso8601
        case utcSpaceSeparated
    }

    public enum LevelStyle: Sendable, Hashable {
        case raw
        case uppercase
        case paddedUppercase
    }

    public enum CategoryStyle: Sendable, Hashable {
        case field
        case bareBodyToken
    }

    public enum Field: Sendable, Hashable {
        case timestamp
        case level
        case label
        case category
        case thread
        case source
        case message
        case metadata
    }

    public static let defaultFields: [Field] = [
        .timestamp,
        .thread,
        .level,
        .source,
        .label,
        .category,
        .message,
        .metadata,
    ]

    public let timestampStyle: TimestampStyle
    public let levelStyle: LevelStyle
    public let categoryStyle: CategoryStyle
    public let fields: [Field]

    public init(
        timestampStyle: TimestampStyle = .utcSpaceSeparated,
        levelStyle: LevelStyle = .uppercase,
        categoryStyle: CategoryStyle = .field,
        fields: [Field] = LogfmtFormatter.defaultFields
    ) {
        self.timestampStyle = timestampStyle
        self.levelStyle = levelStyle
        self.categoryStyle = categoryStyle
        self.fields = fields
    }

    public func format(_ record: LogRecord) -> String {
        Self.format(record, config: self)
    }

    public static func format(_ record: LogRecord, config: Self = .init()) -> String {
        var components: [String] = []
        components.reserveCapacity(config.fields.count)

        for field in config.fields {
            switch field {
            case .timestamp:
                let timestamp = formatTimestamp(
                    record.timestamp,
                    style: config.timestampStyle
                )
                switch config.timestampStyle {
                case .iso8601:
                    components.append("ts=\(timestamp)")
                case .utcSpaceSeparated:
                    components.append(timestamp)
                }
            case .level:
                let level = formatLevel(record.level, style: config.levelStyle)
                switch config.levelStyle {
                case .raw:
                    components.append("level=\(level)")
                case .uppercase, .paddedUppercase:
                    components.append(level)
                }
            case .label:
                components.append(String.logfmt(["label": record.label]))
            case .category:
                switch config.categoryStyle {
                case .field:
                    components.append(String.logfmt(["category": record.category.rawValue]))
                case .bareBodyToken where record.message?.isEmpty != false:
                    components.append(String.logfmt(record.category.rawValue))
                case .bareBodyToken:
                    break
                }
            case .thread:
                components.append(record.thread == .main ? "[UI]" : "[BG]")
            case .source:
                let type = URL(fileURLWithPath: record.file)
                    .deletingPathExtension()
                    .lastPathComponent
                components.append(
                    String.logfmt(
                        "\(type).\(record.function):\(record.line)"
                    )
                )
            case .message:
                if let message = record.message, !message.isEmpty {
                    components.append(String.logfmt(["msg": message]))
                }
            case .metadata:
                if !record.metadataFragment.isEmpty {
                    components.append(record.metadataFragment)
                }
            }
        }

        return components.joined(separator: " ")
    }

    static func formatTimestamp(_ date: Date, style: TimestampStyle) -> String {
        let roundedToMilliseconds = Date(
            timeIntervalSinceReferenceDate:
                (date.timeIntervalSinceReferenceDate * 1_000).rounded() / 1_000
                + 0.0005
        )
        let iso8601 = Date.ISO8601FormatStyle(
            dateSeparator: .dash,
            dateTimeSeparator: style == .iso8601 ? .standard : .space,
            timeSeparator: .colon,
            timeZoneSeparator: .omitted,
            includingFractionalSeconds: true,
            timeZone: .gmt
        )
        let formatted = iso8601.format(roundedToMilliseconds)
        if style == .utcSpaceSeparated {
            return String(formatted.dropLast())
        }
        return formatted
    }

    private static func formatLevel(_ level: Logger.Level, style: LevelStyle) -> String {
        switch style {
        case .raw:
            level.rawValue
        case .uppercase:
            level.rawValue.uppercased()
        case .paddedUppercase:
            level.rawValue.uppercased().padding(
                toLength: 8,
                withPad: " ",
                startingAt: 0
            )
        }
    }
}
