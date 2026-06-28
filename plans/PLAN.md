# FellerBuncher — Implementation Plan

A reusable Swift logging package built on **swift-log** + **adamwulf/Logfmt**. It produces clean
logfmt lines and fans each log event out to one or more destinations (rotating/pruned file,
in-memory ring buffer, console/OSLog), and drops into any Swift package or app in one call.

Status: **DESIGN.** This document is the target. Build it in the phases below — each phase is
independently buildable and testable, layering toward the full design. Slow and steady.

---

## Boundary (package vs. user)

- **Consumers use swift-log's `Logger` directly — there is no facade type.** The package owns only
  the one-call bootstrap, the `LogHandler`, and the destinations.
- **Logfmt is a private dependency**, used only inside the package; it is **not** re-exported, so it
  stays swappable.
- **Path-agnostic:** the log directory is always a caller-supplied parameter, never a hard-coded
  container. (Biggest testability win — tests inject a temp dir.)
- **Dependency direction:** libraries depend on **swift-log only** and emit plain `Logger(label:)`
  values; only the **app** (or a single composition root) depends on FellerBuncher and calls
  `bootstrap`. Library loggers route to whatever was bootstrapped — the fan-out when the app runs,
  swift-log's default stderr under `swift test` with no bootstrap.

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

**Swift 6 / `-strict-concurrency=complete` from day one.** This is the one place we lead rather than
inherit a 5.9 baseline.

---

## Concurrency contract

- **The public interface needs no async/await.** swift-log's `Logger`, `bootstrap`, and the sugar
  are all synchronous and fire-and-forget; a non-async call site uses the whole path without entering
  an `async` context.
- **The write path is fire-and-forget sync:** `write(line)` does `queue.async { performWrite }`; the
  caller never blocks. (This is why destinations are serial-queue classes, not actors — swift-log's
  `log()` is sync and cannot `await`.)
- **The only dual-API surface is `drain`** (export is deferred). It comes in three shapes:
  1. **sync** `queue.sync {}` — a barrier; **test/known-safe-thread only.** Document the hazards:
     `queue.sync` from main at shutdown can priority-invert, and it must **never** be called from an
     `async` context (it blocks a cooperative-pool thread).
  2. **callback** `drain(completion:)` = `queue.async { completion() }` — non-blocking, safe
     anywhere; the **source of truth** and the production shutdown/pre-export call.
  3. **async** `drain() async` = `withCheckedContinuation { c in drain { c.resume() } }`, derived
     from #2 so the two surfaces can't drift.

---

## Phases

### Phase 0 — Package skeleton
**Goal:** an empty package that builds green in CI.
- `Package.swift`: deps on **swift-log** + **adamwulf/Logfmt**; Swift 6 language mode /
  `-strict-concurrency=complete`. (Pin a swift-log ≥ 1.14 so `log(event:)` is available.)
- Empty `FellerBuncher` library target + `FellerBuncherTests` test target.
- **Test:** `swift build` and `swift test` succeed; CI green.

### Phase 1 — Pure formatting core (no I/O)
**Goal:** turn a log event into one logfmt line, configurably, with zero I/O. The foundation
everything else formats through.
- **`LogRecord`** — immutable `Sendable` value built **once per call, eagerly on the calling
  thread**, shared by value to every destination. Carries `timestamp`, `level`, `label`,
  `category: LogCategory`, `message`, source (`file/function/line`), `thread: ThreadKind`, and
  **metadata pre-rendered to a single sanitized logfmt fragment** (a `Sendable` string, **not** a
  `[String:String]` map).
  - `ThreadKind` (`.main`/`.bg`) is sampled via `Thread.isMainThread` **at construction** — eager is
    mandatory; by the time a destination's queue formats the record the thread identity is gone.
  - Sanitization (strip `\r\n` + control chars) happens **here, once**, while rendering the metadata
    fragment, so the `Any?` bag never crosses a queue/`Sendable` boundary and destinations never
    re-sanitize.
  - **One metadata renderer:** `String.logfmt` over `[String: Any?]` (handles nils, nested
    dicts/arrays, and `CustomLogfmtStringConvertible` typed values). It is the *only* flattening
    path — both the sugar and the closure bridge route through it, so the wire format can't drift.
  - **Forward-guard comment at the `LogRecord` definition:** *metadata is pre-rendered to a single
    fragment; per-destination metadata-key selection is intentionally unsupported. If a future
    destination needs it, carry the structured `[String: Any?]` in a `Sendable` box rendered lazily.*
- **`LogCategory`** — a `Sendable`/`Hashable`/`ExpressibleByStringLiteral` `String` wrapper.
  Category-taking APIs accept **any `RawRepresentable<String>`** (`LogCategoryConvertible`) so an app
  conforms its generated enum and writes `log.info(.mcp, …)`. The package does **not** own the enum
  or its codegen. Cheap to omit: a `Logger`-only call gets a default category. Used three ways:
  destination routing key (set membership), an optional wire field, and the OSLog `category:`.
