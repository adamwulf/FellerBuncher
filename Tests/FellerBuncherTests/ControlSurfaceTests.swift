import Dispatch
import Foundation
import Logging
import Testing

@testable import FellerBuncher

// MARK: - Helpers

private func makeControlTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("FellerBuncherPhase5-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true
    )
    return url
}

private func phase5Record(
    _ message: String,
    level: Logger.Level = .info,
    category: LogCategory = .default
) -> LogRecord {
    LogRecord(
        timestamp: Date(timeIntervalSince1970: 1_782_565_496.789),
        level: level,
        label: "phase5",
        category: category,
        message: message,
        file: "Tests/Phase5.swift",
        function: "run()",
        line: 1
    )
}

/// A thread-safe clock whose value the test advances explicitly, so a single
/// destination can observe a day boundary mid-lifetime.
private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) {
        self.current = start
    }

    func advance(to date: Date) {
        lock.lock()
        current = date
        lock.unlock()
    }

    var now: @Sendable () -> Date {
        { [self] in
            lock.lock()
            defer { lock.unlock() }
            return current
        }
    }
}

/// Captures the thread identity and call count for a level-change callback.
private final class LevelChangeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var levels: [Logger.Level] = []
    private(set) var threads: [Thread] = []

    func record(_ level: Logger.Level) {
        lock.lock()
        levels.append(level)
        threads.append(Thread.current)
        lock.unlock()
    }

    var snapshot: (levels: [Logger.Level], threads: [Thread]) {
        lock.lock()
        defer { lock.unlock() }
        return (levels, threads)
    }
}

private func drainFile(_ destination: FileDestination) {
    let done = DispatchSemaphore(value: 0)
    destination.drain {
        done.signal()
    }
    #expect(done.wait(timeout: .now() + 2) == .success)
}

// MARK: - Global level control

@Test
func setGlobalLevelFlipsEveryDestinationAndHandlerGate() throws {
    let directory = try makeControlTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let file = try FileDestination(
        logDirectory: directory,
        processName: "level-app",
        rotationPolicy: .none,
        filterConfig: FilterConfig(minimumLevel: .info)
    )
    let memory = MemoryDestination(
        capacity: 50,
        filterConfig: FilterConfig(minimumLevel: .info)
    )
    let registry = DestinationRegistry(
        destinations: [file, memory],
        globalLevel: .info
    )
    let handle = LoggingHandle(
        fileDestination: file,
        memoryDestination: memory,
        registry: registry
    )

    #expect(handle.effectiveLevel == .info)

    handle.setGlobalLevel(.debug)

    #expect(handle.effectiveLevel == .debug)
    #expect(file.filterConfig().minimumLevel == .debug)
    #expect(memory.filterConfig().minimumLevel == .debug)

    // The handler gate now admits .debug too.
    var handler = FellerBuncherLogHandler(
        label: "gate",
        registry: registry,
        minimumLevel: .info
    )
    #expect(handler.logLevel == .debug)
    handler.metadata = [:]

    let logger = Logger(label: "gate") { _ in handler }
    logger.debug("admitted")
    drainFile(file)

    #expect(memory.snapshot().map(\.message) == ["admitted"])
    let contents = try String(contentsOf: file.fileURL, encoding: .utf8)
    #expect(contents.contains("msg=admitted"))
}

@Test
func laterAddedDestinationInheritsGlobalLevel() {
    let registry = DestinationRegistry(globalLevel: .info)
    registry.setGlobalLevel(.warning)

    let memory = MemoryDestination(
        capacity: 10,
        filterConfig: FilterConfig(minimumLevel: .trace)
    )
    registry.addDestination(memory)

    #expect(memory.filterConfig().minimumLevel == .warning)
}

@Test
func onEffectiveLevelChangeFiresOnSetterThread() throws {
    let directory = try makeControlTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = try FileDestination(
        logDirectory: directory,
        processName: "observer-app",
        rotationPolicy: .none
    )
    let registry = DestinationRegistry(destinations: [file], globalLevel: .info)
    let handle = LoggingHandle(
        fileDestination: file,
        memoryDestination: nil,
        registry: registry
    )
    defer { tearDownFile(file) }

    let probe = LevelChangeProbe()
    handle.onEffectiveLevelChange = { level in
        probe.record(level)
    }

    let setterThreadIsCaller = Thread.current
    handle.setGlobalLevel(.error)

    let result = probe.snapshot
    #expect(result.levels == [.error])
    #expect(result.threads.first === setterThreadIsCaller)

    // Setting the same level again does not re-fire.
    handle.setGlobalLevel(.error)
    #expect(probe.snapshot.levels == [.error])
}

