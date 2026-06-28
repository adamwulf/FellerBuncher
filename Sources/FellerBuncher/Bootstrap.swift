import Foundation
import Logging

private final class BootstrapState: @unchecked Sendable {
    let lock = NSLock()
    var handle: LoggingHandle?
    var preConfigCoordinator: PreConfigCoordinator?
}

private let bootstrapState = BootstrapState()

/// Installs a lightweight buffering handler **before** `bootstrap`, so logs
/// emitted by `Logger(label:)`s created before bootstrap aren't lost. Records
/// are held in a bounded drop-oldest ring and replayed (tagged `late=true`) into
/// the real destinations once `bootstrap` runs.
///
/// This is the **single** `LoggingSystem.bootstrap` call: `bootstrap` later
/// activates the same coordinator rather than bootstrapping again (swift-log
/// crashes on a second bootstrap). Idempotent — a second install no-ops.
public func installPreConfigCapture(
    bufferCapacity: Int = defaultPreConfigBufferCapacity
) {
    bootstrapState.lock.lock()
    defer { bootstrapState.lock.unlock() }

    guard bootstrapState.preConfigCoordinator == nil,
        bootstrapState.handle == nil
    else {
        return
    }

    let coordinator = PreConfigCoordinator(capacity: bufferCapacity)
    bootstrapState.preConfigCoordinator = coordinator
    LoggingSystem.bootstrap(
        { label, metadataProvider in
            PreConfigLogHandler(
                label: label,
                coordinator: coordinator,
                metadataProvider: metadataProvider
            )
        },
        metadataProvider: nil
    )
}

@discardableResult
public func bootstrap(
    processName: String,
    logDir: URL,
    console: ConsoleMode = .osLog,
    inMemory: Bool = false,
    minimumLevel: Logger.Level = .info,
    formatter: LogfmtFormatter = .init(),
    rotationPolicy: RotationPolicy = .size(bytes: FileDestination.maxFileBytes),
    rotatedFilesToKeep: Int = FileDestination.rotatedFilesToKeep,
    retention: TimeInterval = FileDestination.retention
) throws -> LoggingHandle {
    bootstrapState.lock.lock()
    defer { bootstrapState.lock.unlock() }

    if let handle = bootstrapState.handle {
        return handle
    }

    let filterConfig = FilterConfig(minimumLevel: minimumLevel)
    let fileDestination = try FileDestination(
        logDirectory: logDir,
        processName: processName,
        formatter: formatter,
        rotationPolicy: rotationPolicy,
        rotatedFilesToKeep: rotatedFilesToKeep,
        retention: retention,
        filterConfig: filterConfig
    )
    let consoleDestination = console == .none
        ? nil
        : ConsoleDestination(
            mode: console,
            subsystem: Bundle.main.bundleIdentifier ?? processName,
            formatter: formatter,
            filterConfig: filterConfig
        )
    let memoryDestination = inMemory
        ? MemoryDestination(filterConfig: filterConfig)
        : nil
    let destinations: [any LogDestination]
    switch (consoleDestination, memoryDestination) {
    case let (.some(consoleDestination), .some(memoryDestination)):
        destinations = [fileDestination, consoleDestination, memoryDestination]
    case let (.some(consoleDestination), .none):
        destinations = [fileDestination, consoleDestination]
    case let (.none, .some(memoryDestination)):
        destinations = [fileDestination, memoryDestination]
    case (.none, .none):
        destinations = [fileDestination]
    }
    let registry = DestinationRegistry(
        destinations: destinations,
        globalLevel: minimumLevel
    )

    let handle = LoggingHandle(
        fileDestination: fileDestination,
        memoryDestination: memoryDestination,
        registry: registry
    )

    if let coordinator = bootstrapState.preConfigCoordinator {
        // Pre-config capture already owns the single LoggingSystem.bootstrap.
        // Switch it live and replay the buffered prefix tagged late=true; all
        // loggers (pre- and post-bootstrap) route through it to this registry.
        coordinator.activate(registry: registry)
    } else {
        LoggingSystem.bootstrap(
            { label, metadataProvider in
                FellerBuncherLogHandler(
                    label: label,
                    registry: registry,
                    minimumLevel: minimumLevel,
                    metadataProvider: metadataProvider
                )
            },
            metadataProvider: nil
        )
    }
    bootstrapState.handle = handle
    return handle
}
