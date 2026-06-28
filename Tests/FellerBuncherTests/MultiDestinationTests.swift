import Dispatch
import Foundation
import Logging
import Testing

@testable import FellerBuncher

private final class CountingDestination: LogDestination, @unchecked Sendable {
    private let lock = NSLock()
    private var config: FilterConfig
    private var received: [LogRecord] = []
    private var isClosed = false

    init(config: FilterConfig = .init(minimumLevel: .trace)) {
        self.config = config
    }

    var records: [LogRecord] {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    var closed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isClosed
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
        if !isClosed {
            received.append(record)
        }
        lock.unlock()
    }

    func tearDown(completion: @escaping @Sendable () -> Void) {
        lock.lock()
        isClosed = true
        lock.unlock()
        completion()
    }
}

private final class LockedFlag: @unchecked Sendable {
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

private final class CallbackProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var count = 0
    private var ranOnMain = false

    func install(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func fire() {
        let continuation: CheckedContinuation<Void, Never>?
        lock.lock()
        count += 1
        ranOnMain = Thread.isMainThread
        continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }

    var result: (count: Int, ranOnMain: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (count, ranOnMain)
    }
}

private func phase4Record(
    _ message: String,
    level: Logger.Level = .info,
    category: LogCategory = .default
) -> LogRecord {
    LogRecord(
        level: level,
        label: "phase4",
        category: category,
        message: message,
        file: "Tests/Phase4.swift",
        function: "run()",
        line: 1
    )
}

@Test
func fanOutAppliesIncludeExcludeLevelAndForceInclude() {
    let filtered = CountingDestination(
        config: FilterConfig(
            minimumLevel: .warning,
            include: ["network"],
            exclude: ["blocked"],
            forceInclude: ["forced"]
        )
    )
    let all = CountingDestination()
    let registry = DestinationRegistry(destinations: [filtered, all])

    registry.fanOut(phase4Record("low", level: .info, category: "network"))
    registry.fanOut(phase4Record("included", level: .error, category: "network"))
    registry.fanOut(phase4Record("excluded", level: .error, category: "blocked"))
    registry.fanOut(phase4Record("forced", level: .debug, category: "forced"))

    #expect(filtered.records.map(\.message) == ["included", "forced"])
    #expect(all.records.count == 4)
}

@Test
func forceIncludePassesThroughTheSwiftLogHandlerGate() {
    let forced = MemoryDestination(
        capacity: 10,
        filterConfig: FilterConfig(
            minimumLevel: .info,
            forceInclude: ["mcp"]
        )
    )
    let registry = DestinationRegistry(destinations: [forced])
    let logger = Logger(label: "force-include") { label in
        FellerBuncherLogHandler(
            label: label,
            registry: registry,
            minimumLevel: .info
        )
    }

    logger.debug(LogCategory(rawValue: "mcp"), "forced")
    logger.debug("ordinary")

    #expect(forced.snapshot().map(\.message) == ["forced"])
}

@Test
func runtimeAddAndRemoveChangesSubsequentFanOut() {
    let destination = CountingDestination()
    let registry = DestinationRegistry()
    registry.addDestination(destination)
    registry.addDestination(destination)
    registry.fanOut(phase4Record("before"))
    let completion = DispatchSemaphore(value: 0)
    registry.removeDestination(destination) {
        completion.signal()
    }
    #expect(completion.wait(timeout: .now() + 2) == .success)
    registry.fanOut(phase4Record("after"))

    #expect(destination.records.map(\.message) == ["before"])
    #expect(destination.closed)
    #expect(registry.snapshot().isEmpty)
}

@Test
func filterConfigIsAlwaysReadAsOneAtomicValue() {
    let first = FilterConfig(
        minimumLevel: .debug,
        include: ["first"],
        exclude: ["second"],
        forceInclude: ["forced-first"]
    )
    let second = FilterConfig(
        minimumLevel: .info,
        include: ["second"],
        exclude: ["first"],
        forceInclude: ["forced-second"]
    )
    let destination = MemoryDestination(
        capacity: 1,
        filterConfig: first
    )
    let invalidRead = LockedFlag()

    // Worker 0 swaps the config; workers 1...4 read it. Each read must see one
    // whole config, never a torn mix of the two. Dedicated threads, not a shared
    // concurrent queue, so this can't starve on a low-core CI runner.
    let completed = runConcurrently(workers: 5) { index in
        if index == 0 {
            for iteration in 0..<5_000 {
                destination.setFilterConfig(iteration.isMultiple(of: 2) ? first : second)
            }
        } else {
            for _ in 0..<5_000 {
                let snapshot = destination.filterConfig()
                if snapshot != first && snapshot != second {
                    invalidRead.set()
                }
            }
        }
    }
    #expect(completed)
    #expect(!invalidRead.value)
}

@Test
func removalDuringWriteBurstDoesNotReopenClosedFile() throws {
    let directory = try makePhase4TemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let files = try (0..<8).map { index in
        try FileDestination(
            logDirectory: directory,
            processName: "race-\(index)",
            rotationPolicy: .none,
            filterConfig: FilterConfig(minimumLevel: .trace)
        )
    }
    let memory = MemoryDestination(
        capacity: 1_000,
        filterConfig: FilterConfig(minimumLevel: .trace)
    )
    let registry = DestinationRegistry(destinations: [files[0], memory])
    let removalTimedOut = LockedFlag()

    // Worker 0 bursts 500 records through the registry while worker 1 adds and
    // removes file destinations underneath it. Dedicated threads, not a shared
    // concurrent queue, so this can't starve on a low-core CI runner. The
    // per-removal semaphore stays: `removeDestination`'s completion runs on the
    // destination's own serial queue, which is never pool-starved.
    let completed = runConcurrently(workers: 2) { index in
        if index == 0 {
            for record in 0..<500 {
                registry.fanOut(phase4Record("\(record)"))
            }
        } else {
            for (fileIndex, file) in files.enumerated() {
                if fileIndex > 0 {
                    registry.addDestination(file)
                }
                let removal = DispatchSemaphore(value: 0)
                registry.removeDestination(file) {
                    removal.signal()
                }
                if removal.wait(timeout: .now() + 5) == .timedOut {
                    removalTimedOut.set()
                }
            }
        }
    }

    #expect(completed)
    #expect(!removalTimedOut.value)
    #expect(memory.snapshot().count == 500)
    for file in files {
        let sizeAfterClose = try fileSize(at: file.fileURL)
        file.receive(phase4Record("late"))
        file.drain()
        #expect(try fileSize(at: file.fileURL) == sizeAfterClose)
    }
}

@Test
@MainActor
func memoryRingCapsDropsOldestAndCoalescesOnMain() async {
    let probe = CallbackProbe()
    let memory = MemoryDestination(
        capacity: 5,
        filterConfig: FilterConfig(minimumLevel: .trace),
        onChange: {
            probe.fire()
        }
    )

    await withCheckedContinuation { continuation in
        probe.install(continuation)
        for index in 0..<10 {
            memory.receive(phase4Record("\(index)"))
        }
    }

    #expect(memory.snapshot().compactMap(\.message) == ["5", "6", "7", "8", "9"])
    #expect(probe.result.count == 1)
    #expect(probe.result.ranOnMain)
}

@Test
func osLogCacheReusesCategoriesAndStaysBounded() {
    let console = ConsoleDestination(
        mode: .osLog,
        subsystem: "FellerBuncherTests",
        formatter: LogfmtFormatter(fields: [.message]),
        filterConfig: FilterConfig(minimumLevel: .trace),
        maximumCachedCategories: 2
    )

    console.receive(phase4Record("one", category: "one"))
    console.receive(phase4Record("two", category: "two"))
    console.receive(phase4Record("one-again", category: "one"))
    console.receive(phase4Record("three", category: "three"))
    console.drain()

    #expect(console.cachedCategoryCount == 2)
    #expect(console.cachedCategories == ["one", "three"])
}

private func makePhase4TemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("FellerBuncherPhase4-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true
    )
    return url
}

private func fileSize(at url: URL) throws -> UInt64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let number = try #require(attributes[.size] as? NSNumber)
    return number.uint64Value
}
