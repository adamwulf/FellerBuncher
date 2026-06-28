import Dispatch
import Foundation
import OSLog

public enum RotationPolicy: Sendable, Equatable {
    case none
    case size(bytes: UInt64)
}

public enum PruneDate: Sendable, Equatable {
    case contentModificationDate
    case creationDate
}

public class FileDestination: LogDestination, @unchecked Sendable {
    public static let maxFileBytes: UInt64 = 10 * 1_024 * 1_024
    public static let rotatedFilesToKeep = 5
    public static let pruneInterval: TimeInterval = 60 * 60
    public static let retention: TimeInterval = 7 * 24 * 60 * 60

    public let logDirectory: URL
    public let fileURL: URL
    public let formatter: LogfmtFormatter

    private let processName: String
    private let rotationPolicy: RotationPolicy
    private let retainedFileCount: Int
    private let retentionInterval: TimeInterval
    private let pruneIntervalValue: TimeInterval
    private let pruneDate: PruneDate
    private let queue: DispatchQueue
    private let filter: LockedFilterConfig
    private let degradationLogger: Logger

    // Every mutable property below is confined to `queue`.
    private var fileHandle: FileHandle?
    private var currentSize: UInt64
    private var lastPruneDate: Date?
    private var closed = false

    public init(
        logDirectory: URL,
        processName: String,
        formatter: LogfmtFormatter = .init(),
        rotationPolicy: RotationPolicy = .size(bytes: FileDestination.maxFileBytes),
        rotatedFilesToKeep: Int = FileDestination.rotatedFilesToKeep,
        retention: TimeInterval = FileDestination.retention,
        pruneInterval: TimeInterval = FileDestination.pruneInterval,
        pruneDate: PruneDate = .contentModificationDate,
        filterConfig: FilterConfig = .init()
    ) throws {
        let safeProcessName = Self.safeProcessName(processName)
        self.logDirectory = logDirectory
        self.fileURL = logDirectory.appendingPathComponent("\(safeProcessName).log")
        self.processName = safeProcessName
        self.formatter = formatter
        self.rotationPolicy = rotationPolicy
        self.retainedFileCount = max(0, rotatedFilesToKeep)
        self.retentionInterval = max(0, retention)
        self.pruneIntervalValue = max(0, pruneInterval)
        self.pruneDate = pruneDate
        self.queue = DispatchQueue(label: "FellerBuncher.FileDestination.\(safeProcessName)")
        self.filter = LockedFilterConfig(filterConfig)
        self.degradationLogger = Logger(
            subsystem: "FellerBuncher",
            category: "writer"
        )

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: logDirectory,
            withIntermediateDirectories: true
        )
        if !fileManager.fileExists(atPath: fileURL.path) {
            guard fileManager.createFile(atPath: fileURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }

        let handle = try FileHandle(forWritingTo: fileURL)
        self.currentSize = try handle.seekToEnd()
        self.fileHandle = handle

        queue.async { [self] in
            pruneIfNeeded(at: Date(), force: true)
        }
    }

    deinit {
        try? fileHandle?.close()
    }

    public func filterConfig() -> FilterConfig {
        filter.get()
    }

    public func setFilterConfig(_ config: FilterConfig) {
        filter.set(config)
    }

    public func shouldLog(_ record: LogRecord) -> Bool {
        filter.get().shouldLog(record)
    }

    public func receive(_ record: LogRecord) {
        queue.async { [self] in
            guard !closed else {
                return
            }
            let line = formatter.format(record) + "\n"
            guard let data = line.data(using: .utf8) else {
                return
            }
            rotateIfNeeded(forAdditionalBytes: UInt64(data.count))
            do {
                try fileHandle?.write(contentsOf: data)
                currentSize += UInt64(data.count)
            } catch {
                degradationLogger.error(
                    "write failed path=\(self.fileURL.path, privacy: .public) error=\(String(describing: error), privacy: .public)"
                )
            }
            pruneIfNeeded(at: Date(), force: false)
        }
    }