/// A TSan-ready race test for the Phase 5 global-level path: one thread flips
/// `setGlobalLevel(.debug)↔(.info)` while N threads fan out through a
/// destination whose `shouldLog` reads `filterConfig()`. No record may be judged
/// against a half-applied config. (Meaningful only under
/// `swift test --sanitize=thread`; a green normal run cannot prove the race
/// absent, but it must not deadlock or tear the level value.)
@Test
func setGlobalLevelDuringFanOutIsAtomic() {
    let memory = MemoryDestination(
        capacity: 1,
        filterConfig: FilterConfig(minimumLevel: .info)
    )
    let registry = DestinationRegistry(
        destinations: [memory],
        globalLevel: .info
    )
    let torn = LockedBool()
    let group = DispatchGroup()
    let queue = DispatchQueue(
        label: "FellerBuncherTests.global-level-race",
        attributes: .concurrent
    )

    group.enter()
    queue.async {
        for index in 0..<5_000 {
            registry.setGlobalLevel(index.isMultiple(of: 2) ? .debug : .info)
        }
        group.leave()
    }
    for _ in 0..<4 {
        group.enter()
        queue.async {
            for _ in 0..<5_000 {
                let level = memory.filterConfig().minimumLevel
                if level != .debug && level != .info {
                    torn.set()
                }
                registry.fanOut(phase5Record("racing", level: .debug))
            }
            group.leave()
        }
    }

    #expect(group.wait(timeout: .now() + 10) == .success)
    #expect(!torn.value)
}

private final class LockedBool: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set() {
        lock.lock()
        storage = true
        lock.unlock()
    }
}

// MARK: - preConfigLogs replay

@Test
func preConfigCaptureBuffersAndReplaysTaggedLate() {
    let coordinator = PreConfigCoordinator(capacity: 100)

    // Logs emitted before activation are buffered, not lost.
    coordinator.ingest(phase5Record("early-1"))
    coordinator.ingest(phase5Record("early-2"))
    #expect(coordinator.bufferedRecords().map(\.message) == ["early-1", "early-2"])

    let memory = MemoryDestination(
        capacity: 100,
        filterConfig: FilterConfig(minimumLevel: .trace)
    )
    let registry = DestinationRegistry(
        destinations: [memory],
        globalLevel: .trace
    )

    coordinator.activate(registry: registry)

    let replayed = memory.snapshot()
    #expect(replayed.map(\.message) == ["early-1", "early-2"])
    // Every replayed record is tagged late=true.
    #expect(replayed.allSatisfy { $0.metadataFragment.contains("late=true") })

    // Post-activation logs go straight through, untagged.
    coordinator.ingest(phase5Record("live"))
    let all = memory.snapshot()
    #expect(all.map(\.message) == ["early-1", "early-2", "live"])
    #expect(all.last?.metadataFragment.contains("late=true") == false)
}

@Test
func preConfigCaptureDropsOldestBeyondCapacity() {
    let coordinator = PreConfigCoordinator(capacity: 3)
    for index in 0..<6 {
        coordinator.ingest(phase5Record("\(index)"))
    }
    #expect(coordinator.bufferedRecords().map(\.message) == ["3", "4", "5"])
}

@Test
func preConfigReplayPreservesOriginalTimestampAndThread() throws {
    let coordinator = PreConfigCoordinator(capacity: 10)
    let original = phase5Record("buffered")
    coordinator.ingest(original)

    let memory = MemoryDestination(
        capacity: 10,
        filterConfig: FilterConfig(minimumLevel: .trace)
    )
    let registry = DestinationRegistry(destinations: [memory], globalLevel: .trace)
    coordinator.activate(registry: registry)

    let replayed = try #require(memory.snapshot().first)
    #expect(replayed.timestamp == original.timestamp)
    #expect(replayed.thread == original.thread)
}

// MARK: - .dateStamped rotation

@Test
func dateStampedFilenameEmbedsUTCDate() throws {
    let directory = try makeControlTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    // 2026-06-28 04:45 UTC (= 2026-06-27 23:45 CDT): the UTC day must win.
    let day1 = Date(timeIntervalSince1970: 1_782_621_952)
    let clock = MutableClock(day1)
    let destination = try FileDestination(
        logDirectory: directory,
        processName: "dated-app",
        rotationPolicy: .dateStamped(granularity: .day, zone: .gmt),
        filterConfig: FilterConfig(minimumLevel: .trace),
        now: clock.now
    )
    defer { tearDownFile(destination) }

    destination.receive(phase5Record("today"))
    drainFile(destination)

    let expected = directory.appendingPathComponent("dated-app-2026-06-28.log")
    #expect(FileManager.default.fileExists(atPath: expected.path))
    let contents = try String(contentsOf: expected, encoding: .utf8)
    #expect(contents.contains("msg=today"))
}

@Test
func dateStampedSwapsFileByFilenameDiffersOnDayBoundary() throws {
    let directory = try makeControlTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let day1 = Date(timeIntervalSince1970: 1_782_621_952) // 2026-06-28 UTC
    let day2 = day1.addingTimeInterval(24 * 60 * 60)       // 2026-06-29 UTC
    let clock = MutableClock(day1)
    let destination = try FileDestination(
        logDirectory: directory,
        processName: "roll-app",
        rotationPolicy: .dateStamped(granularity: .day, zone: .gmt),
        filterConfig: FilterConfig(minimumLevel: .trace),
        now: clock.now
    )
    defer { tearDownFile(destination) }

    destination.receive(phase5Record("before-midnight"))
    drainFile(destination)

    // Cross the day boundary; the next write opens the fresh dated file.
    clock.advance(to: day2)
    destination.receive(phase5Record("after-midnight"))
    drainFile(destination)

    let file1 = directory.appendingPathComponent("roll-app-2026-06-28.log")
    let file2 = directory.appendingPathComponent("roll-app-2026-06-29.log")
    let contents1 = try String(contentsOf: file1, encoding: .utf8)
    let contents2 = try String(contentsOf: file2, encoding: .utf8)
    #expect(contents1.contains("msg=before-midnight"))
    #expect(!contents1.contains("msg=after-midnight"))
    #expect(contents2.contains("msg=after-midnight"))
    #expect(!contents2.contains("msg=before-midnight"))
}

