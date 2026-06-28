# FellerBuncher — Implementation Plan

A reusable Swift logging package built on **swift-log** + **adamwulf/Logfmt**. It renders clean
logfmt lines and fans each event out to one or more destinations (rotating/pruned file, in-memory
ring buffer, console/OSLog), and drops into any Swift package or app in one call.

Status: **DESIGN** — this document is the target. Each phase below is independently buildable and
testable, layering toward the full design.

---

## Boundary (package vs. user)

- **Consumers use swift-log's `Logger` directly — no facade type.** The package owns only the
  one-call bootstrap, the `LogHandler`, and the destinations.
- **Logfmt is a private dependency** — used only inside the package, never re-exported, so it stays
  swappable.
- **Path-agnostic:** the log directory is always a caller-supplied parameter, never a hard-coded
  container (so tests inject a temp dir).
- **Dependency direction:** libraries depend on **swift-log only** and emit plain `Logger(label:)`;
  only the **app** (or a single composition root) depends on FellerBuncher and calls `bootstrap`.
  Library loggers route to whatever was bootstrapped — the fan-out under the app, swift-log's default
  stderr under `swift test`.

| Concern | Package | User |
| --- | --- | --- |
| logfmt formatting (per-destination config) | ✅ formatter | picks options |
| File writing, pluggable rotation, pruning | ✅ file destination | policy/retention |
| In-memory ring buffer + coalesced change hook | ✅ memory destination | sets callback |
| Console / OSLog mirroring | ✅ console destination | — |
| `LogDestination` protocol + runtime registry | ✅ | add/remove, custom destinations |
| `LogCategory` field + conformable category sugar | ✅ | conforms its enum |
| Category enum + its codegen | — | ✅ (app build phase) |
| Bootstrap + idempotency + preConfigLogs replay | ✅ | — |
| Global level override (`setGlobalLevel`/`effectiveLevel`) | ✅ | persists the toggle |
| Dynamic-level entry `custom(level:)` (closure path) | ✅ | calls it from its closure |
| Log directory path | — | ✅ (param) |
| Per-destination level / category include-exclude / force-include | ✅ mechanism | config |
| Rate-limit / coalescing | — (v1) | ✅ at the source |
| Anonymization | optional hook point only | ✅ call-site transform |
| Remote/error sinks (e.g. Sentry) | ✅ protocol generalizes | supplies the destination |
| Log zip | deferred | collects the dirs |
| Log viewer UI + share/save presentation | — | ✅ always app |

**Swift 6 / `-strict-concurrency=complete` from day one** — leading, not inheriting a 5.9 baseline.

---

## Concurrency contract

- **The public interface needs no async/await.** swift-log's `Logger`, `bootstrap`, and the sugar
  are all synchronous and fire-and-forget; a non-async call site uses the whole path without entering
  an `async` context.
- **The write path is fire-and-forget sync:** `write(line)` does `queue.async { performWrite }`; the
  caller never blocks. (Hence destinations are serial-queue classes, not actors — swift-log's `log()`
  is sync and cannot `await`.)
- **The only dual-API surface is `drain`** (export is deferred), in three shapes:
  1. **sync** `queue.sync {}` — a barrier; **test/known-safe-thread only.** `queue.sync` from main at
     shutdown can priority-invert, and **never** from an `async` context (blocks a pool thread).
  2. **callback** `drain(completion:)` = `queue.async { completion() }` — non-blocking, safe anywhere;
     the **source of truth** and the production shutdown/pre-export call.
  3. **async** `drain() async` = `withCheckedContinuation { c in drain { c.resume() } }`, derived from
     #2 so the two can't drift.

---

## Phases

### Phase 0 — Package skeleton
**Goal:** an empty package that builds green in CI.
- `Package.swift`: deps on **swift-log** + **adamwulf/Logfmt**; Swift 6 language mode /
  `-strict-concurrency=complete`. (Pin a swift-log ≥ 1.14 so `log(event:)` is available.)
- Empty `FellerBuncher` library target + `FellerBuncherTests` test target.
- **Test:** `swift build` and `swift test` succeed; CI green.

