# FellerBuncher

A small, reusable logging package for Swift apps built on
[swift-log](https://github.com/apple/swift-log) and
[Logfmt](https://github.com/adamwulf/Logfmt). One call wires up structured
[logfmt](https://brandur.org/logfmt) logging to a rotating, self-pruning file —
plus an OSLog console echo and an optional in-memory ring buffer — and hands you
back a control surface for runtime level changes and clean shutdown.

It is designed to **drop in alongside swift-log**: your code keeps using the
stock `Logger(label:)`. FellerBuncher only owns the bootstrap and the
destination fan-out, so there is no facade to learn and nothing to migrate away
from later.

- **Platforms:** iOS 16+, macOS 13+ (incl. Mac Catalyst), tvOS 16+, watchOS 9+
- **Concurrency:** Swift 6 language mode, full strict concurrency. The public
  surface is synchronous (no `async`/`await` required).

## Install

Add the package to your `Package.swift`:

```swift
.package(url: "https://github.com/adamwulf/FellerBuncher.git", branch: "main"),
```

…and depend on the `FellerBuncher` product from your app or composition-root
target:

```swift
.product(name: "FellerBuncher", package: "FellerBuncher"),
```

> **Dependency direction:** only the **app** (composition root) should depend on
> FellerBuncher and call `bootstrap`. Your **libraries** should depend on
> `swift-log` alone and emit plain `Logger(label:)` messages — the app installs
> the destinations that decide where those messages go.

## Quickstart

Call `bootstrap` once, as early as possible in app launch, **before** any logger
you intend to use is touched.

```swift
import FellerBuncher
import Logging

// 1. Pick a directory for the log files (the package stays path-agnostic).
let logDir = URL.documentsDirectory.appending(path: "Logs")

// 2. Bootstrap once. Sane defaults: OSLog console echo, .info level,
//    10 MB size-based rotation, keep 5 files, 7-day retention.
let logging = try bootstrap(processName: "MyApp", logDir: logDir)

// 3. Log from anywhere using the stock swift-log Logger.
let log = Logger(label: "com.myapp.startup")
log.info("app launched", metadata: ["version": Bundle.main.infoDictionary?["CFBundleShortVersionString"]])
```

### UIKit / Mac Catalyst

```swift
@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        do {
            _ = try bootstrap(
                processName: "MyApp",
                logDir: URL.documentsDirectory.appending(path: "Logs")
            )
        } catch {
            // The default OSLog console still works even if the file dir failed.
            print("logging bootstrap failed: \(error)")
        }
        return true
    }
}
```

### SwiftUI

```swift
@main
struct MyApp: App {
    init() {
        _ = try? bootstrap(
            processName: "MyApp",
            logDir: URL.documentsDirectory.appending(path: "Logs")
        )
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
```

> ⚠️ **Bootstrap order matters.** swift-log binds a `Logger(label:)` to its
> handler at *construction time*, not at log time. A logger created before
> `bootstrap` runs is stuck on the default handler forever. So: call `bootstrap`
> first, and make module-level loggers lazy (`static let`) so they aren't built
> until after launch. FellerBuncher also installs a [pre-config
> capture](#pre-config-capture-dont-lose-early-logs) buffer to catch logs from
> the gap, but the ordering discipline still gives the cleanest results.

## Convenience helpers

FellerBuncher adds additive `debug`/`info`/`warning`/`error` overloads to
`Logger` that take a plain `[String: Any?]` metadata bag and a first-class
**category**:

```swift
let log = Logger(label: "com.myapp.network")

log.info("request finished", metadata: ["status": 200, "ms": 142])
log.error("upload failed", metadata: ["url": url, "error": error])

// Categories route to destinations and become a wire-format field.
log.warning("retrying", metadata: ["attempt": 2])
```

Give your app one `String`-backed enum of categories and conform it once — then
the category travels with zero per-call mapping:

```swift
enum Category: String, LogCategoryConvertible {
    case network, database, ui
}

log.info(.network, "request finished", metadata: ["status": 200])
log.custom(level: .trace, .database, "query plan", metadata: ["rows": 42])
```

## The control surface

`bootstrap` returns a `LoggingHandle` — keep it around for runtime control.

```swift
// Flip the global level at runtime (backs an "Enable Debug Logging" toggle).
logging.setGlobalLevel(.debug)
let current = logging.effectiveLevel        // readback for a settings screen

logging.onEffectiveLevelChange = { level in
    // Fires on the calling thread; hop to main yourself if your UI needs it.
}

// Where is the file? (handy for a "share logs" feature your app builds.)
let activeFile = logging.fileDestination.fileURL

// Drain before shutdown. Three shapes — pick what fits the calling context.
await logging.drain()                       // async
logging.drain { /* done */ }                // callback (safe anywhere)
logging.drain()                             // blocking; test / known-safe-thread only
```

## Configuration

All `bootstrap` parameters have sane defaults; override only what you need:

```swift
let logging = try bootstrap(
    processName: "MyApp",
    logDir: logDir,
    console: .osLog,                         // .osLog (default) | .stderr | .none
    inMemory: true,                          // add a 5,000-record ring buffer
    minimumLevel: .info,
    rotationPolicy: .size(bytes: 10 * 1_024 * 1_024),  // or .dateStamped() / .none
    rotatedFilesToKeep: 5,
    retention: 7 * 24 * 60 * 60              // seconds
)
```

- **`console`** — `.osLog` echoes to the unified logging system (visible in
  Console.app and the Xcode console; emitted `privacy: .public` so it isn't
  redacted). Use `.stderr` for tools, `.none` to write only to file.
- **`rotationPolicy`** — `.size(bytes:)` rolls into numbered siblings
  (`MyApp.log → MyApp-1.log → …`); `.dateStamped()` writes a dated file per day
  and prunes purely by age; `.none` never rotates.
- **`inMemory: true`** exposes `logging.memoryDestination` with a `snapshot()`
  of recent records (for an in-app log viewer) and an `onChange` hook.

### Pre-config capture (don't lose early logs)

If code may log before `bootstrap` runs, install the capture buffer at the very
top of launch. Buffered records replay into the real destinations (tagged
`late=true`) once `bootstrap` runs:

```swift
installPreConfigCapture()   // optional; call before anything logs
// …later…
let logging = try bootstrap(processName: "MyApp", logDir: logDir)
```

Both `installPreConfigCapture()` and `bootstrap(...)` are idempotent — safe to
call from both an app and its extensions.

## What the package does and doesn't own

**Owns:** the `LoggingSystem` bootstrap, the logfmt `LogHandler`, the
serial-queue file writer (rotation + prune), the OSLog/stderr console
destination, the in-memory ring buffer, the runtime destination registry, and
the `Logger` convenience sugar.

**Leaves to your app:** the log directory, share/save UI, a log-viewer screen,
zip/export, and any custom destinations (e.g. a Sentry destination). Custom
destinations are first-class — conform to `LogDestination` and
`logging.addDestination(_:)` at runtime.

## License

See repository for license details.
