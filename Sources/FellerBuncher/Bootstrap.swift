import Foundation
import Logging

public final class LoggingHandle: Sendable {
    public let fileDestination: FileDestination
    public let memoryDestination: MemoryDestination?
    public let registry: DestinationRegistry

    init(
        fileDestination: FileDestination,
        memoryDestination: MemoryDestination?,
        registry: DestinationRegistry
    ) {
        self.fileDestination = fileDestination
        self.memoryDestination = memoryDestination
        self.registry = registry
    }

    public var destinations: [any LogDestination] {
        registry.snapshot()
    }
}

private final class BootstrapState: @unchecked Sendable {
    let lock = NSLock()
    var handle: LoggingHandle?
}

private let bootstrapState = BootstrapState()

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
    let registry = DestinationRegistry(destinations: destinations)

    let handle = LoggingHandle(
        fileDestination: fileDestination,
        memoryDestination: memoryDestination,
        registry: registry
    )
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
    bootstrapState.handle = handle
    return handle
}
