import Foundation
import Logging

/// The precomputed answer to "does any destination accept this level and
/// category?", checked before the sugar renders metadata.
///
/// `DestinationRegistry` rebuilds it when destinations, filter configs, or the
/// global level change, so the per-call check is one lock and one dictionary
/// lookup: no destination snapshot, no array copy.
final class LevelGate: @unchecked Sendable {
    private struct Table {
        /// The floor for a category that no destination names in its
        /// include/exclude/forceInclude sets; `nil` when nothing accepts it.
        var unlisted: Logger.Level?
        /// The floors for the named categories; a `nil` value means no
        /// destination accepts that category at any level.
        var listed: [LogCategory: Logger.Level?]
        /// The lowest floor over every category; backs the handlers' `logLevel`.
        var lowest: Logger.Level?

        static let acceptsEverything = Table(unlisted: .trace, listed: [:], lowest: .trace)
    }

    /// Guards `globalLevelValue` and `table`; held only to read or swap them.
    private let lock = NSLock()
    /// Serializes `rebuild`, so the last rebuild to finish reflects the latest
    /// configs. Separate from `lock` so readers never wait on a destination's
    /// `filterConfig()`.
    private let rebuildLock = NSLock()
    private var globalLevelValue: Logger.Level
    private var table: Table

    /// Accepts every level and category until the first `rebuild`, so the
    /// pre-config capture buffers everything before bootstrap.
    init(globalLevel: Logger.Level = .info) {
        self.globalLevelValue = globalLevel
        self.table = .acceptsEverything
    }

    func globalLevel() -> Logger.Level {
        lock.lock()
        defer { lock.unlock() }
        return globalLevelValue
    }

    /// `true` when at least one destination accepts `level` for `category`.
    func accepts(_ level: Logger.Level, category: LogCategory) -> Bool {
        let floor: Logger.Level?
        lock.lock()
        if let listedFloor = table.listed[category] {
            floor = listedFloor
        } else {
            floor = table.unlisted
        }
        lock.unlock()
        guard let floor else {
            return false
        }
        return level >= floor
    }

    /// The lowest level any destination accepts for any category, or `nil`
    /// when no destination accepts anything.
    func lowestLevel() -> Logger.Level? {
        lock.lock()
        defer { lock.unlock() }
        return table.lowest
    }

    /// Recomputes the floors from the filter configs of `destinations()`. A
    /// non-nil `newGlobalLevel` replaces the stored global level in the same
    /// swap.
    func rebuild(
        globalLevel newGlobalLevel: Logger.Level? = nil,
        destinations: () -> [any LogDestination]
    ) {
        rebuildLock.lock()
        defer { rebuildLock.unlock() }

        let globalLevel = newGlobalLevel ?? self.globalLevel()
        let table = Self.makeTable(
            configs: destinations().map { $0.filterConfig() },
            globalLevel: globalLevel
        )

        lock.lock()
        globalLevelValue = globalLevel
        self.table = table
        lock.unlock()
    }

    private static func makeTable(
        configs: [FilterConfig],
        globalLevel: Logger.Level
    ) -> Table {
        var named = Set<LogCategory>()
        for config in configs {
            named.formUnion(config.include)
            named.formUnion(config.exclude)
            named.formUnion(config.forceInclude)
        }

        let unlisted = lowest(
            configs.map { $0.lowestAcceptedLevel(for: nil, globalLevel: globalLevel) }
        )
        var listed: [LogCategory: Logger.Level?] = [:]
        for category in named {
            // `updateValue`, not subscript assignment: assigning `nil` through
            // the subscript would remove the key instead of storing "rejected".
            listed.updateValue(
                lowest(
                    configs.map {
                        $0.lowestAcceptedLevel(for: category, globalLevel: globalLevel)
                    }
                ),
                forKey: category
            )
        }
        let lowestOverall = lowest([unlisted] + Array(listed.values))
        return Table(unlisted: unlisted, listed: listed, lowest: lowestOverall)
    }

    private static func lowest(_ levels: [Logger.Level?]) -> Logger.Level? {
        levels.compactMap { $0 }.min()
    }
}
