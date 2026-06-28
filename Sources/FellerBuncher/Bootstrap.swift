import Foundation
import Logging

public final class LoggingHandle: Sendable {
    public let fileDestination: FileDestination
    public let destinations: [any LogDestination]

    init(
        fileDestination: FileDestination,
        destinations: [any LogDestination]
    ) {
        self.fileDestination = fileDestination
        self.destinations = destinations
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
    let destinations: [any LogDestination]
    if console != .none {
        destinations = [
            fileDestination,
            ConsoleDestination(
                mode: console,
                subsystem: processName,
                formatter: formatter,
                filterConfig: filterConfig
            ),
        ]
    } else {
        destinations = [fileDestination]
    }

    // MemoryDestination arrives in Phase 4; retain the argument for source compatibility.
    _ = inMemory

    let handle = LoggingHandle(
        fileDestination: fileDestination,
        destinations: destinations
    )
    LoggingSystem.bootstrap(
        { label, metadataProvider in
            FellerBuncherLogHandler(
                label: label,
                destinations: destinations,
                minimumLevel: minimumLevel,
                metadataProvider: metadataProvider
            )
        },
        metadataProvider: nil
    )
    bootstrapState.handle = handle
    return handle
}
