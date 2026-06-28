import Dispatch
import Foundation
import OSLog

/// The cadence at which a `.dateStamped` active file rolls to a fresh file.
public enum DateGranularity: Sendable, Equatable {
    case day
}

public enum RotationPolicy: Sendable, Equatable {
    case none
    case size(bytes: UInt64)
    /// The active filename embeds the date (`<name>-yyyy-MM-dd.log` for `.day`)
    /// in `zone` (default UTC). Rolls at the boundary by computed-filename-differs
    /// — no timer, no numbered siblings; pruning is purely age-based.
    case dateStamped(granularity: DateGranularity = .day, zone: TimeZone = .gmt)
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
    public let formatter: LogfmtFormatter

    /// The base name component (`<name>.log`). For `.dateStamped` the active file
    /// embeds the date instead; read `fileURL` for the live target.
    private let baseURL: URL

    private let processName: String
    private let rotationPolicy: RotationPolicy
    private let retainedFileCount: Int
    private let retentionInterval: TimeInterval
    private let pruneIntervalValue: TimeInterval
    private let pruneDate: PruneDate
    private let queue: DispatchQueue
    private let filter: LockedFilterConfig
    private let degradationLogger: Logger
    /// Injectable clock so tests can simulate a cold launch on a later day.
    private let now: @Sendable () -> Date

    // Every mutable property below is confined to `queue`.
    private var fileHandle: FileHandle?
    private var activeFileURL: URL
    private var currentSize: UInt64
    private var lastPruneDate: Date?
    private var closed = false

    /// The currently-targeted file. For `.size`/`.none` this is the fixed base
    /// file; for `.dateStamped` it is the dated file for the current date.
    public var fileURL: URL {
        switch rotationPolicy {
        case .none, .size:
            return baseURL
        case .dateStamped(let granularity, let zone):
            return Self.datedFileURL(
                logDirectory: logDirectory,
                processName: processName,
                date: Date(),
                granularity: granularity,
                zone: zone
            )
        }
    }