### Phase 1 — Pure formatting core (no I/O)
**Goal:** turn a log event into one logfmt line, configurably, with zero I/O — the foundation
everything else formats through.
- **`LogRecord`** — immutable `Sendable` value built **once per call, eagerly on the calling
  thread**, shared by value to every destination. Carries `timestamp`, `level`, `label`,
  `category: LogCategory`, `message`, source (`file/function/line`), `thread: ThreadKind`, and
  **metadata pre-rendered to a single sanitized logfmt fragment** (a `Sendable` string, **not** a
  `[String:String]` map).
  - `ThreadKind` (`.main`/`.bg`) is sampled via `Thread.isMainThread` **at construction** — by the
    time a destination's queue formats the record the thread identity is gone.
  - Sanitization (strip `\r\n` + control chars) happens **here, once**, while rendering the metadata
    fragment, so the `Any?` bag never crosses a `Sendable` boundary and destinations never re-sanitize.
  - **One metadata renderer:** `String.logfmt` over `[String: Any?]` (handles nils, nested
    dicts/arrays, `CustomLogfmtStringConvertible` typed values) — the *only* flattening path, so the
    sugar and the closure bridge can't drift.
  - **Forward-guard comment at the definition:** *metadata is pre-rendered to a single fragment;
    per-destination metadata-key selection is intentionally unsupported. If a future destination needs
    it, carry the structured `[String: Any?]` in a `Sendable` box rendered lazily.*
- **`LogCategory`** — a `Sendable`/`Hashable`/`ExpressibleByStringLiteral` `String` wrapper.
  Category-taking APIs accept **any `RawRepresentable<String>`** (`LogCategoryConvertible`) so an app
  conforms its generated enum and writes `log.info(.mcp, …)`; the package owns neither the enum nor
  its codegen. A `Logger`-only call gets a default category. Used three ways: destination routing key
  (set membership), an optional wire field, and the OSLog `category:`.