- **`LogfmtFormatter`** — a per-destination **config** that is still a pure static
  `LogRecord -> String` function. Parameterized by:
  - **Timestamp style** — default `.iso8601`; per-destination overridable (e.g. a 24-char
    `yyyy-MM-dd HH:mm:ss.SSS` UTC).
  - **Level style** — `.raw` (default, `level.rawValue`) | `.paddedUppercase`. All 7 levels stay
    distinct, **no collapsing** (`grep level=error` must work).
  - **Field selection + order** of `ts/level/label/category/thread/source/msg/metadata`. Source
    attribution is captured always but **rendered opt-in** (default off). Leading fields are emitted
    **by hand** in a stable order (`String.logfmt` sorts keys alphabetically, so field order can't
    rely on it); the message + metadata are appended via the one renderer.
  - **Sanitization is non-optional, baked in** (not a formatter toggle).
  - Default `ts` = **ISO8601 fractional seconds, UTC, `Z`-suffixed** (`2026-06-27T12:34:56.789Z`) via
    **`Date.ISO8601FormatStyle`** (a `Sendable` value type — avoids the non-`Sendable`
    `ISO8601DateFormatter` warning under complete concurrency). Output must be **byte-identical** to
    `ISO8601DateFormatter` (`.withInternetDateTime` + `.withFractionalSeconds` + UTC `Z`) so existing
    greps don't break — locked by a regression test.
- **Tests (all pure functions, no temp dir):** stable leading-field order; escaping/quoting via
  `String.logfmt`; sanitization strips `\r\n`/control chars from message **and** every metadata
  value; a record built on **main** formats `[UI]` even when formatted later off a background queue;
  `Error.loggingContext()` (nested `underlying_errors` array-of-dicts + a nil + a
  `CustomLogfmtStringConvertible` id) renders identically through the public entry and through
  `String.logfmt` directly; two formatter configs render the same record differently; the 24-char
  custom timestamp is exactly 24 chars as the leading field. **Timestamp wire-format lock:**
  `ISO8601FormatStyle` is byte-identical to `ISO8601DateFormatter` across ≥5 fractional cases (`.000`,
  `.050`, `.700`, `.999`, whole second) — proving always exactly 3 fractional digits. **Timestamp
  perf benchmark:** 10k formats via `ISO8601FormatStyle` vs a cached `ISO8601DateFormatter`; if the
  value type is materially slower, fall back to `nonisolated(unsafe) static let ISO8601DateFormatter`
  (perf is the measured trigger, not aesthetics).

### Phase 2 — File MVP
**Goal:** *log to a rotating, pruned file in one line.*
- **`LogDestination` protocol** (`AnyObject, Sendable`): `filterConfig()`/`setFilterConfig(_:)`
  (read/write the whole triple atomically), `shouldLog(_:)`, `receive(_:)` (cheap, enqueues),
  `tearDown(completion:)`. *(Filtering/teardown internals land fully in Phase 4; Phase 2 needs only
  the level gate.)*
- **`FileDestination`** — class, private serial `DispatchQueue`, `@unchecked Sendable` (state is
  queue-confined). Writes `logDir/<processName>.log`; holds its own `LogfmtFormatter`. Pluggable
  `RotationPolicy`:
  - `.size(bytes)` (this phase) — numbered siblings (`app.log → app-1.log`, shift up), checked
    **before** each write so overshoot is bounded to one record; **truncate-in-place fallback** if
    the rename fails so the size bound always holds.
  - `.none`.
  - `.dateStamped` arrives in Phase 5.
  - **Pruning** — per-directory (each process prunes its own dir at startup, off-main), age-based,
    and **never the active file** (an unlinked-but-open file silently swallows writes → data loss).
    Prune date field is configurable (`contentModificationDate` vs `creationDate`).
  - **Defaults:** `maxFileBytes = 10MB`, `rotatedFilesToKeep = 5`, `pruneInterval = 1 hour` (don't
    `stat` the dir on every line) — start as constants. **Retention is a param** (`7d` default; real
    consumers already differ).
- **`FellerBuncherLogHandler`** (swift-log `LogHandler`) — **cheap level-gate first**
  (`guard logLevel <= level` before any allocation, so calls stay inline in hot paths), then build
  the `LogRecord` once and fan out to each passing destination. Implement **`log(event:)`**
  (swift-log 1.14+), folding the event's optional `error` into the metadata bag (its
  `localizedDescription` often has newlines → sanitized). Keep the `format(...)` helper a pure static
  function.
