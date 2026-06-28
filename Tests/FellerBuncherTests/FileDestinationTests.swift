import Dispatch
import Foundation
import Logging
import Testing

@testable import FellerBuncher

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("FellerBuncherTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true
    )
    return url
}

private func record(
    _ message: String,
    level: Logger.Level = .info
) -> LogRecord {
    LogRecord(
        timestamp: Date(timeIntervalSince1970: 1_782_565_496.789),
        level: level,
        label: "tests",
        message: message,
        file: "Tests/Worker.swift",
        function: "run()",
        line: 42
    )
}

private func tearDown(_ destination: FileDestination) {
    let completion = DispatchSemaphore(value: 0)
    destination.tearDown {
        completion.signal()
    }
    #expect(completion.wait(timeout: .now() + 2) == .success)
}

@Test
func handlerWritesLogEventsToFile() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = try FileDestination(
        logDirectory: directory,
        processName: "app",
        formatter: LogfmtFormatter(fields: [.message, .metadata]),
        rotationPolicy: .none,
        filterConfig: FilterConfig(minimumLevel: .debug)
    )
    var handler = FellerBuncherLogHandler(
        label: "integration",
        destinations: [destination],
        minimumLevel: .debug,
        metadataProvider: Logger.MetadataProvider {
            ["provided": "context"]
        }
    )
    handler.metadata["constant"] = "base"
    let error = NSError(
        domain: "tests",
        code: 12,
        userInfo: [NSLocalizedDescriptionKey: "bad\nthing"]
    )

    handler.log(
        event: LogEvent(
            level: .trace,
            message: "filtered",
            metadata: nil,
            source: nil,
            file: "Tests/Worker.swift",
            function: "run()",
            line: 41
        )
    )
    handler.log(
        event: LogEvent(
            level: .error,
            message: "failed",
            error: error,
            metadata: ["request": "abc"],
            source: nil,
            file: "Tests/Worker.swift",
            function: "run()",
            line: 42
        )
    )
    destination.drain()

    let contents = try String(contentsOf: destination.fileURL, encoding: .utf8)
    #expect(
        contents
            == "msg=failed constant=base error=badthing provided=context request=abc\n"
    )
    tearDown(destination)
}

@Test
func sizeRotationRollsBeforeWriteAndShiftsSiblings() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = try FileDestination(
        logDirectory: directory,
        processName: "app",
        formatter: LogfmtFormatter(fields: [.message]),
        rotationPolicy: .size(bytes: 35),
        rotatedFilesToKeep: 2
    )

    destination.receive(record("11111111111111111111"))
    destination.receive(record("22222222222222222222"))
    destination.receive(record("33333333333333333333"))
    destination.drain()

    let active = try String(contentsOf: destination.fileURL, encoding: .utf8)
    let first = try String(
        contentsOf: directory.appendingPathComponent("app-1.log"),
        encoding: .utf8
    )
    let second = try String(
        contentsOf: directory.appendingPathComponent("app-2.log"),
        encoding: .utf8
    )
    #expect(active == "msg=33333333333333333333\n")
    #expect(first == "msg=22222222222222222222\n")
    #expect(second == "msg=11111111111111111111\n")
    tearDown(destination)
}

private final class FailingMoveDestination: FileDestination, @unchecked Sendable {
    override func moveItem(at source: URL, to destination: URL) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}

@Test
func renameFailureTruncatesActiveFileInPlace() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = try FailingMoveDestination(
        logDirectory: directory,
        processName: "app",
        formatter: LogfmtFormatter(fields: [.message]),
        rotationPolicy: .size(bytes: 35),
        rotatedFilesToKeep: 2
    )

    destination.receive(record("11111111111111111111"))
    destination.receive(record("22222222222222222222"))
    destination.drain()

    let contents = try String(contentsOf: destination.fileURL, encoding: .utf8)
    let attributes = try FileManager.default.attributesOfItem(
        atPath: destination.fileURL.path
    )
    let size = try #require(attributes[.size] as? NSNumber)
    #expect(contents == "msg=22222222222222222222\n")
    #expect(size.uint64Value <= 35)
    tearDown(destination)
}

@Test
func startupPruningUsesAgeAndCountButNeverDeletesActiveFile() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileManager = FileManager.default
    let active = directory.appendingPathComponent("app.log")
    let first = directory.appendingPathComponent("app-1.log")
    let second = directory.appendingPathComponent("app-2.log")
    let ancient = directory.appendingPathComponent("other.log")
    #expect(fileManager.createFile(atPath: active.path, contents: Data("active".utf8)))
    #expect(fileManager.createFile(atPath: first.path, contents: Data("first".utf8)))
    #expect(fileManager.createFile(atPath: second.path, contents: Data("second".utf8)))
    #expect(fileManager.createFile(atPath: ancient.path, contents: Data("old".utf8)))
    let oldDate = Date(timeIntervalSinceNow: -3_600)
    try fileManager.setAttributes(
        [.modificationDate: oldDate],
        ofItemAtPath: active.path
    )
    try fileManager.setAttributes(
        [.modificationDate: oldDate],
        ofItemAtPath: ancient.path
    )

    let destination = try FileDestination(
        logDirectory: directory,
        processName: "app",
        rotationPolicy: .none,
        rotatedFilesToKeep: 1,
        retention: 60,
        pruneInterval: 3_600
    )
    destination.drain()

    #expect(fileManager.fileExists(atPath: active.path))
    #expect(fileManager.fileExists(atPath: first.path))
    #expect(!fileManager.fileExists(atPath: second.path))
    #expect(!fileManager.fileExists(atPath: ancient.path))
    tearDown(destination)
}

@Test
func bootstrapIsIdempotentAndFirstLogLands() throws {
    let firstDirectory = try makeTemporaryDirectory()
    let secondDirectory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: firstDirectory) }
    defer { try? FileManager.default.removeItem(at: secondDirectory) }

    let first = try bootstrap(
        processName: "bootstrap-app",
        logDir: firstDirectory,
        console: .none,
        minimumLevel: .debug,
        rotationPolicy: .none
    )
    let second = try bootstrap(
        processName: "ignored-app",
        logDir: secondDirectory,
        console: .none,
        minimumLevel: .critical,
        rotationPolicy: .none
    )
    let logger = Logger(label: "bootstrap-test")
    logger.info(
        "first",
        file: "Tests/AppDelegate.swift",
        function: "start()",
        line: 10
    )
    first.fileDestination.drain()

    #expect(first === second)
    let contents = try String(
        contentsOf: first.fileDestination.fileURL,
        encoding: .utf8
    )
    #expect(contents.contains("msg=first"))
    #expect(
        !FileManager.default.fileExists(
            atPath: secondDirectory.appendingPathComponent("ignored-app.log").path
        )
    )
}
