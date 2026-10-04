import Foundation
import Logging
import Testing

@testable import FellerBuncher

/// A seeded generator (SplitMix64), so the sampled dates are the same on
/// every run.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

// MARK: - Formatting stays byte-identical

@Test
func museGoldenLineIsUnchanged() {
    let record = LogRecord(
        timestamp: Date(timeIntervalSince1970: 1_791_080_000.123),
        level: .info,
        label: "Sync",
        category: "sync_network",
        metadataFragment: LogRecord.renderMetadata([
            "count": 2,
            "nested": ["records": 12],
            "reason": nil,
            "status": "two words",
            "workspace_id": "deadbeef",
        ]),
        file: "Sync/SyncService.swift",
        function: "tick(reason:)",
        line: 42,
        thread: .main
    )
    let formatter = LogfmtFormatter(
        timestampStyle: .utcSpaceSeparated,
        levelStyle: .uppercase,
        categoryStyle: .bareBodyToken,
        fields: [.timestamp, .thread, .level, .source, .category, .message, .metadata]
    )

    #expect(
        formatter.format(record)
            == "2026-10-04 02:13:20.123 [UI] INFO SyncService.tick(reason:):42 sync_network count=2 nested.records=12 reason=[none] status=\"two words\" workspace_id=deadbeef"
    )
}

@Test
func integerTimestampMatchesFormatStyleTimestamp() {
    var dates: [Date] = [
        Date(timeIntervalSince1970: 0),
        Date(timeIntervalSince1970: 0.0004),
        Date(timeIntervalSince1970: 951_782_399.9996),   // 2000-02-28 23:59:59.9996
        Date(timeIntervalSince1970: 951_868_799.999),    // 2000-02-29 23:59:59.999
        Date(timeIntervalSince1970: 1_709_251_199.9995), // 2024-02-29 23:59:59.9995
        Date(timeIntervalSince1970: 1_798_761_599.9999), // 2026-12-31 23:59:59.9999
        Date(timeIntervalSince1970: 4_107_542_400),      // 2100-03-01
        Date(timeIntervalSince1970: 253_402_300_799.999), // 9999-12-31 23:59:59.999
        Date(timeIntervalSince1970: -1),                 // before 1970: fallback
        Date(timeIntervalSince1970: 253_402_300_800),    // year 10000: fallback
    ]
    var generator = SeededGenerator(seed: 0xFE11E7)
    for _ in 0..<20_000 {
        dates.append(
            Date(timeIntervalSince1970: Double.random(in: 0..<4_102_444_800, using: &generator))
        )
    }

    for date in dates {
        for style in [LogfmtFormatter.TimestampStyle.utcSpaceSeparated, .iso8601] {
            #expect(
                LogfmtFormatter.formatTimestamp(date, style: style)
                    == LogfmtFormatter.formatTimestampWithFormatStyle(date, style: style),
                "\(date.timeIntervalSince1970) \(style)"
            )
        }
    }
}

@Test(
    arguments: [
        "Sync/SyncService.swift",
        "SyncService.swift",
        "/Users/someone/Muse/Sync/SyncService.swift",
        "Module/Sub/Name.With.Dots.swift",
        "Module/NoExtension",
        "Module/Directory/",
    ]
)
func sourceTypeMatchesURLDerivation(file: String) {
    let expected = URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
    #expect(String(LogfmtFormatter.sourceType(fromFile: file)) == expected)
}

@Test
func sanitizeKeepsCleanStringsAndStripsEveryControlCharacter() {
    let clean = "plain é ü 日本 \u{00A0}nbsp \u{00BF} emoji 🎉"
    #expect(LogRecord.sanitize(clean) == clean)

    let dirty = "a\u{0000}b\u{001F}c\u{007F}d\u{0080}e\u{0085}f\u{009F}g\r\nh"
    #expect(LogRecord.sanitize(dirty) == "abcdefgh")
}

// MARK: - Date-roll boundary

@Test(arguments: ["UTC", "America/Chicago", "Asia/Kolkata", "America/Santiago"])
func datePeriodSpansExactlyTheDatesWithTheSameStamp(zoneIdentifier: String) throws {
    let zone = try #require(TimeZone(identifier: zoneIdentifier))
    // Includes the 2026 US DST changes (23- and 25-hour days in Chicago) and
    // Santiago's 2026-09-06, where DST starts at midnight (the day starts at
    // 01:00).
    let samples = [
        Date(timeIntervalSince1970: 1_791_080_000.123),
        Date(timeIntervalSince1970: 1_773_014_400),
        Date(timeIntervalSince1970: 1_793_516_400),
        Date(timeIntervalSince1970: 1_788_710_400),
    ]
    for date in samples {
        let period = FileDestination.datePeriod(containing: date, granularity: .day, zone: zone)
        let stamp = FileDestination.dateStamp(for: date, granularity: .day, zone: zone)
        func stampAt(_ date: Date) -> String {
            FileDestination.dateStamp(for: date, granularity: .day, zone: zone)
        }

        #expect(period.contains(date))
        #expect(stampAt(period.lowerBound) == stamp)
        #expect(stampAt(period.upperBound.addingTimeInterval(-0.001)) == stamp)
        #expect(stampAt(period.upperBound) != stamp)
        #expect(stampAt(period.lowerBound.addingTimeInterval(-0.001)) != stamp)
    }
}