- **`bootstrap(processName:logDir:, console:.osLog, inMemory:false, minimumLevel:.info)`** — builds
  destinations + registry, installs the handler via `LoggingSystem.bootstrap`. **Idempotent**
  (`NSLock`-guarded `Bool` around the bootstrap call). **Synchronous startup** — the dir/file is
  ready before it returns, so the first log lands. Returns a `LoggingHandle` (full surface in
  Phase 5).
- **Tests (inject a temp dir):** writes land in the file; `.size` rotation rolls at the threshold and
  shifts siblings; rename-failure → truncate-in-place keeps the size bound; pruning by count and age
  **never** removes the active file, per-directory only; bootstrap idempotency (second call is a safe
  no-op). Keep formatting tests pure (no temp dir).

### Phase 3 — Ergonomic helpers
**Goal:** the convenient call sites. Completes the original five concerns.
- **Two orthogonal, composable sugars** on the real `Logger` (additive, not a replacement type):
  1. **metadata-dict** `log.info("wrote", ["bytes": n])` — `[String: Any?]`.
  2. **category** `log.info(.mcp, "started", ["port": p])` — any `RawRepresentable<String>`.
  - Plus `debug/info/warning/error` and **`custom(level:category:_:metadata:file:function:line:)`**
    with `level` as a **runtime value** (the dynamic-level entry).
- All sugar renders its `[String: Any?]` bag through the **same `String.logfmt` renderer** as the
  closure path (one renderer → sugar and bridge can't drift), eagerly on the calling thread. Forward
  `file/function/line`.
- **Routing existing closure-based loggers is a doc note, not a type:** an app's own closure body
  calls the public `custom(level:category:_:metadata:)` directly, mapping its runtime `level` and
  handing `context` as the metadata bag. The dynamic-level entry above is the only affordance this
  requires.
- **Tests:** sugar and the closure path produce identical bytes for the same bag; `custom(level:)`
  routes a dynamic level correctly; an app `enum Cat: String` conformed to `LogCategoryConvertible`
  works in `log.info(.mcp, …)` with no per-call `.init(rawValue:)`; `file/function/line` forwarded.

### Phase 4 — Multi-destination
**Goal:** fan one record out to many destinations with per-destination filtering, safe runtime
add/remove, and safe teardown. Add the ThreadSanitizer race tests here.
- **`DestinationRegistry`** — runtime-mutable (`addDestination`/`removeDestination`, no relaunch).
  The lock is held **only to copy the list**; fan-out happens outside it so a slow destination can't
  block registration. `removeDestination` keys on registry-side `ObjectIdentifier`, then calls the
  destination's `tearDown`.
- **`FilterConfig`** — the `{minimumLevel, include, exclude, forceInclude}` triple as **one
  `Sendable` value behind its own lock**, read+swapped **whole** (so level and categories can never
  tear relative to each other when the global level changes during fan-out). `shouldLog` takes one
  `filterConfig()` snapshot and decides from it. Filtering = per-destination level + category
  **include-set** AND **exclude-set** + **force-include** (admit a record *below* the gate for an
  allowlisted category/source). This is a **second synchronization domain** from the serial queue;
  **lock-ordering rule: the two domains must never nest** (never take the filter lock on the queue,
  nor `queue.sync` while holding the filter lock).
- **`tearDown` + closed flag** — `tearDown(completion:)` runs drain+close **on the destination's own
  queue** (a late `receive()` captured in a fan-out snapshot is then ordered before the close — it
  writes — or after — it no-ops). It sets a terminal **`closed`** flag, checked in the write path
  **before** `openHandleIfNeeded`, so a post-close write can't resurrect a torn-down file.
- **`ConsoleDestination`** — `ConsoleMode` `.osLog` (default) / `.stderr` / `.none`.
  - `.osLog`: emit the formatted line via an `os.Logger` cached **per category** (subsystem = a
    constant app bundle id), with `privacy: .public` (we control + sanitize the line). **Bound the
    cache** (LRU or cache-known-only) for the open-cardinality `.other` category.
  - Plus an **always-on, separate OSLog breadcrumb channel** for the writer's own degradation events
    ("write failed", "rotation move failed") — survives even when the file path is broken, independent
    of `ConsoleMode`.
- **`MemoryDestination`** — fixed-capacity ring buffer (default **5000**, **O(1) drop-oldest**)
  storing **structured `LogRecord`s** so an in-app viewer can re-filter and render lazily. A single
  coalesced `onChange` `@Sendable () -> Void` callback **delivered on main** (the only consumer is a
  view; mutating view state off-main is undefined). **Coalescing avoids the lost-wakeup race:** under
  the lock set `dirty=true` and `if !scheduled { scheduled=true; dispatch }`; the fired block, under
  the lock, sets `scheduled=false` and captures+clears `dirty` before firing, so a log during the
  fire re-arms a fresh schedule.
- **Tests — must run under ThreadSanitizer.** `-strict-concurrency=complete` proves types are
  `Sendable`, **not** that an `@unchecked` claim holds; a green normal run can still be racy. Run the
  whole suite with `swift test --sanitize=thread`. The two race tests are **meaningless without
  TSan:**
  - **Filter-config torn read:** one thread tight-loops `setGlobalLevel(.debug)↔(.info)` while N
    threads fan out through a destination whose `shouldLog` reads `filterConfig()` — TSan clean, no
    record judged against a half-applied config.
  - **Teardown use-after-close:** tight-loop `addDestination`/`removeDestination` on a
    `FileDestination` during a write burst — no crash, no write after close, **no reopen after
    teardown**, nothing lost from destinations that stayed registered.
  - Plus: fan-out routes a record only to destinations whose level + category include/exclude passes;
    force-include admits a below-global record for an allowlisted category; runtime add/remove changes
    where subsequent records land; OSLog caches one `os.Logger` per category (not per label);
    `MemoryDestination` caps at 5000 with O(1) drop-oldest, snapshot in order, and `onChange`
    coalesces (N logs → ≥1 refresh and at least one refresh **after** the last log).

### Phase 5 — Control surface + lifecycle
**Goal:** runtime control, startup safety, and calendar-day rotation.
- **`LoggingHandle`** (returned by `bootstrap`):
  - `addDestination`/`removeDestination` (runtime registry mutation; remove drains before teardown).
  - `setGlobalLevel(_:)` — writes the `minimumLevel` in **every** destination's `FilterConfig` (via
    its atomic setter) **and** the handler gate, so the level reaches the destinations, not just the
    handler. A destination added afterward inherits the current global level. Backs a shipping user
    feature ("Enable Debug Logging"), not just a debug affordance.
  - `effectiveLevel` (get) — global readback for a settings toggle and for slaving closed SDKs
    (Setapp/Sparkle) to one sink. The package set/gets; the app persists and re-asserts at startup.
  - `onEffectiveLevelChange` — fires on level change, **delivered on the thread that called
    `setGlobalLevel`** (the app hops to main itself if its SDK setter needs it).
  - `drain(...)` in the three forms above (also dependency-driven flush).
