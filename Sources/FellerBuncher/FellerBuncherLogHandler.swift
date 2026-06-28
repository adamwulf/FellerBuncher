import Foundation
import Logging

public struct FellerBuncherLogHandler: LogHandler {
    public var metadataProvider: Logger.MetadataProvider?
    public var metadata: Logger.Metadata
    public var logLevel: Logger.Level

    public let label: String
    private let destinations: [any LogDestination]

    public init(
        label: String,
        destinations: [any LogDestination],
        minimumLevel: Logger.Level = .info,
        metadataProvider: Logger.MetadataProvider? = nil
    ) {
        self.label = label
        self.destinations = destinations
        self.logLevel = minimumLevel
        self.metadata = [:]
        self.metadataProvider = metadataProvider
    }

    public subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    public func log(event: LogEvent) {
        guard event.level >= logLevel else {
            return
        }

        var combinedMetadata = metadataProvider?.get() ?? [:]
        combinedMetadata.merge(metadata) { _, handlerValue in handlerValue }
        if let eventMetadata = event.metadata {
            combinedMetadata.merge(eventMetadata) { _, eventValue in eventValue }
        }
        var renderedMetadata = combinedMetadata.mapValues(Self.metadataValue)
        if let error = event.error {
            renderedMetadata["error"] = (error as NSError).localizedDescription
        }

        let record = LogRecord(
            level: event.level,
            label: label,
            message: event.message.description,
            metadata: renderedMetadata,
            file: event.file,
            function: event.function,
            line: event.line
        )

        for destination in destinations where destination.shouldLog(record) {
            destination.receive(record)
        }
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
}
