import Dispatch
import Foundation

public final class MemoryDestination: LogDestination, @unchecked Sendable {
    public static let defaultCapacity = 5_000

    public let capacity: Int

    private let filter: LockedFilterConfig
    private let lock = NSLock()
    private var ring: [LogRecord?]
    private var head = 0
    private var count = 0
    private var callback: (@Sendable () -> Void)?
    private var dirty = false
    private var scheduled = false
    private var closed = false

    public init(
        capacity: Int = MemoryDestination.defaultCapacity,
        filterConfig: FilterConfig = .init(),
        onChange: (@Sendable () -> Void)? = nil
    ) {
        self.capacity = max(1, capacity)
        self.ring = Array(repeating: nil, count: max(1, capacity))
        self.filter = LockedFilterConfig(filterConfig)
        self.callback = onChange
    }

    public var onChange: (@Sendable () -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return callback
        }
        set {
            lock.lock()
            callback = newValue
            lock.unlock()
        }
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
        var shouldSchedule = false

        lock.lock()
        if !closed {
            let insertionIndex = (head + count) % capacity
            ring[insertionIndex] = record
            if count == capacity {
                head = (head + 1) % capacity
            } else {
                count += 1
            }
            dirty = true
            if !scheduled {
                scheduled = true
                shouldSchedule = true
            }
        }
        lock.unlock()

        if shouldSchedule {
            DispatchQueue.main.async { [self] in
                deliverChange()
            }
        }
    }

    public func snapshot() -> [LogRecord] {
        lock.lock()
        defer { lock.unlock() }
        return (0..<count).compactMap { offset in
            ring[(head + offset) % capacity]
        }
    }

    public func tearDown(completion: @escaping @Sendable () -> Void) {
        lock.lock()
        closed = true
        callback = nil
        dirty = false
        lock.unlock()
        completion()
    }

    private func deliverChange() {
        let callback: (@Sendable () -> Void)?

        lock.lock()
        scheduled = false
        if closed || !dirty {
            callback = nil
        } else {
            dirty = false
            callback = self.callback
        }
        lock.unlock()

        callback?()
    }
}