    public init(
        logDirectory: URL,
        processName: String,
        formatter: LogfmtFormatter = .init(),
        rotationPolicy: RotationPolicy = .size(bytes: FileDestination.maxFileBytes),
        rotatedFilesToKeep: Int = FileDestination.rotatedFilesToKeep,
        retention: TimeInterval = FileDestination.retention,
        pruneInterval: TimeInterval = FileDestination.pruneInterval,
        pruneDate: PruneDate = .contentModificationDate,
        filterConfig: FilterConfig = .init(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        let safeProcessName = Self.safeProcessName(processName)
        self.logDirectory = logDirectory
        self.baseURL = logDirectory.appendingPathComponent("\(safeProcessName).log")
        self.processName = safeProcessName
        self.formatter = formatter
        self.rotationPolicy = rotationPolicy
        self.retainedFileCount = max(0, rotatedFilesToKeep)
        self.retentionInterval = max(0, retention)
        self.pruneIntervalValue = max(0, pruneInterval)
        self.pruneDate = pruneDate
        self.queue = DispatchQueue(label: "FellerBuncher.FileDestination.\(safeProcessName)")
        self.filter = LockedFilterConfig(filterConfig)
        self.now = now
        self.degradationLogger = Logger(
            subsystem: "FellerBuncher",
            category: "writer"
        )

        // Resolve the initial active file: a cold launch the day after the last
        // write opens the fresh dated file, never reopening yesterday's.
        let initialURL: URL
        switch rotationPolicy {
        case .none, .size:
            initialURL = baseURL
        case .dateStamped(let granularity, let zone):
            initialURL = Self.datedFileURL(
                logDirectory: logDirectory,
                processName: safeProcessName,
                date: now(),
                granularity: granularity,
                zone: zone
            )
        }
        self.activeFileURL = initialURL

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: logDirectory,
            withIntermediateDirectories: true
        )
        if !fileManager.fileExists(atPath: initialURL.path) {
            guard fileManager.createFile(atPath: initialURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }

        let handle = try FileHandle(forWritingTo: initialURL)
        self.currentSize = try handle.seekToEnd()
        self.fileHandle = handle

        queue.async { [self] in
            pruneIfNeeded(at: self.now(), force: true)
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
            // Date rotation is by computed-filename-differs, checked cheaply on
            // every write so the first write after midnight opens the new file.
            rollIfDateChangedLocked(now: now())
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
                    "write failed path=\(self.activeFileURL.path, privacy: .public) error=\(String(describing: error), privacy: .public)"
                )
            }
            pruneIfNeeded(at: now(), force: false)
        }
    }

    /// An idempotent date-roll the app may poke on any cadence (no package
    /// timer). A no-op unless the computed filename for `now` differs from the
    /// currently-open file. Runs on the serial queue, so it is ordered against
    /// writes and pruning.
    public func rollIfDateChanged() {
        queue.async { [self] in
            guard !closed else {
                return
            }
            rollIfDateChangedLocked(now: now())
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

    /// Rolls the active file to the dated file for `now` when the computed name
    /// differs from the open one. No-op for `.size`/`.none` and when the date is
    /// unchanged. Must run on `queue`.
    private func rollIfDateChangedLocked(now: Date) {
        guard case .dateStamped(let granularity, let zone) = rotationPolicy else {
            return
        }
        let target = Self.datedFileURL(
            logDirectory: logDirectory,
            processName: processName,
            date: now,
            granularity: granularity,
            zone: zone
        )
        guard target.standardizedFileURL != activeFileURL.standardizedFileURL else {
            return
        }

        try? fileHandle?.synchronize()
        try? fileHandle?.close()
        fileHandle = nil

        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: target.path) {
            guard fileManager.createFile(atPath: target.path, contents: nil) else {
                degradationLogger.error(
                    "date roll create failed path=\(target.path, privacy: .public)"
                )
                return
            }
        }
        do {
            let handle = try FileHandle(forWritingTo: target)
            currentSize = try handle.seekToEnd()
            fileHandle = handle
            activeFileURL = target
        } catch {
            degradationLogger.error(
                "date roll open failed path=\(target.path, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
        }
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
            try moveItem(at: activeFileURL, to: rotatedFileURL(index: 1))
            guard FileManager.default.createFile(atPath: activeFileURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            fileHandle = try FileHandle(forWritingTo: activeFileURL)
            currentSize = 0
        } catch {
            degradationLogger.error(
                "rotation move failed path=\(self.activeFileURL.path, privacy: .public) error=\(String(describing: error), privacy: .public)"
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
                fileHandle = try FileHandle(forWritingTo: activeFileURL)
            }
            try fileHandle?.truncate(atOffset: 0)
            try fileHandle?.seek(toOffset: 0)
            currentSize = 0
        } catch {
            degradationLogger.error(
                "truncate fallback failed path=\(self.activeFileURL.path, privacy: .public) error=\(String(describing: error), privacy: .public)"
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

        // The skip-active guard reads the queue-confined active file, so for
        // `.dateStamped` it recomputes today's name each sweep (never pruning
        // the file currently open).
        let activePath = activeFileURL.standardizedFileURL.path
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

        // `.dateStamped` has no numbered siblings; its pruning is purely
        // age-based above. `.size`/`.none` keep the numbered-sibling count cap.
        if case .dateStamped = rotationPolicy {
            return
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

    /// `<dir>/<name>-yyyy-MM-dd.log` for `date` in `zone` (`.day` granularity).
    /// Uses `Date.ISO8601FormatStyle` (a `Sendable` value type) to avoid the
    /// non-`Sendable` `DateFormatter` warning under complete concurrency.
    static func datedFileURL(
        logDirectory: URL,
        processName: String,
        date: Date,
        granularity: DateGranularity,
        zone: TimeZone
    ) -> URL {
        let stamp = dateStamp(for: date, granularity: granularity, zone: zone)
        return logDirectory.appendingPathComponent("\(processName)-\(stamp).log")
    }

    static func dateStamp(
        for date: Date,
        granularity: DateGranularity,
        zone: TimeZone
    ) -> String {
        switch granularity {
        case .day:
            let style = Date.ISO8601FormatStyle(
                dateSeparator: .dash,
                timeZone: zone
            ).year().month().day()
            return style.format(date)
        }
    }
}
