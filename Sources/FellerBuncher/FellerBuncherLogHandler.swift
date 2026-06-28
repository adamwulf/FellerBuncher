import Foundation
import Logging

enum FellerBuncherBridge {
    static let categoryKey = "__fellerbuncher_category"
    static let metadataFragmentKey = "__fellerbuncher_metadata"
}

public struct FellerBuncherLogHandler: LogHandler {
    public var metadataProvider: Logger.MetadataProvider?
    public var metadata: Logger.Metadata
    public var logLevel: Logger.Level {
        get {
            registry.hasForceIncludedCategories()
                ? .trace
                : configuredLogLevel
        }
        set {
            configuredLogLevel = newValue
        }
    }

    public let label: String
    private let registry: DestinationRegistry
    private var configuredLogLevel: Logger.Level

    public init(
        label: String,
        registry: DestinationRegistry,
        minimumLevel: Logger.Level = .info,
        metadataProvider: Logger.MetadataProvider? = nil
    ) {
        self.label = label
        self.registry = registry
        self.configuredLogLevel = minimumLevel
        self.metadata = [:]
        self.metadataProvider = metadataProvider
    }

    public init(
        label: String,
        destinations: [any LogDestination],
        minimumLevel: Logger.Level = .info,
        metadataProvider: Logger.MetadataProvider? = nil
    ) {
        self.init(
            label: label,
            registry: DestinationRegistry(destinations: destinations),
            minimumLevel: minimumLevel,
            metadataProvider: metadataProvider
        )
    }

    public subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    public func log(event: LogEvent) {
        let bridgedCategory: LogCategory = (
            event.metadata?[FellerBuncherBridge.categoryKey]
        )
            .flatMap(Self.stringValue)
            .map { LogCategory(rawValue: $0) } ?? LogCategory.default
        guard event.level >= configuredLogLevel
            || registry.forceIncludes(bridgedCategory)
        else {
            return
        }

        var combinedMetadata = metadataProvider?.get() ?? [:]
        combinedMetadata.merge(metadata) { _, handlerValue in handlerValue }
        if let eventMetadata = event.metadata {
            combinedMetadata.merge(eventMetadata) { _, eventValue in eventValue }
        }
        let category = combinedMetadata
            .removeValue(forKey: FellerBuncherBridge.categoryKey)
            .flatMap(Self.stringValue)
            .map { LogCategory(rawValue: $0) } ?? .default
        let bridgedFragment = combinedMetadata
            .removeValue(forKey: FellerBuncherBridge.metadataFragmentKey)
            .flatMap(Self.stringValue) ?? ""
        var renderedMetadata = combinedMetadata.mapValues(Self.metadataValue)
        if let error = event.error {
            renderedMetadata["error"] = (error as NSError).localizedDescription
        }
        let nativeFragment = LogRecord.renderMetadata(renderedMetadata)
        let metadataFragment = [nativeFragment, bridgedFragment]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let message = event.message.description

        let record = LogRecord(
            level: event.level,
            label: label,
            category: category,
            message: message.isEmpty ? nil : message,
            metadataFragment: metadataFragment,
            file: event.file,
            function: event.function,
            line: event.line
        )

        registry.fanOut(record)
    }

    public static func format(
        _ record: LogRecord,
        formatter: LogfmtFormatter = .init()
    ) -> String {
        formatter.format(record)
    }

    private static func metadataValue(_ value: Logger.Metadata.Value) -> Any {
        switch value {
        case .string(let value):
            value
        case .stringConvertible(let value):
            value.description
        case .dictionary(let value):
            value.mapValues(metadataValue)
        case .array(let value):
            value.map(metadataValue)
        }
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