    public func tearDown(completion: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            if !closed {
                closed = true
                try? fileHandle?.synchronize()
                try? fileHandle?.close()
                fileHandle = nil
            }
            completion()
        }
    }

    /// A blocking barrier for tests and callers on a known-safe thread.
    public func drain() {
        queue.sync {
            try? fileHandle?.synchronize()
        }
    }

    /// The non-blocking production drain API.
    public func drain(completion: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            try? fileHandle?.synchronize()
            completion()
        }
    }

    public func drain() async {
        await withCheckedContinuation { continuation in
            drain {
                continuation.resume()
            }
        }
    }

    /// Overridable only to let filesystem implementations customize the move operation.
    func moveItem(at source: URL, to destination: URL) throws {
        try FileManager.default.moveItem(at: source, to: destination)
    }

    private func rotateIfNeeded(forAdditionalBytes additionalBytes: UInt64) {
        guard case .size(let maximumBytes) = rotationPolicy else {
            return
        }
        guard maximumBytes > 0, currentSize + additionalBytes > maximumBytes else {
            return
        }
        guard currentSize > 0 else {
            return
        }
        guard retainedFileCount > 0 else {
            reopenAndTruncateActiveFile()
            return
        }

        do {
            try fileHandle?.synchronize()
            try fileHandle?.close()
            fileHandle = nil
            try shiftRotatedFiles()
            try moveItem(at: fileURL, to: rotatedFileURL(index: 1))
            guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            fileHandle = try FileHandle(forWritingTo: fileURL)
            currentSize = 0
        } catch {
            degradationLogger.error(
                "rotation move failed path=\(self.fileURL.path, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            reopenAndTruncateActiveFile()
        }
    }

    private func shiftRotatedFiles() throws {
        guard retainedFileCount > 0 else {
            return
        }
        let fileManager = FileManager.default
        let oldest = rotatedFileURL(index: retainedFileCount)
        if fileManager.fileExists(atPath: oldest.path) {
            try fileManager.removeItem(at: oldest)
        }
        guard retainedFileCount > 1 else {
            return
        }
        for index in stride(from: retainedFileCount - 1, through: 1, by: -1) {
            let source = rotatedFileURL(index: index)
            guard fileManager.fileExists(atPath: source.path) else {
                continue
            }
            try moveItem(at: source, to: rotatedFileURL(index: index + 1))
        }
    }

    private func reopenAndTruncateActiveFile() {
        do {
            if fileHandle == nil {
                fileHandle = try FileHandle(forWritingTo: fileURL)
            }
            try fileHandle?.truncate(atOffset: 0)
            try fileHandle?.seek(toOffset: 0)
            currentSize = 0
        } catch {
            degradationLogger.error(
                "truncate fallback failed path=\(self.fileURL.path, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            fileHandle = nil
            currentSize = 0
        }
    }

    private func pruneIfNeeded(at now: Date, force: Bool) {
        if !force, let lastPruneDate,
            now.timeIntervalSince(lastPruneDate) < pruneIntervalValue
        {
            return
        }
        lastPruneDate = now

        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: logDirectory,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .contentModificationDateKey,
                .creationDateKey,
            ]
        ) else {
            return
        }

        let activePath = fileURL.standardizedFileURL.path
        for candidate in files {
            guard candidate.standardizedFileURL.path != activePath else {
                continue
            }
            guard candidate.pathExtension == "log" else {
                continue
            }
            let values = try? candidate.resourceValues(
                forKeys: [.isRegularFileKey, .contentModificationDateKey, .creationDateKey]
            )
            guard values?.isRegularFile == true else {
                continue
            }
            let date: Date?
            switch pruneDate {
            case .contentModificationDate:
                date = values?.contentModificationDate
            case .creationDate:
                date = values?.creationDate
            }
            if let date, now.timeIntervalSince(date) > retentionInterval {
                try? fileManager.removeItem(at: candidate)
            }
        }

        pruneExcessRotatedFiles()
    }

    private func pruneExcessRotatedFiles() {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: logDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        let prefix = "\(processName)-"
        let rotated = files
            .filter {
                $0.pathExtension == "log"
                    && $0.deletingPathExtension().lastPathComponent.hasPrefix(prefix)
            }
            .sorted {
                rotationIndex(for: $0) < rotationIndex(for: $1)
            }
        for candidate in rotated.dropFirst(retainedFileCount) {
            try? fileManager.removeItem(at: candidate)
        }
    }

    private func rotationIndex(for url: URL) -> Int {
        let name = url.deletingPathExtension().lastPathComponent
        return Int(name.dropFirst(processName.count + 1)) ?? .max
    }

    private func rotatedFileURL(index: Int) -> URL {
        logDirectory.appendingPathComponent("\(processName)-\(index).log")
    }

    private static func safeProcessName(_ processName: String) -> String {
        let candidate = URL(fileURLWithPath: processName).lastPathComponent
        return candidate.isEmpty ? "process" : candidate
    }
}
