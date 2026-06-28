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

    // Worker 0 flips the global level; workers 1...4 fan out and check that the
    // level they observe is always a fully-applied value. Dedicated threads, not
    // a shared concurrent queue, so this can't starve on a low-core CI runner.
    let completed = runConcurrently(workers: 5) { index in
        if index == 0 {
            for iteration in 0..<5_000 {
                registry.setGlobalLevel(iteration.isMultiple(of: 2) ? .debug : .info)
            }
        } else {
            for _ in 0..<5_000 {
                let level = memory.filterConfig().minimumLevel
                if level != .debug && level != .info {
                    torn.set()
                }
                registry.fanOut(phase5Record("racing", level: .debug))
            }
        }
    }

    #expect(completed)
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

/// A destination that pauses inside the FIRST `setFilterConfig` call until the
/// test releases it, so the test can deterministically force the problematic
/// interleaving: setter A parked mid-fan-out while setter B runs to completion.
private final class PausableConfigDestination: LogDestination, @unchecked Sendable {
    private let lock = NSLock()
    private var config: FilterConfig
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private var armed = true

    init(config: FilterConfig) {
        self.config = config
    }

    /// Blocks until the first `setFilterConfig` has entered (A is inside its
    /// fan-out under the atomic fix, or past the gate write under the bug).
    func waitUntilFirstSetterEntered() {
        entered.wait()
    }

    /// Lets the parked first setter finish writing.
    func releaseFirstSetter() {
        release.signal()
    }

    func filterConfig() -> FilterConfig {
        lock.lock()
        defer { lock.unlock() }
        return config
    }

    func setFilterConfig(_ config: FilterConfig) {
        lock.lock()
        let shouldPause = armed
        if armed { armed = false }
        lock.unlock()

        if shouldPause {
            entered.signal()
            release.wait()
        }

        lock.lock()
        self.config = config
        lock.unlock()
    }

    func shouldLog(_ record: LogRecord) -> Bool { filterConfig().shouldLog(record) }
    func receive(_ record: LogRecord) {}
    func tearDown(completion: @escaping @Sendable () -> Void) { completion() }
}

/// Concurrent setters must not leave a durable gate-vs-destination mismatch.
/// Deterministically forces: setter A (→ .debug) parked mid-fan-out, setter B
/// (→ .error) runs fully, then A resumes. Under a non-atomic setGlobalLevel A's
/// late config write leaves config=.debug while gate=.error — a durable
/// mismatch. Under the lock-held-across-fan-out fix, B blocks on levelLock until
/// A completes, so gate and config both end at the last committed level.
@Test
func concurrentSetGlobalLevelKeepsGateAndDestinationsConsistent() {
    let pausable = PausableConfigDestination(
        config: FilterConfig(minimumLevel: .info)
    )
    let registry = DestinationRegistry(
        destinations: [pausable],
        globalLevel: .info
    )
    let aDone = DispatchSemaphore(value: 0)
    let bDone = DispatchSemaphore(value: 0)

    // A and B run on dedicated threads so the deterministic interleaving the
    // main thread orchestrates below can't be defeated by GCD pool starvation on
    // a low-core CI runner.

    // A parks inside its fan-out (first setFilterConfig).
    let threadA = Thread {
        registry.setGlobalLevel(.debug)
        aDone.signal()
    }
    threadA.name = "FellerBuncherTests.det-setter-A"
    threadA.start()
    pausable.waitUntilFirstSetterEntered()

    // B runs while A is parked. Under the fix it blocks on levelLock until A
    // finishes; under the bug it completes now (gate=.error, config=.error).
    let threadB = Thread {
        registry.setGlobalLevel(.error)
        bDone.signal()
    }
    threadB.name = "FellerBuncherTests.det-setter-B"
    threadB.start()
    // Give B a beat to either complete (bug) or block on levelLock (fix).
    Thread.sleep(forTimeInterval: 0.05)

    // Release A; it finishes writing config=.debug.
    pausable.releaseFirstSetter()

    #expect(aDone.wait(timeout: .now() + 5) == .success)
    #expect(bDone.wait(timeout: .now() + 5) == .success)

    // Quiescent invariant: the gate and the destination config must agree.
    #expect(pausable.filterConfig().minimumLevel == registry.globalLevel())
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
func dateStampedFileURLReflectsActiveFileAfterRoll() throws {
    let directory = try makeControlTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let day1 = Date(timeIntervalSince1970: 1_782_621_952) // 2026-06-28 UTC
    let day2 = day1.addingTimeInterval(24 * 60 * 60)       // 2026-06-29 UTC
    let clock = MutableClock(day1)
    let destination = try FileDestination(
        logDirectory: directory,
        processName: "url-app",
        rotationPolicy: .dateStamped(granularity: .day, zone: .gmt),
        filterConfig: FilterConfig(minimumLevel: .trace),
        now: clock.now
    )
    defer { tearDownFile(destination) }

    // fileURL names the actually-open file, honoring the injected clock.
    #expect(destination.fileURL.lastPathComponent == "url-app-2026-06-28.log")

    clock.advance(to: day2)
    destination.rollIfDateChanged()
    drainFile(destination)
    #expect(destination.fileURL.lastPathComponent == "url-app-2026-06-29.log")
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

@Test
func removeDestinationDrainsRecordEnqueuedJustBeforeTeardown() throws {
    let directory = try makeControlTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let file = try FileDestination(
        logDirectory: directory,
        processName: "remove-drain-app",
        rotationPolicy: .none,
        filterConfig: FilterConfig(minimumLevel: .trace)
    )
    let registry = DestinationRegistry(destinations: [file], globalLevel: .trace)
    let handle = LoggingHandle(
        fileDestination: file,
        memoryDestination: nil,
        registry: registry
    )

    // Fan a record, then immediately remove: tearDown drains (FIFO on the
    // serial queue) before closing, so the record must reach disk.
    registry.fanOut(phase5Record("last-gasp"))
    let removed = DispatchSemaphore(value: 0)
    handle.removeDestination(file) {
        removed.signal()
    }
    #expect(removed.wait(timeout: .now() + 2) == .success)

    let contents = try String(contentsOf: file.fileURL, encoding: .utf8)
    #expect(contents.contains("msg=last-gasp"))
    #expect(registry.snapshot().isEmpty)
}

// MARK: - Test scaffolding

private func tearDownFile(_ destination: FileDestination) {
    let done = DispatchSemaphore(value: 0)
    destination.tearDown {
        done.signal()
    }
    #expect(done.wait(timeout: .now() + 2) == .success)
}
