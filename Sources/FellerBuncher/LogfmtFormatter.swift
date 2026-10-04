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
                let type = sourceType(fromFile: record.file)
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

    /// The `Type` of the source field: the file name without its directories
    /// or extension (`Sync/SyncService.swift` → `SyncService`). Plain string
    /// work, because `URL(fileURLWithPath:)` asks the file system whether the
    /// path is a directory, which cost about 30 µs per line.
    static func sourceType(fromFile file: String) -> Substring {
        var name = file[...]
        while name.count > 1, name.hasSuffix("/") {
            name = name.dropLast()
        }
        if let slash = name.lastIndex(of: "/"), slash != name.index(before: name.endIndex) {
            name = name[name.index(after: slash)...]
        }
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            name = name[..<dot]
        }
        return name
    }

    /// `yyyy-MM-dd HH:mm:ss.SSS` (or ISO 8601 with `T` and `Z`) in UTC,
    /// rounded to the nearest millisecond. Built from integer math in the
    /// common range; other dates use `Date.ISO8601FormatStyle`.
    static func formatTimestamp(_ date: Date, style: TimestampStyle) -> String {
        let milliseconds = (date.timeIntervalSinceReferenceDate * 1_000).rounded()
        guard milliseconds >= -millisecondsFrom1970ToReferenceDate,
            milliseconds < millisecondsFrom1970ToYear10000 - millisecondsFrom1970ToReferenceDate
        else {
            return formatTimestampWithFormatStyle(date, style: style)
        }
        return formatTimestamp(
            millisecondsSince1970: Int64(milliseconds) + Int64(millisecondsFrom1970ToReferenceDate),
            style: style
        )
    }

    private static let millisecondsFrom1970ToReferenceDate: Double = 978_307_200_000
    private static let millisecondsFrom1970ToYear10000: Double = 253_402_300_800_000

    /// Formats a non-negative UTC millisecond count below year 10000.
    private static func formatTimestamp(
        millisecondsSince1970: Int64,
        style: TimestampStyle
    ) -> String {
        let millisecond = Int(millisecondsSince1970 % 1_000)
        let seconds = millisecondsSince1970 / 1_000
        let secondOfDay = Int(seconds % 86_400)
        let (year, month, day) = civilDate(daysSince1970: Int(seconds / 86_400))
        let isISO8601 = style == .iso8601
        let length = isISO8601 ? 24 : 23

        return String(unsafeUninitializedCapacity: length) { buffer in
            func put(_ value: Int, digits: Int, at offset: Int) {
                var value = value
                for index in stride(from: offset + digits - 1, through: offset, by: -1) {
                    buffer[index] = UInt8(ascii: "0") + UInt8(value % 10)
                    value /= 10
                }
            }
            put(year, digits: 4, at: 0)
            buffer[4] = UInt8(ascii: "-")
            put(month, digits: 2, at: 5)
            buffer[7] = UInt8(ascii: "-")
            put(day, digits: 2, at: 8)
            buffer[10] = isISO8601 ? UInt8(ascii: "T") : UInt8(ascii: " ")
            put(secondOfDay / 3_600, digits: 2, at: 11)
            buffer[13] = UInt8(ascii: ":")
            put(secondOfDay / 60 % 60, digits: 2, at: 14)
            buffer[16] = UInt8(ascii: ":")
            put(secondOfDay % 60, digits: 2, at: 17)
            buffer[19] = UInt8(ascii: ".")
            put(millisecond, digits: 3, at: 20)
            if isISO8601 {
                buffer[23] = UInt8(ascii: "Z")
            }
            return length
        }
    }

    /// The proleptic Gregorian date `days` after 1970-01-01, for `days >= 0`
    /// (Howard Hinnant's `civil_from_days`).
    private static func civilDate(daysSince1970 days: Int) -> (year: Int, month: Int, day: Int) {
        let shifted = days + 719_468
        let era = shifted / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shiftedMonth = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
        let month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        return (year, month, day)
    }

    static func formatTimestampWithFormatStyle(_ date: Date, style: TimestampStyle) -> String {
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
            timeZone: .fellerBuncherUTC
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
