import Foundation
import Logging

/// Shared, mutable coordinator behind every `PreConfigLogHandler` copy.
///
/// `Logger(label:)` binds its handler at construction, so logs emitted **before**
/// `bootstrap` would otherwise be lost. Installing a pre-config capture as the
/// single `LoggingSystem.bootstrap` makes those early loggers route here: while
/// buffering, records are held in a bounded drop-oldest ring; once `bootstrap`
/// runs it `activate`s this coordinator, switching to live fan-out and replaying
/// the buffer into the real destinations tagged `late=true`.
///
/// Because the coordinator is a reference shared by every handler copy (existing
/// and future), `LoggingSystem.bootstrap` is called **once** — the pre-config
/// install — and never again, avoiding swift-log's second-bootstrap crash.

/// The default number of pre-bootstrap records retained for replay.
public let defaultPreConfigBufferCapacity = 1_000

final class PreConfigCoordinator: @unchecked Sendable {
    static let defaultCapacity = defaultPreConfigBufferCapacity

    private let lock = NSLock()
    private let capacity: Int
    private var buffer: [LogRecord] = []
    private var registry: DestinationRegistry?

    init(capacity: Int = PreConfigCoordinator.defaultCapacity) {
        self.capacity = max(1, capacity)
        buffer.reserveCapacity(self.capacity)
    }

    /// Routes a built record: live fan-out once activated, otherwise buffered
    /// (drop-oldest at capacity).
    func ingest(_ record: LogRecord) {
        lock.lock()
        if let registry {
            lock.unlock()
            registry.fanOut(record)
            return
        }
        if buffer.count == capacity {
            buffer.removeFirst()
        }
        buffer.append(record)
        lock.unlock()
    }

    /// The effective gate for the pre-config handler: `.trace` while buffering
    /// (capture everything), the live global level once activated. Keeps the
    /// cheap handler-level gate alive for loggers created after bootstrap.
    func effectiveLevel() -> Logger.Level {
        lock.lock()
        let registry = self.registry
        lock.unlock()
        guard let registry else {
            return .trace
        }
        return registry.hasForceIncludedCategories()
            ? .trace
            : registry.globalLevel()
    }

    func forceIncludes(_ category: LogCategory) -> Bool {
        lock.lock()
        let registry = self.registry
        lock.unlock()
        return registry?.forceIncludes(category) ?? false
    }

    /// Switches to live mode and replays the buffered prefix into `registry`,
    /// each record tagged `late=true`. Idempotent: a second activation no-ops.
    func activate(registry: DestinationRegistry) {
        lock.lock()
        guard self.registry == nil else {
            lock.unlock()
            return
        }
        self.registry = registry
        let pending = buffer
        buffer.removeAll(keepingCapacity: false)
        lock.unlock()

        for record in pending {
            registry.fanOut(record.taggedLate())
        }
    }

    /// Test-only readback of the buffered records before activation.
    func bufferedRecords() -> [LogRecord] {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}

/// The `LogHandler` installed by `installPreConfigCapture`. A value type that
/// holds a reference to the shared coordinator, so every logger copy routes to
/// the same buffer/registry.
public struct PreConfigLogHandler: LogHandler {
    public var metadataProvider: Logger.MetadataProvider?
    public var metadata: Logger.Metadata = [:]
    public var logLevel: Logger.Level {
        get { coordinator.effectiveLevel() }
        // The global level is authoritative here. Unlike the live
        // FellerBuncherLogHandler (which loosens its gate with a per-logger
        // override via min(global, configured)), the pre-config path
        // intentionally ignores per-logger overrides — it is the transitional
        // bootstrap handler, gated only by the global level.
        set {}
    }

    public let label: String
    private let coordinator: PreConfigCoordinator

    init(
        label: String,
        coordinator: PreConfigCoordinator,
        metadataProvider: Logger.MetadataProvider? = nil
    ) {
        self.label = label
        self.coordinator = coordinator
        self.metadataProvider = metadataProvider
    }

    public subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    public func log(event: LogEvent) {
        // While buffering, the gate is `.trace` (capture everything). Once
        // activated it tracks the live global level, so post-bootstrap loggers
        // routed through this handler still get the cheap level gate.
        let bridgedCategory: LogCategory = (
            event.metadata?[FellerBuncherBridge.categoryKey]
        )
            .flatMap(Self.stringValue)
            .map { LogCategory(rawValue: $0) } ?? LogCategory.default
        guard event.level >= coordinator.effectiveLevel()
            || coordinator.forceIncludes(bridgedCategory)
        else {
            return
        }

        let record = FellerBuncherLogHandler.makeRecord(
            label: label,
            event: event,
            handlerMetadata: metadata,
            metadataProvider: metadataProvider
        )
        coordinator.ingest(record)
    }

    private static func stringValue(_ value: Logger.Metadata.Value) -> String? {
        switch value {
        case .string(let value):
            value
        case .stringConvertible(let value):
            value.description
        case .dictionary, .array:
            nil
        }
    }
}
