import Dispatch
import Foundation
import Testing

/// Runs `workers` closures truly concurrently on dedicated `Thread`s and waits
/// for all of them to finish, returning `true` if they completed within
/// `timeout`.
///
/// The race tests below deliberately stress the library's locks by having N
/// threads hammer it at once. They originally fanned the work out with
/// `DispatchQueue(attributes: .concurrent)` + `DispatchGroup.wait`, but a custom
/// concurrent queue draws from GCD's global pool, whose width is capped near the
/// core count. With Swift Testing running every `@Test` in parallel by default,
/// several such tests at once demand far more pool threads than a small CI runner
/// (4 vCPUs) can grant, so the queued work items never get a thread and the
/// `wait` times out — green locally on a many-core box, red in CI.
///
/// Dedicated `Thread`s sidestep that entirely: each worker owns a real thread
/// that the scheduler always runs, so the test exercises genuine concurrency
/// without depending on ambient core count or the global pool's width. The
/// `timeout` therefore only trips on an actual deadlock in the code under test —
/// which is exactly what these tests want to catch — never on scheduling
/// starvation. The library's production paths are all non-blocking async over
/// per-destination serial queues, so this models the concurrency the library
/// actually guarantees.
@discardableResult
func runConcurrently(
    workers: Int,
    timeout: TimeInterval = 30,
    _ body: @escaping @Sendable (_ index: Int) -> Void
) -> Bool {
    let group = DispatchGroup()
    for index in 0..<workers {
        group.enter()
        let thread = Thread {
            body(index)
            group.leave()
        }
        thread.name = "FellerBuncherTests.worker-\(index)"
        thread.start()
    }
    return group.wait(timeout: .now() + timeout) == .success
}
