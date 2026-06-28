import Foundation
import Logging
import Testing

@testable import FellerBuncher

private enum TestCategory: String, LogCategoryConvertible {
    case mcp
    case databaseConnect = "database.connect"
}

private final class RecordingDestination: LogDestination, @unchecked Sendable {
    private let lock = NSLock()
    private var config = FilterConfig(minimumLevel: .trace)
    private var storage: [LogRecord] = []

    var records: [LogRecord] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func filterConfig() -> FilterConfig {
        lock.lock()
        defer { lock.unlock() }
        return config
    }

    func setFilterConfig(_ config: FilterConfig) {
        lock.lock()
        self.config = config
        lock.unlock()
    }

    func shouldLog(_ record: LogRecord) -> Bool {
        filterConfig().shouldLog(record)
    }

    func receive(_ record: LogRecord) {
        lock.lock()
        storage.append(record)
        lock.unlock()
    }

    func tearDown(completion: @escaping @Sendable () -> Void) {
        completion()
    }
}

private func makeLogger(
    destination: RecordingDestination,
    minimumLevel: Logger.Level = .trace
) -> Logger {
    Logger(label: "extension-tests") { label in
        FellerBuncherLogHandler(
            label: label,
            destinations: [destination],
            minimumLevel: minimumLevel
        )
    }
}

@Test
func overloadShapesResolveAndPreserveMeaning() {
    let destination = RecordingDestination()
    let logger = makeLogger(destination: destination)

    logger.info("wrote", metadata: ["bytes": 12])
    logger.info(TestCategory.mcp, "started", metadata: ["port": 8_080])
    logger.info(TestCategory.mcp, "started")
    logger.info(TestCategory.mcp, metadata: ["state": "ready"])

    let records = destination.records
    #expect(records.count == 4)
    #expect(records[0].category == .default)
    #expect(records[0].message == "wrote")
    #expect(records[0].metadataFragment == "bytes=12")
    #expect(records[1].category.rawValue == "mcp")
    #expect(records[1].message == "started")
    #expect(records[1].metadataFragment == "port=8080")
    #expect(records[2].category.rawValue == "mcp")
    #expect(records[2].message == "started")
    #expect(records[2].metadataFragment.isEmpty)
    #expect(records[3].category.rawValue == "mcp")
    #expect(records[3].message == nil)
    #expect(records[3].metadataFragment == "state=ready")
}

@Test
func categoryOnlyUsesBareBodyTokenAndNeverTurnsMetadataIntoMessage() {
    let destination = RecordingDestination()
    let logger = makeLogger(destination: destination)
    logger.info(TestCategory.databaseConnect, metadata: ["foo": "bar"])
    let record = destination.records[0]
    let line = LogfmtFormatter(
        categoryStyle: .bareBodyToken,
        fields: [.category, .message, .metadata]
    ).format(record)

    #expect(line == "database.connect foo=bar")
    #expect(!line.contains("msg="))
}

@Test
func dynamicLevelAndLevelSpecificSugarProduceIdenticalBytes() {
    let destination = RecordingDestination()
    let logger = makeLogger(destination: destination)
    logger.info(TestCategory.mcp, "same", metadata: ["key": "value"])
    logger.custom(
        level: .info,
        TestCategory.mcp,
        "same",
        metadata: ["key": "value"]
    )
    logger.custom(level: .warning, TestCategory.mcp, "dynamic")
    let records = destination.records
    let formatter = LogfmtFormatter(
        fields: [.level, .category, .message, .metadata]
    )

    #expect(formatter.format(records[0]) == formatter.format(records[1]))
    #expect(records[2].level == .warning)
}

private func markEvaluated(_ flag: inout Bool) -> Logger.Message {
    flag = true
    return "expensive"
}

@Test
func droppedAutoclosureIsNotEvaluated() {
    let destination = RecordingDestination()
    let logger = makeLogger(destination: destination, minimumLevel: .warning)
    var evaluated = false

    logger.debug(
        markEvaluated(&evaluated),
        metadata: ["force-rich-overload": 1]
    )

    #expect(!evaluated)
    #expect(destination.records.isEmpty)
}

@Test
func categoryRawValueAndSourceLocationAreForwardedExactly() {
    let destination = RecordingDestination()
    let logger = makeLogger(destination: destination)

    logger.error(
        TestCategory.databaseConnect,
        "failed",
        file: "Example/Database.swift",
        function: "connect()",
        line: 91
    )

    let record = destination.records[0]
    #expect(record.category.rawValue == "database.connect")
    #expect(record.file == "Example/Database.swift")
    #expect(record.function == "connect()")
    #expect(record.line == 91)
}
