import Foundation

public final class DestinationRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var destinations: [any LogDestination]

    public init(destinations: [any LogDestination] = []) {
        self.destinations = destinations
    }

    public func addDestination(_ destination: any LogDestination) {
        let identifier = ObjectIdentifier(destination)
        lock.lock()
        defer { lock.unlock() }
        guard !destinations.contains(where: { ObjectIdentifier($0) == identifier }) else {
            return
        }
        destinations.append(destination)
    }

    public func removeDestination(
        _ destination: any LogDestination,
        completion: @escaping @Sendable () -> Void = {}
    ) {
        let identifier = ObjectIdentifier(destination)
        let removed: (any LogDestination)?

        lock.lock()
        if let index = destinations.firstIndex(
            where: { ObjectIdentifier($0) == identifier }
        ) {
            removed = destinations.remove(at: index)
        } else {
            removed = nil
        }
        lock.unlock()

        guard let removed else {
            completion()
            return
        }
        removed.tearDown(completion: completion)
    }

    public func snapshot() -> [any LogDestination] {
        lock.lock()
        defer { lock.unlock() }
        return destinations
    }

    public func fanOut(_ record: LogRecord) {
        let destinations = snapshot()
        for destination in destinations where destination.shouldLog(record) {
            destination.receive(record)
        }
    }

    func hasForceIncludedCategories() -> Bool {
        snapshot().contains {
            !$0.filterConfig().forceInclude.isEmpty
        }
    }

    func forceIncludes(_ category: LogCategory) -> Bool {
        snapshot().contains {
            $0.filterConfig().forceInclude.contains(category)
        }
    }
}
