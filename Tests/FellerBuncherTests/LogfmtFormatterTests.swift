import Dispatch
import Foundation
import Logging
import Logfmt
import Testing

@testable import FellerBuncher

private let fixedDate = Date(timeIntervalSince1970: 1_782_565_496.789)

@Test
func stableLeadingFieldOrder() {
    let record = LogRecord(
        timestamp: fixedDate,
        level: .warning,
        label: "network",
        category: "sync",
        message: "connected",
        metadata: ["attempt": 2]
    )

    let line = LogfmtFormatter().format(record)
    let thread = record.thread == .main ? "[UI]" : "[BG]"

    #expect(
        line
            == "ts=2026-06-27T13:04:56.789Z level=warning label=network category=sync \(thread) msg=connected attempt=2"
    )
}

@Test
func logfmtEscapingAndSanitization() {
    let record = LogRecord(
        level: .info,
        label: "test",
        message: "hello\r\n\u{0000}world",
        metadata: [
            "plain": "two words",
            "quote": "say \"hello\"",
            "nested": ["value": "a\nb"],
            "array": ["c\rd", "e\u{001F}f"],
        ]
    )
    let formatter = LogfmtFormatter(fields: [.message, .metadata])

    #expect(
        formatter.format(record)
            == "msg=helloworld array.0=cd array.1=ef nested.value=ab plain=\"two words\" quote=\"say \\\"hello\\\"\""
    )
}

@Test
@MainActor
func mainThreadIsCapturedBeforeBackgroundFormatting() async {
    let record = LogRecord(level: .info, label: "test")

    let line = await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(
                returning: LogfmtFormatter(fields: [.thread]).format(record)
            )
        }
    }

    #expect(line == "[UI]")
}

private final class Identifier: CustomLogfmtStringConvertible {
    let value: String

    init(_ value: String) {
        self.value = value
    }

    var loggingDescription: String { value }
}

private struct ContextError: Error {
    func loggingContext() -> [String: Any?] {
        [
            "id": Identifier("id-12"),
            "missing": nil,
            "underlying_errors": [
                ["code": 12, "reason": "bad\ninput"],
                ["code": 13, "reason": "offline"],
            ],
        ]
    }
}

@Test
func publicMetadataEntryMatchesDirectRenderer() {
    let context = ContextError().loggingContext()
    let record = LogRecord(
        level: .error,
        label: "test",
        metadata: context
    )
    let sanitizedDirect: [String: Any] = [
        "id": "id-12",
        "missing": Optional<String>.none as Any,
        "underlying_errors": [
            ["code": 12, "reason": "badinput"],
            ["code": 13, "reason": "offline"],
        ],
    ]

    #expect(record.metadataFragment == String.logfmt(sanitizedDirect))
}

@Test
func configsRenderSameRecordDifferently() {
    let record = LogRecord(
        timestamp: fixedDate,
        level: .error,
        label: "database",
        category: "database.connect",
        metadata: ["retry": true]
    )
    let generic = LogfmtFormatter(fields: [.level, .category, .metadata])
    let muse = LogfmtFormatter(
        timestampStyle: .utcSpaceSeparated,
        levelStyle: .paddedUppercase,
        categoryStyle: .bareBodyToken,
        fields: [.timestamp, .thread, .level, .category, .metadata]
    )
    let thread = record.thread == .main ? "[UI]" : "[BG]"

    #expect(generic.format(record) == "level=error category=database.connect retry=true")
    #expect(
        muse.format(record)
            == "2026-06-27 13:04:56.789Z \(thread) ERROR    database.connect retry=true"
    )
}

@Test
func customTimestampIsExactly24Characters() {
    let record = LogRecord(timestamp: fixedDate, level: .info, label: "test")
    let line = LogfmtFormatter(
        timestampStyle: .utcSpaceSeparated,
        fields: [.timestamp]
    ).format(record)
    let timestamp = line

    #expect(timestamp == "2026-06-27 13:04:56.789Z")
    #expect(timestamp.count == 24)
}

@Test(
    arguments: [
        0.000,
        0.050,
        0.700,
        0.999,
        1.000,
    ]
)
func iso8601WireFormatMatchesLegacyFormatter(fraction: TimeInterval) {
    let date = Date(timeIntervalSince1970: 1_782_565_496 + fraction)
    let record = LogRecord(timestamp: date, level: .info, label: "test")
    let line = LogfmtFormatter(fields: [.timestamp]).format(record)
    let actual = String(line.dropFirst("ts=".count))
    let legacy = ISO8601DateFormatter()
    legacy.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    legacy.timeZone = TimeZone(secondsFromGMT: 0)

    #expect(actual == legacy.string(from: date))
    #expect(actual.suffix(5).first == ".")
}

@Test
func timestampFormattingBenchmarkWorkload() {
    let clock = ContinuousClock()
    let valueStyleDuration = clock.measure {
        for _ in 0..<10_000 {
            _ = LogfmtFormatter.formatTimestamp(fixedDate, style: .iso8601)
        }
    }
    let legacy = ISO8601DateFormatter()
    legacy.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    legacy.timeZone = TimeZone(secondsFromGMT: 0)
    let legacyDuration = clock.measure {
        for _ in 0..<10_000 {
            _ = legacy.string(from: fixedDate)
        }
    }

    print("ISO8601FormatStyle: \(valueStyleDuration); cached formatter: \(legacyDuration)")
}
