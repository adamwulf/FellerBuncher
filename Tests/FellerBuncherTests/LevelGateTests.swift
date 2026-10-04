import Foundation
import Logging
import Testing

@testable import FellerBuncher

/// Counts how often the metadata renderer reads `description`, to prove a
/// dropped call never renders its metadata.
private final class RenderProbe: CustomStringConvertible, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var renders: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    var description: String {
        lock.lock()
        count += 1
        lock.unlock()
        return "probe"
    }
}

/// A custom destination (not one of the built-ins), like Muse's LogCapture.
private final class CustomDestination: LogDestination, @unchecked Sendable {
    private let lock = NSLock()
    private var config: FilterConfig
    private var received: [LogRecord] = []

    init(config: FilterConfig) {
        self.config = config
    }

    var records: [LogRecord] {
        lock.lock()
        defer { lock.unlock() }
        return received
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
        received.append(record)
        lock.unlock()
    }

    func tearDown(completion: @escaping @Sendable () -> Void) {
        completion()
    }
}

private let render: LogCategory = "render"
private let sync: LogCategory = "sync"
private let noisy: LogCategory = "noisy"

private func fixedTraceConfig(_ categories: Set<LogCategory>) -> FilterConfig {
    FilterConfig(minimumLevel: .trace, include: categories, followsGlobalLevel: false)
}

private func gateLogger(_ registry: DestinationRegistry) -> Logger {
    Logger(label: "gate-tests") { label in
        FellerBuncherLogHandler(label: label, registry: registry, minimumLevel: .info)
    }
}

// MARK: - Fixed-level destinations

@Test
func fixedLevelDestinationKeepsItsLevelAcrossSetGlobalLevelAndAdd() {
    let follower = MemoryDestination(capacity: 10, filterConfig: FilterConfig(minimumLevel: .info))
    let fixed = MemoryDestination(capacity: 10, filterConfig: fixedTraceConfig([render]))
    let registry = DestinationRegistry(destinations: [follower], globalLevel: .info)

    registry.addDestination(fixed)
    #expect(fixed.filterConfig().minimumLevel == .trace)

    registry.setGlobalLevel(.warning)
    #expect(follower.filterConfig().minimumLevel == .warning)
    #expect(fixed.filterConfig().minimumLevel == .trace)
    #expect(fixed.filterConfig().include == [render])
}

@Test
func followingCustomDestinationInheritsAndTracksGlobalLevel() {
    let registry = DestinationRegistry(globalLevel: .info)
    let capture = CustomDestination(config: FilterConfig(minimumLevel: .error))
    registry.addDestination(capture)
    #expect(capture.filterConfig().minimumLevel == .info)

    let logger = gateLogger(registry)
    registry.setGlobalLevel(.trace)
    logger.trace("captured")
    #expect(capture.records.map(\.message) == ["captured"])
}

// MARK: - The level gate

@Test
func gateUsesLowestLevelAmongDestinationsThatAcceptTheCategory() {
    let main = MemoryDestination(
        capacity: 10,
        filterConfig: FilterConfig(minimumLevel: .info, exclude: [noisy])
    )
    let snapshots = MemoryDestination(capacity: 10, filterConfig: fixedTraceConfig([render]))
    let registry = DestinationRegistry(destinations: [main, snapshots], globalLevel: .info)
    let gate = registry.gate

    #expect(gate.accepts(.trace, category: render))
    #expect(!gate.accepts(.debug, category: sync))
    #expect(gate.accepts(.info, category: sync))
    #expect(!gate.accepts(.critical, category: noisy))
    #expect(gate.lowestLevel() == .trace)

    registry.setGlobalLevel(.debug)
    #expect(gate.accepts(.debug, category: sync))
    #expect(!gate.accepts(.trace, category: sync))
}

@Test
func gateFollowsForceIncludeOnlyForTheForcedCategories() {
    let main = MemoryDestination(
        capacity: 10,
        filterConfig: FilterConfig(minimumLevel: .info, forceInclude: [render])
    )
    let registry = DestinationRegistry(destinations: [main], globalLevel: .info)

    #expect(registry.gate.accepts(.trace, category: render))
    #expect(!registry.gate.accepts(.debug, category: sync))
}