- **preConfigLogs replay** — a lightweight bootstrap-time handler buffers records emitted **before**
  bootstrap (bounded, **drop-oldest** overflow) and replays them into the destinations once they
  exist, **tagged `late=true`**. (`Logger(label:)` binds its handler at construction, so early logs
  would otherwise be lost.) Replayed lines land physically later than their timestamps — file order ≠
  chronological for the replayed prefix; that's expected, and `late=true` is the re-sort escape hatch.
- **`.dateStamped(granularity, zone)` rotation** — the active filename embeds the **UTC day**
  (`<name>-yyyy-MM-dd.log`); roll at the day boundary detected by **computed-filename-differs**, not
  a timer. Check cheaply on **every `receive()`** (so the next write after midnight, and a cold launch
  the next day, open the fresh file) plus an **idempotent `rollIfDateChanged()`** the app may poke on
  any cadence — **no package timer**. No numbered siblings; pruning is purely age-based. Under
  `.dateStamped` the active file is **dynamic** — the skip-active prune guard must recompute today's
  name each sweep (both run on the serial queue, so they're ordered).
- **Tests:** `setGlobalLevel(.debug)` flips minimumLevel on every destination + the handler gate;
  `effectiveLevel` returns it; `onEffectiveLevelChange` fires on the setter's thread; a
  later-added destination inherits the level. preConfigLogs replay into destinations tagged
  `late=true`. `.dateStamped` filename embeds the UTC date and swaps by filename-differs;
  **cold-launch-after-day-boundary** — a launch the day after the last write opens the new dated file
  with nothing lost to yesterday's. Callback-thread contracts verified (`onChange` on main,
  `onEffectiveLevelChange` on the setter's thread).

### Phase 6 — Generalization + deferred
**Goal:** prove the protocol generalizes and stake out the deferred work.
- **Sentry-as-destination (app-owned example, not shipped)** — a `SentryDestination` with
  `minimumLevel = .error` and a value transform (typed context like `QualifiedId.hexString`,
  file/func/line as extras) is just another `LogDestination`. The package ships the protocol +
  registry; the app supplies the destination. Proof the per-destination + typed-category design
  generalizes beyond files.
- **Anonymization hook point** — at most an optional shape-preserving hook; the package ships **no
  policy**. The app owns the call-site transform.
- **Deferred:** log exporter/zip plumbing (Foundation-only; least reusable piece); in-package
  rate-limit/coalescing (app/source-owned for v1, but the cheap-level-gate + per-destination filters
  must compose with an upstream throttle); log viewer UI and share/save presentation (always the app).

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