- **`LogfmtFormatter`** — a per-destination **config**, still a pure static `LogRecord -> String`
  function. Parameterized by:
  - **Timestamp style** — default `.utcSpaceSeparated`
    (`yyyy-MM-dd HH:mm:ss.SSS`, UTC); per-destination overridable with `.iso8601`.
  - **Level style** — `.raw` | `.uppercase` (default) | `.paddedUppercase`. All 7 levels stay
    distinct, **no collapsing**.
  - **Field selection + order** of `ts/level/label/category/thread/source/msg/metadata`. Source is
    captured and rendered by default. The default prefix is
    `yyyy-MM-dd HH:mm:ss.SSS [BG|UI] LEVEL Type.function():line`; `Type` is derived from the source
    filename. Leading fields are emitted **by hand** in a stable order (`String.logfmt` sorts keys
    alphabetically, so order can't rely on it); message + metadata are appended via the one renderer.
  - **Category render style:** `category=mcp` (generic default) | **bare leading body token** (`mcp`,
    Muse's shape). Bare token shares the **body slot** with the message: category leads the body
    (`… File.func:line mcp foo=bar`), a message if present leads instead. `msg=` is omitted when
    there's no message (never `msg=""`). (Muse's full field order: Phase 3 blockquote.)
    - **Render `category.rawValue` verbatim — NEVER the case name, `description`, or any
      re-derivation.** Muse rawValues are hand-authored and several contain DOTS or diverge from the
      case name (`.syncNetwork` → `sync_network`, `.databaseConnect` → `database.connect`). Since
      `LogCategory` wraps the rawValue String, printing the wrapped String is correct; a
      description/case-name would silently drift the dotted ones. (Test: a `LogCategory` from
      `"database.connect"` renders the bare token exactly `database.connect`.)
  - **Sanitization is non-optional, baked in** (not a toggle).
  - Default `ts` = **UTC with fractional seconds and no suffix**
    (`2026-06-27 12:34:56.789`) via **`Date.ISO8601FormatStyle`** (a `Sendable` value type — avoids
    the non-`Sendable` `ISO8601DateFormatter` warning under complete concurrency). The alternate
    `.iso8601` output must be **byte-identical** to `ISO8601DateFormatter`
    (`.withInternetDateTime` + `.withFractionalSeconds` + UTC `Z`) — locked by a regression test.
- **Tests (all pure, no temp dir):** stable leading-field order; escaping/quoting via `String.logfmt`;
  sanitization strips `\r\n`/control chars from message **and** every metadata value; a record built on
  **main** formats `[UI]` even when formatted later off a background queue; `Error.loggingContext()`
  (nested `underlying_errors` array-of-dicts + a nil + a `CustomLogfmtStringConvertible` id) renders
  identically through the public entry and through `String.logfmt` directly; two configs render the
  same record differently; the default timestamp is exactly 23 chars as the leading field.
  **Timestamp wire-format lock:** `ISO8601FormatStyle` byte-identical to `ISO8601DateFormatter` across
  ≥5 fractional cases (`.000`, `.050`, `.700`, `.999`, whole second) — proving always exactly 3
  fractional digits. **Timestamp perf benchmark:** 10k formats via `ISO8601FormatStyle` vs a cached
  `ISO8601DateFormatter`; if the value type is materially slower, fall back to `nonisolated(unsafe)
  static let ISO8601DateFormatter` (perf is the measured trigger).

### Phase 2 — File MVP
**Goal:** *log to a rotating, pruned file in one line.*
- **`LogDestination` protocol** (`AnyObject, Sendable`): `filterConfig()`/`setFilterConfig(_:)`
  (read/write the whole triple atomically), `shouldLog(_:)`, `receive(_:)` (cheap, enqueues),
  `tearDown(completion:)`. *(Filtering/teardown internals land in Phase 4; Phase 2 needs only the
  level gate.)*
- **`FileDestination`** — class, private serial `DispatchQueue`, `@unchecked Sendable` (state is
  queue-confined). Writes `logDir/<processName>.log`; holds its own `LogfmtFormatter`. Pluggable
  `RotationPolicy`:
  - `.size(bytes)` (this phase) — numbered siblings (`app.log → app-1.log`, shift up), checked
    **before** each write so overshoot is bounded to one record; **truncate-in-place fallback** on
    rename failure so the size bound always holds.
  - `.none`. `.dateStamped` arrives in Phase 5.
  - **Pruning** — per-directory (each process prunes its own dir at startup, off-main), age-based,
    **never the active file** (an unlinked-but-open file silently swallows writes → data loss). Prune
    date field configurable (`contentModificationDate` vs `creationDate`).
  - **Defaults** (constants): `maxFileBytes = 10MB`, `rotatedFilesToKeep = 5`, `pruneInterval = 1 hour`
    (don't `stat` the dir on every line). **Retention is a param** (`7d` default; real consumers differ).
- **`FellerBuncherLogHandler`** (swift-log `LogHandler`) — **cheap level-gate first**
  (`guard logLevel <= level` before any allocation, so calls stay inline in hot paths), then build the
  `LogRecord` once and fan out to each passing destination. Implement **`log(event:)`** (swift-log
  1.14+), folding the event's optional `error` into the metadata bag (its `localizedDescription` often
  has newlines → sanitized). Keep `format(...)` a pure static function.
- **`bootstrap(processName:logDir:, console:.osLog, inMemory:false, minimumLevel:.info)`** — builds
  destinations + registry, installs the handler via `LoggingSystem.bootstrap`. **Idempotent**
  (`NSLock`-guarded `Bool`). **Synchronous startup** — the dir/file is ready before it returns, so the
  first log lands. Returns a `LoggingHandle` (full surface in Phase 5).
- **Tests (inject a temp dir):** writes land in the file; `.size` rotation rolls at the threshold and
  shifts siblings; rename-failure → truncate-in-place keeps the size bound; pruning by count and age
  is per-directory and **never** removes the active file; bootstrap idempotency (second call no-ops).

### Phase 3 — Ergonomic helpers
**Goal:** the convenient call sites. Completes the original five concerns.

**`message` and `category` are BOTH optional; the dict is always pure metadata.** Message and category
share the **leading "body" slot**: a message renders as logfmt's `msg=`; category-only makes the
category the body's leading token; neither leaves the body as just metadata. The dict is never the body
text — `["state": "started"]` is a metadata key, not a message.

```swift
extension Logger {
    // message [+ metadata]  — swift-log-direct style; category omitted → default
    func info(_ message: @autoclosure () -> Logger.Message,
              metadata: [String: Any?] = [:],
              file: String = #fileID, function: String = #function, line: UInt = #line)

    // category [+ message] [+ metadata]  — Muse style; message omitted → no msg=
    func info(_ category: some LogCategoryConvertible,
              _ message: @autoclosure () -> Logger.Message? = nil,
              metadata: [String: Any?] = [:],
              file: String = #fileID, function: String = #function, line: UInt = #line)

    // dynamic level (closure / re-level entry)
    func custom(level: Logger.Level,
                _ category: some LogCategoryConvertible,
                _ message: @autoclosure () -> Logger.Message? = nil,
                metadata: [String: Any?] = [:],
                file: String = #fileID, function: String = #function, line: UInt = #line)
}
```
`debug` / `warning` / `error` mirror `info`. Call sites:
```swift
log.info("wrote", metadata: ["bytes": n])      // msg + metadata, default category
log.info(AppCategory.mcp, "started", metadata: ["port": p]) // category + msg + metadata
log.info(AppCategory.mcp, "started")                        // category + msg
log.info(AppCategory.mcp, metadata: ["foo": "bar"])         // category + metadata, NO msg
log.custom(level: lvl, AppCategory.mcp, "msg", metadata: ["k": v]) // dynamic level
```
- **`metadata:` is LABELED** (matches MuseLog's labeled `context:`). MuseLog names its first arg
  `message:` though its TYPE is the category enum — **do NOT inherit that name**; here the category arg
  is positional and the dict is `metadata:`. (A `MuseLog` shim keeping `context:` forwards trivially.)
- Overloads resolve unambiguously: first arg is `Logger.Message` (string literal) or
  `some LogCategoryConvertible`; after a category, the next positional is a `Logger.Message` or
  absent. Swift cannot infer an arbitrary application enum from bare `.mcp` in a generic parameter,
  so call sites qualify it as `AppCategory.mcp`. App codegen may emit constrained static forwarders
  if bare-member syntax is required.
- `message` is `@autoclosure` (not built when the gate drops the call); `Logger.Message?` on the
  category overloads so it can be omitted.
- All overloads render `[String: Any?]` through the **same `String.logfmt` renderer**, eagerly on the
  calling thread; category/`msg=` render per Phase-1 formatter config. Additive on the real `Logger`.

**Routing closure-based loggers is a doc note, not a type:** the app's closure calls
`log.custom(level:_:_:metadata:)` directly (mirroring MuseLog's `LogContext.logHandler`). The
dynamic-level entry is the only affordance this needs.

> **MuseLog shape (confirmed from source):** `static func info(_ message: Category, file:…, function:…,
> line:…, context: [String: Any?]? = nil)` — first arg is the **category** (misnamed `message:`),
> **required**; `context:` labeled & optional; **no human-message field**. The body renders as
> `<category.rawValue> <String.logfmt(context)>` (bare leading token), then SwiftyBeaver prefixes
> ts/[thread]/level/File.func:line → final order `ts [thread] LEVEL File.func:line CATEGORY(bare)
> context-pairs`. FellerBuncher matches this as a formatter option but makes category **optional**
> (swift-log-direct users have a label, not a category) and names the arg positional, not `message:`.

- **Tests:** a message emits `msg="…"`, none emits **no `msg=`** (never `msg=""`); category-only renders
  the category as the leading body token; the dict is never the body; the four overload shapes resolve
  unambiguously; sugar and the closure path produce identical bytes; `custom(level:)` routes a dynamic
  level; an app `enum Cat: String` conformed to `LogCategoryConvertible` works in
  `log.info(Cat.mcp, …)` with no per-call `.init(rawValue:)`; `@autoclosure` message NOT evaluated
  when the gate drops the call; `file/function/line` forwarded.

### Phase 4 — Multi-destination
**Goal:** fan one record out to many destinations with per-destination filtering, safe runtime
add/remove, and safe teardown. Add the ThreadSanitizer race tests here.
- **`DestinationRegistry`** — runtime-mutable (`addDestination`/`removeDestination`, no relaunch). The
  lock is held **only to copy the list**; fan-out happens outside it so a slow destination can't block
  registration. `removeDestination` keys on `ObjectIdentifier`, then calls the destination's `tearDown`.
- **`FilterConfig`** — the `{minimumLevel, include, exclude, forceInclude}` triple as **one `Sendable`
  value behind its own lock**, read+swapped **whole** so level and categories can't tear relative to
  each other mid-fan-out. `shouldLog` decides from one `filterConfig()` snapshot. Filtering =
  per-destination level + category **include-set** AND **exclude-set** + **force-include** (admit a
  record *below* the gate for an allowlisted category/source). This is a **second synchronization
  domain** from the serial queue; **lock-ordering rule: never nest them** (no filter lock on the queue,
  no `queue.sync` while holding the filter lock).
- **`tearDown` + closed flag** — `tearDown(completion:)` runs drain+close **on the destination's own
  queue**, so a late `receive()` from a fan-out snapshot is ordered before the close (writes) or after
  (no-ops). It sets a terminal **`closed`** flag, checked in the write path **before**
  `openHandleIfNeeded`, so a post-close write can't resurrect a torn-down file.
- **`ConsoleDestination`** — `ConsoleMode` `.osLog` (default) / `.stderr` / `.none`.
  - `.osLog`: emit the formatted line via an `os.Logger` cached **per category** (subsystem = a constant
    app bundle id), `privacy: .public` (we control + sanitize the line). **Bound the cache** (LRU or
    cache-known-only) for the open-cardinality `.other` category.
  - Plus an **always-on, separate OSLog breadcrumb channel** for the writer's own degradation events
    ("write failed", "rotation move failed") — independent of `ConsoleMode`, survives a broken file path.
- **`MemoryDestination`** — fixed-capacity ring buffer (default **5000**, **O(1) drop-oldest**) storing
  **structured `LogRecord`s** so an in-app viewer can re-filter and render lazily. A single coalesced
  `onChange` `@Sendable () -> Void` callback **delivered on main** (the only consumer is a view; mutating
  view state off-main is undefined). **Coalescing avoids the lost-wakeup race:** under the lock set
  `dirty=true` and `if !scheduled { scheduled=true; dispatch }`; the fired block, under the lock, sets
  `scheduled=false` and captures+clears `dirty` before firing, so a log mid-fire re-arms a fresh schedule.
- **Tests — must run under ThreadSanitizer** (`swift test --sanitize=thread`).
  `-strict-concurrency=complete` proves types are `Sendable`, **not** that an `@unchecked` claim holds —
  a green normal run can still be racy, so the two race tests are **meaningless without TSan:**
  - **Filter-config torn read:** one thread tight-loops `setGlobalLevel(.debug)↔(.info)` while N threads
    fan out through a destination whose `shouldLog` reads `filterConfig()` — TSan clean, no record judged
    against a half-applied config.
  - **Teardown use-after-close:** tight-loop `addDestination`/`removeDestination` on a `FileDestination`
    during a write burst — no crash, no write after close, **no reopen after teardown**, nothing lost
    from destinations that stayed registered.
  - Plus: fan-out routes only to destinations whose level + category include/exclude passes;
    force-include admits a below-global record for an allowlisted category; runtime add/remove changes
    where subsequent records land; OSLog caches one `os.Logger` per category (not per label);
    `MemoryDestination` caps at 5000 with O(1) drop-oldest, snapshot in order, and `onChange` coalesces
    (N logs → ≥1 refresh, at least one **after** the last log).

### Phase 5 — Control surface + lifecycle
**Goal:** runtime control, startup safety, and calendar-day rotation.
- **`LoggingHandle`** (returned by `bootstrap`):
  - `addDestination`/`removeDestination` (runtime registry mutation; remove drains before teardown).
  - `setGlobalLevel(_:)` — writes `minimumLevel` into **every** destination's `FilterConfig` (atomic
    setter) **and** the handler gate, so the level reaches the destinations, not just the handler. A
    destination added afterward inherits it. Backs a shipping feature ("Enable Debug Logging").
  - `effectiveLevel` (get) — global readback for a settings toggle and for slaving closed SDKs
    (Setapp/Sparkle) to one sink. The package set/gets; the app persists and re-asserts at startup.
  - `onEffectiveLevelChange` — fires on change, **delivered on the thread that called
    `setGlobalLevel`** (the app hops to main itself if its SDK setter needs it).
  - `drain(...)` in the three forms above (also dependency-driven flush).
- **preConfigLogs replay** — a lightweight bootstrap-time handler buffers records emitted **before**
  bootstrap (bounded, **drop-oldest**) and replays them into the destinations once they exist, **tagged
  `late=true`** (`Logger(label:)` binds its handler at construction, so early logs would otherwise be
  lost). Replayed lines land physically after their timestamps — file order ≠ chronological for the
  replayed prefix; `late=true` is the re-sort escape hatch.
- **`.dateStamped(granularity, zone)` rotation** — the active filename embeds the **UTC day**
  (`<name>-yyyy-MM-dd.log`); roll at the day boundary by **computed-filename-differs**, not a timer.
  Checked cheaply on **every `receive()`** (so the next write after midnight, and a cold launch the next
  day, open the fresh file) plus an **idempotent `rollIfDateChanged()`** the app may poke on any cadence
  — **no package timer**. No numbered siblings; pruning is purely age-based. The active file is
  **dynamic** here, so the skip-active prune guard recomputes today's name each sweep (both on the serial
  queue, so ordered).
- **Tests:** `setGlobalLevel(.debug)` flips minimumLevel on every destination + the handler gate;
  `effectiveLevel` returns it; `onEffectiveLevelChange` fires on the setter's thread; a later-added
  destination inherits the level. preConfigLogs replay tagged `late=true`. `.dateStamped` filename
  embeds the UTC date and swaps by filename-differs; **cold-launch-after-day-boundary** — a launch the
  day after the last write opens the new dated file, nothing lost to yesterday's. Callback-thread
  contracts (`onChange` on main, `onEffectiveLevelChange` on the setter's thread).

### Phase 6 — Generalization + deferred
**Goal:** prove the protocol generalizes and stake out the deferred work.
- **Sentry-as-destination (app-owned example, not shipped)** — a `SentryDestination` with
  `minimumLevel = .error` and a value transform (typed context like `QualifiedId.hexString`,
  file/func/line as extras) is just another `LogDestination`. The package ships the protocol +
  registry, the app supplies the destination — proof the per-destination + typed-category design
  generalizes beyond files.
- **Anonymization hook point** — at most an optional shape-preserving hook; **no policy** ships. The
  app owns the call-site transform.
- **Deferred:** log exporter/zip plumbing (Foundation-only; least reusable); in-package
  rate-limit/coalescing (app/source-owned for v1, but the level-gate + per-destination filters must
  compose with an upstream throttle); log viewer UI + share/save presentation (always the app).

---

## Package layout (target)
```
Package.swift                       # swift-log + adamwulf/Logfmt; Swift 6 mode; lib + test target
Sources/FellerBuncher/
  FellerBuncher.swift               # bootstrap() -> LoggingHandle + public config types
  LoggingHandle.swift               # control surface: add/removeDestination, set/effectiveLevel, drain
  LogRecord.swift                   # value type; sanitized once; category + ThreadKind + source + rendered-metadata fragment
  LogCategory.swift                 # first-class routable field (String wrapper, app maps its enum)
  LogfmtFormatter.swift             # per-destination config (ts/level style, thread, fields); one renderer via String.logfmt
  LogDestination.swift              # protocol + FilterConfig (level + category include/exclude + force-include)
  DestinationRegistry.swift         # runtime-mutable, lock-guarded fan-out target
  FileDestination.swift             # serial queue; RotationPolicy (.size/.dateStamped, app-poked rollIfDateChanged); prune
  MemoryDestination.swift           # ring buffer 5000, O(1) drop-oldest, coalesced onChange
  ConsoleDestination.swift          # OSLog (os.Logger cached per category) / stderr / none
  FellerBuncherLogHandler.swift     # swift-log LogHandler: level-gate, build record, fan out
  Logger+Convenience.swift          # sugar: debug/info/warning/error + custom(level:) + [String:Any?] + category
  # No ClosureHandlerBridge type — apps route closures by calling custom(level:) directly.
  # LogExporter.swift               # DEFERRED: Foundation-only zip plumbing, no UIKit.
  # SentryDestination.swift         # APP-OWNED example, not shipped.
Tests/FellerBuncherTests/           # inject a temp dir; run under --sanitize=thread
plans/PLAN.md                       # this file
```