@Test
func gateIsRebuiltWhenDestinationsAreAddedAndRemoved() {
    let registry = DestinationRegistry(globalLevel: .info)
    #expect(registry.gate.lowestLevel() == nil)
    #expect(!registry.gate.accepts(.critical, category: sync))

    let snapshots = MemoryDestination(capacity: 10, filterConfig: fixedTraceConfig([render]))
    registry.addDestination(snapshots)
    #expect(registry.gate.accepts(.trace, category: render))
    #expect(!registry.gate.accepts(.critical, category: sync))

    registry.removeDestination(snapshots)
    #expect(!registry.gate.accepts(.trace, category: render))
}

@Test
func gateTracksDirectSetFilterConfigOnBuiltInDestinations() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("FellerBuncherGate-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = try FileDestination(
        logDirectory: directory,
        processName: "gate",
        rotationPolicy: .none
    )
    let memory = MemoryDestination(capacity: 10)
    let console = ConsoleDestination(mode: .stderr, subsystem: "FellerBuncherTests")
    let registry = DestinationRegistry(destinations: [file, memory, console], globalLevel: .info)

    for destination in [file, memory, console] as [any LogDestination] {
        let original = destination.filterConfig()
        destination.setFilterConfig(fixedTraceConfig([render]))
        #expect(registry.gate.accepts(.trace, category: render))
        destination.setFilterConfig(original)
        #expect(!registry.gate.accepts(.trace, category: render))
    }

    // A removed destination no longer reports to the registry.
    registry.removeDestination(memory)
    memory.setFilterConfig(fixedTraceConfig([render]))
    #expect(!registry.gate.accepts(.trace, category: render))
}

@Test
func customDestinationReportsConfigChangesThroughTheRegistry() {
    let custom = CustomDestination(config: FilterConfig(minimumLevel: .info))
    let registry = DestinationRegistry(destinations: [custom], globalLevel: .info)

    custom.setFilterConfig(fixedTraceConfig([render]))
    registry.filterConfigDidChange()

    #expect(registry.gate.accepts(.trace, category: render))
}

// MARK: - The gate runs before rendering

@Test
func droppedSugarCallNeverRendersItsMetadata() {
    let main = MemoryDestination(capacity: 10, filterConfig: FilterConfig(minimumLevel: .info))
    let snapshots = MemoryDestination(capacity: 10, filterConfig: fixedTraceConfig([render]))
    let registry = DestinationRegistry(destinations: [main, snapshots], globalLevel: .info)
    let logger = gateLogger(registry)
    let probe = RenderProbe()

    logger.custom(level: .trace, sync, metadata: ["probe": probe])
    logger.debug("plain", metadata: ["probe": probe])
    #expect(probe.renders == 0)

    logger.custom(level: .trace, render, metadata: ["probe": probe])
    #expect(probe.renders == 1)
    #expect(snapshots.snapshot().map(\.category) == [render])
    #expect(main.snapshot().isEmpty)
}

@Test
func handlerLogLevelIsTheLowestFloorAcrossCategories() {
    let main = MemoryDestination(capacity: 10, filterConfig: FilterConfig(minimumLevel: .info))
    let registry = DestinationRegistry(destinations: [main], globalLevel: .info)
    let logger = gateLogger(registry)
    #expect(logger.logLevel == .info)

    registry.addDestination(MemoryDestination(capacity: 10, filterConfig: fixedTraceConfig([render])))
    #expect(logger.logLevel == .trace)
}

@Test
func preConfigHandlerGateAcceptsEverythingThenFollowsTheLinkedRegistry() {
    let coordinator = PreConfigCoordinator(capacity: 10)
    let logger = Logger(label: "pre-config-gate") { label in
        PreConfigLogHandler(label: label, coordinator: coordinator)
    }
    let probe = RenderProbe()

    // Buffering: capture everything.
    logger.custom(level: .trace, sync, metadata: ["probe": probe])
    #expect(probe.renders == 1)
    #expect(coordinator.bufferedRecords().count == 1)

    let main = MemoryDestination(capacity: 10, filterConfig: FilterConfig(minimumLevel: .info))
    let snapshots = MemoryDestination(capacity: 10, filterConfig: fixedTraceConfig([render]))
    let registry = DestinationRegistry(
        destinations: [main, snapshots],
        globalLevel: .info,
        gate: coordinator.gate
    )
    coordinator.activate(registry: registry)

    #expect(logger.logLevel == .trace)
    logger.custom(level: .trace, sync, metadata: ["probe": probe])
    #expect(probe.renders == 1)
    logger.custom(level: .trace, render, metadata: ["probe": probe])
    #expect(probe.renders == 2)
    #expect(snapshots.snapshot().map(\.category) == [render])
}