@Test
func rollIfDateChangedIsIdempotentAndPokeable() throws {
    let directory = try makeControlTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let day1 = Date(timeIntervalSince1970: 1_782_621_952) // 2026-06-28 UTC
    let day2 = day1.addingTimeInterval(24 * 60 * 60)       // 2026-06-29 UTC
    let clock = MutableClock(day1)
    let destination = try FileDestination(
        logDirectory: directory,
        processName: "poke-app",
        rotationPolicy: .dateStamped(granularity: .day, zone: .gmt),
        filterConfig: FilterConfig(minimumLevel: .trace),
        now: clock.now
    )
    defer { tearDownFile(destination) }

    destination.receive(phase5Record("day1"))
    drainFile(destination)

    // Poking with no date change is a no-op (no new file).
    destination.rollIfDateChanged()
    drainFile(destination)
    let day1File = directory.appendingPathComponent("poke-app-2026-06-28.log")
    let day2File = directory.appendingPathComponent("poke-app-2026-06-29.log")
    #expect(FileManager.default.fileExists(atPath: day1File.path))
    #expect(!FileManager.default.fileExists(atPath: day2File.path))

    // After advancing, poking rolls even with no intervening write.
    clock.advance(to: day2)
    destination.rollIfDateChanged()
    drainFile(destination)
    destination.receive(phase5Record("day2"))
    drainFile(destination)
    let contents2 = try String(contentsOf: day2File, encoding: .utf8)
    #expect(contents2.contains("msg=day2"))
}

@Test
func coldLaunchAfterDayBoundaryOpensNewDatedFile() throws {
    let directory = try makeControlTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let day1 = Date(timeIntervalSince1970: 1_782_621_952) // 2026-06-28 UTC
    let day2 = day1.addingTimeInterval(24 * 60 * 60)       // 2026-06-29 UTC

    // First launch: write to day1's file, then shut down (simulated process exit).
    let firstLaunch = try FileDestination(
        logDirectory: directory,
        processName: "cold-app",
        rotationPolicy: .dateStamped(granularity: .day, zone: .gmt),
        filterConfig: FilterConfig(minimumLevel: .trace),
        now: { day1 }
    )
    firstLaunch.receive(phase5Record("yesterday"))
    drainFile(firstLaunch)
    tearDownFile(firstLaunch)

    // Second launch the next day: must open the fresh dated file, never reopen
    // yesterday's, and lose nothing already written.
    let secondLaunch = try FileDestination(
        logDirectory: directory,
        processName: "cold-app",
        rotationPolicy: .dateStamped(granularity: .day, zone: .gmt),
        filterConfig: FilterConfig(minimumLevel: .trace),
        now: { day2 }
    )
    defer { tearDownFile(secondLaunch) }
    secondLaunch.receive(phase5Record("today"))
    drainFile(secondLaunch)

    let day1File = directory.appendingPathComponent("cold-app-2026-06-28.log")
    let day2File = directory.appendingPathComponent("cold-app-2026-06-29.log")
    let contents1 = try String(contentsOf: day1File, encoding: .utf8)
    let contents2 = try String(contentsOf: day2File, encoding: .utf8)
    #expect(contents1.contains("msg=yesterday"))
    #expect(!contents1.contains("msg=today"))
    #expect(contents2.contains("msg=today"))
}

// MARK: - Drain

@Test
func handleDrainFlushesEveryDestination() throws {
    let directory = try makeControlTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let file = try FileDestination(
        logDirectory: directory,
        processName: "drain-app",
        rotationPolicy: .none,
        filterConfig: FilterConfig(minimumLevel: .trace)
    )
    let memory = MemoryDestination(
        capacity: 10,
        filterConfig: FilterConfig(minimumLevel: .trace)
    )
    let registry = DestinationRegistry(destinations: [file, memory], globalLevel: .trace)
    let handle = LoggingHandle(
        fileDestination: file,
        memoryDestination: memory,
        registry: registry
    )

    registry.fanOut(phase5Record("flush-me"))
    handle.drain()

    let contents = try String(contentsOf: file.fileURL, encoding: .utf8)
    #expect(contents.contains("msg=flush-me"))
}

// MARK: - Test scaffolding

private func tearDownFile(_ destination: FileDestination) {
    let done = DispatchSemaphore(value: 0)
    destination.tearDown {
        done.signal()
    }
    #expect(done.wait(timeout: .now() + 2) == .success)
}
