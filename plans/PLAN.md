# FellerBuncher — Implementation Plan

A reusable Swift logging package built on **swift-log** + **adamwulf/Logfmt**. It produces
clean logfmt log lines, routes them to one or more destinations (file with rotation/pruning,
in-memory ring buffer, console/OSLog), and is trivial to drop into any Swift package or app.

Status: **DESIGN — not yet implemented.** This document is the target. Open questions are
marked `PENDING` and must be resolved before the affected component is built.

---

## 1. Guiding principles (the package/user boundary)

These come from the `log-helper` agent, who shipped a near-identical package (GuessWhoLogging)
and handed over the decisions below. They are accepted as the foundation.

1. **Consumers use swift-log's `Logger` directly. No facade type.** The package owns only
   (a) a one-call bootstrap and (b) the `LogHandler` factory. Anyone who knows swift-log
   already knows this API. A custom logging type would fight muscle memory and re-implement
   level methods for no gain.
2. **Logfmt is a private formatting detail.** `adamwulf/Logfmt` is a separate dependency, used
   only inside the handler. It is **not** re-exported; consumers never touch `String.logfmt`.
   This keeps it swappable.
3. **The package is path-agnostic.** The log directory is always supplied by the caller (a
   parameter, never a hard-coded container path). This is the single biggest testability win:
   tests inject a temp dir and never touch real app containers.
4. **Sane defaults everywhere except processName + logDir.** The 1-line setup is
   `FellerBuncher.bootstrap(processName:logDir:)`; everything else (rotation size, retention,
   which destinations, levels) has a default so it can be omitted.
5. **Concurrency: serial `DispatchQueue`, not actors.** swift-log's `LogHandler.log(...)` is
   synchronous and non-async, so an actor would force `await` hops that cannot be made from
   inside `log()`. Destinations that do I/O are classes guarding all mutable state behind a
   private serial queue, marked `@unchecked Sendable` (sound because state is queue-confined).
6. **Dependency direction: libraries depend on swift-log only; the app depends on FellerBuncher.**
   (log-helper's key insight.) A library/engine that wants to log imports only `Logging` and emits
   plain `Logger(label:)` values — it does NOT depend on FellerBuncher. Those loggers route to
   whatever backend was bootstrapped: the file/fan-out when the app is running, swift-log's default
   stderr under `swift test` with no bootstrap. Only the **app (or a single composition-root
   module)** depends on FellerBuncher and calls `bootstrap` to install the destination fan-out.
   This keeps every library dependency-light (no file-writer/exporter/container machinery dragged
   in) and makes `LogDestination`s an **app-composition concern** — the exact seam SwiftyBeaver's
   `addDestination` occupies, so the muse-ios migration maps cleanly.

### Boundary table

| Concern | Owned by **package** | Owned by **user** |
| --- | --- | --- |
| logfmt formatting | ✅ handler | — |
| File writing, rotation, pruning | ✅ file destination | — |
| In-memory ring buffer | ✅ memory destination | — |
| Console / OSLog mirroring | ✅ console destination | — |
| One-call bootstrap + idempotency guard | ✅ | — |
| Log directory path | — | ✅ (param) |
| Rotation size / retention values | ✅ defaults | ✅ override |
| Per-destination min level / category filter | ✅ defaults | ✅ override |
| Which logger labels + metadata to attach | — | ✅ |
| Log zip (plumbing) | ⏸ optional, deferred (Q5) | — |
| Log share/save **presentation** (UIKit) | — | ✅ always app |

---

## 2. Architecture overview

The muse-ios goal (replace a complex SwiftyBeaver setup) forces a **multi-destination**
design from the start. SwiftyBeaver routes one log event to N destinations, each with its own
minimum level and filtering. FellerBuncher mirrors that shape: a single swift-log `LogHandler`
fans each record out to a set of `LogDestination`s.

```
                                  ┌─────────────────────────────┐
 Logger(label:).info("…", […])    │  FellerBuncherLogHandler     │
   ──────────────────────────────▶│  (swift-log LogHandler)      │
                                  │  - builds an immutable        │
                                  │    LogRecord (ts, level,      │
                                  │    label, msg, metadata)      │
                                  │  - fans out to destinations   │
                                  └──────────────┬──────────────┘
                                                 │  for each destination:
                                                 │  if record passes its filter →
                       ┌─────────────────────────┼─────────────────────────┐
                       ▼                          ▼                         ▼
              ┌─────────────────┐       ┌──────────────────┐      ┌──────────────────┐
              │ FileDestination │       │ MemoryDestination│      │ ConsoleDestination│
              │ serial queue,   │       │ ring buffer,     │      │ OSLog / stderr    │
              │ logfmt → file,  │       │ recent N records │      │ (dev visibility)  │
              │ rotation+prune  │       │ (export/in-app)  │      │                  │
              └─────────────────┘       └──────────────────┘      └──────────────────┘
```

**Formatting vs. destination split:** logfmt formatting lives in a single `LogfmtFormatter`
used by destinations that emit text (file, console). The memory destination can keep structured
`LogRecord`s (so an in-app viewer can filter them) and format lazily on export. This keeps the
formatter a pure function and avoids each destination re-implementing escaping.

> Note: the first shipped version may only wire up `FileDestination` (+ optional console), but
> the `LogDestination` protocol and the fan-out handler are built now so muse-ios's in-memory
> target, profiling mode, and per-destination filtering slot in without a rearchitecture.

---

## 3. Components

### 3.1 `LogRecord` (value type)
Immutable struct produced once per log call and shared (by value) to every destination:
`timestamp: Date`, `level: Logger.Level`, `label: String`, `message: String`,
`metadata: [String: String]` (already flattened + sanitized — see §4), plus source
attribution (`file/function/line`). Sendable.

### 3.2 `LogfmtFormatter`
Pure function `LogRecord -> String` (one line, newline-terminated). Responsibilities:
- Emit **fixed leading fields by hand** in a stable order: `ts=… level=… label=…`
  (`String.logfmt` sorts keys alphabetically, so we cannot rely on it for field order — gotcha C).
- Append the message + metadata by handing **one dict** to `String.logfmt` (`["msg": …, …meta]`).
- Sanitize: strip `\r`/`\n` and other control chars from the message and every metadata value
  before formatting, so one record is always exactly one line (gotcha D).
- `level=` tokens: emit `level.rawValue` directly — all 7 distinct, **no collapsing**
  (`trace debug info notice warning error critical`). `grep 'level=error'` just works.
  Collapsing `notice→info` would throw away a level a consumer deliberately chose. (Q3)
- `ts=` format: **ISO8601 with fractional seconds, UTC, `Z`-suffixed** →
  `ts=2026-06-27T12:34:56.789Z`. Sortable (lexical == chronological) + human-readable. (Q4)
  - **Use `Date.ISO8601FormatStyle` (Sendable value type), NOT `ISO8601DateFormatter`.** Going
    Swift 6 / complete-concurrency from day one (see §4.2), a `static let ISO8601DateFormatter`
    (non-Sendable) warns; the format style sidesteps it entirely and is the right modern choice.
    Configure `.year().month().day()...`/`includingFractionalSeconds: true` with `timeZone: .gmt`
    (or the `ISO8601FormatStyle(...)` initializer with fractional seconds + UTC). Pin UTC
    explicitly so logs from different zones sort and correlate.
  - log-helper's reference used a frozen `static let ISO8601DateFormatter` (safe under their 5.9
    baseline because configure-once-never-mutate); we improve on it with the value-type style.

### 3.3 `LogDestination` (protocol)
```
protocol LogDestination: Sendable {
    var minimumLevel: Logger.Level { get }
    func shouldLog(_ record: LogRecord) -> Bool   // level + optional label/category filter
    func receive(_ record: LogRecord)             // must be cheap / non-blocking for caller
}
```
Each destination decides its own filtering (per-destination level + label filter), matching
SwiftyBeaver's per-destination routing.

### 3.4 `FileDestination` (the gnarly one)
Class, private serial `DispatchQueue`, `@unchecked Sendable`. Writes logfmt lines to
`logDir/<processName>.log`.
- **Rotation** when the active file exceeds the size cap: rename `app.log → app-1.log`
  (shift existing rotated files up). **Truncate-in-place fallback** if the rename fails, so the
  size bound always holds and we don't trip rotation on every subsequent write (gotcha F).
  Rotation is checked **before** each write, so the active file can overshoot the cap by at
  most one record — bounded overshoot is intentional (avoids re-`stat` after every write).
- **Pruning**: enforce max rotated-file count and/or max age, **never deleting the active
  file** (APFS keeps an unlinked-but-open file alive only for its holder → silent writes into
  an unreachable inode → data loss). Skip `activeURL` in the prune sweep (gotcha E). Pruning
  is per-directory (cleans the *other* process's stale `.log` files harmlessly too).
- **Defaults (Q1, adopted from log-helper):**
  - `maxFileBytes = 10 MB` per active file
  - `rotatedFilesToKeep = 5` (`app-1.log` … `app-5.log`; oldest dropped) → worst case ≈ 60 MB/process
  - `maxFileAge = 7 days` (prune anything older)
  - `pruneInterval = 1 hour` — **the non-obvious one**: re-check prune at most hourly so a
    chatty process doesn't `stat` the whole directory on every log line. Do not skip it.
  - Start these as **private constants**, not bootstrap params. Promote to defaulted params
    only when a consumer actually needs to differ. (muse-ios may need this — revisit after interview.)

### 3.5 `MemoryDestination` (for muse-ios in-memory target)
Fixed-capacity ring buffer of recent `LogRecord`s behind a small lock/queue. Exposes a
snapshot accessor for an in-app log viewer / export. Capacity configurable. **Details PENDING
muse-ios interview** (size, whether it stores records or formatted lines, thread-safety needs).

### 3.6 `ConsoleDestination` (Q2 — decided)
Dev-time visibility. Expose a **`ConsoleMode` enum: `.osLog` (default) / `.stderr` / `.none`**.
- `.osLog` (default on Apple platforms): write a small `OSLogDestination` that maps `label →
  subsystem/category` and emits the **same formatted logfmt line** at the mapped os level. This
  is a genuinely better default than stderr when consumers live in Xcode/Console.app — proper
  level coloring, subsystem/category filtering, shows in the unified log.
  - **Gotcha:** `os_log` redacts interpolated values as `<private>` by default. Emit the line
    with `privacy: .public` (`%{public}s`) — safe because we control + already sanitize the
    formatting, so nothing sensitive is added by making it public.
- `.stderr`: swift-log's `StreamLogHandler.standardError` equivalent, for server-side / CLI /
  non-Apple consumers.
- `.none`: file (and/or memory) only.

**Three distinct roles (log-helper's mental model, worth preserving):**
1. **File** = the durable logfmt record.
2. **Console (stderr or OSLog)** = dev-time echo.
3. **A dedicated OSLog breadcrumb channel** for the *writer's own* degradation events
   ("write failed", "rotation move failed") — these must survive even when the file path
   itself is broken, so they go to OSLog regardless of `ConsoleMode`. This is separate from
   the `.osLog` console mode and always on.

### 3.7 `FellerBuncherLogHandler` (swift-log `LogHandler`)
Holds the destination set + the per-logger `logLevel`/`metadata` swift-log requires. On a log
call: build a `LogRecord` once, fan out to each destination that passes its filter. The handler
itself is cheap; destinations own their own threading.
- **Implement `log(event:)`** (swift-log 1.14+) rather than the deprecated long-form
  `log(level:message:metadata:source:file:function:line:)`. `log(event:)` is the supported path
  AND carries the event's optional `error`, which we fold into the metadata bag as `error=…`
  (its `localizedDescription` routinely contains newlines → sanitized per gotcha D). **Check the
  swift-log version paired with our Logfmt:** if it predates 1.14, implement the long-form
  signature and we forgo the free `error`.
- **Keep `format(...)` a STATIC pure function** (`timestamp/level/label/message/metadata →
  String`, no I/O, no writer). Then every formatting test exercises it directly with no temp
  files (embedded-newline-stays-one-line, quote/space-escaping, nested-dict dot-flatten,
  msg-not-first-when-a-key-sorts-before-it). Only the writer tests need an injected temp dir.

### 3.8 `FellerBuncher.bootstrap(...)` (entry point)
```
FellerBuncher.bootstrap(
    processName: String,
    logDir: URL,
    // all below default:
    console: ConsoleMode = .osLog,     // .osLog / .stderr / .none (Q2)
    inMemory: Bool = false,            // muse-ios opt-in
    minimumLevel: Logger.Level = .info
)
```
Rotation/prune values (10 MB / keep 5 / 7 days / hourly prune) start as **private constants**
in `FileDestination`, not bootstrap params (Q1). Promote to defaulted params only when a
consumer needs to differ.
- Builds the destinations, installs the handler via `LoggingSystem.bootstrap`.
- **Idempotency**: an `NSLock`-guarded `Bool` wraps the `LoggingSystem.bootstrap` call so
  repeat calls (app + extension calling per-request) are safe no-ops, never a trap (gotcha A).
- **Ordering contract**: documented loudly — bootstrap must run before any `Logger` is
  constructed, because `Logger(label:)` binds its handler at construction, not at log time
  (gotcha B). Recommend bootstrap as the first statement in `AppDelegate.init()` / app entry,
  and lazy `static let` loggers at call sites.
- **Synchronous startup**: bootstrap is fully synchronous and the file/dir is ready before it
  returns, so the first log after bootstrap is guaranteed to land. (muse-ios requirement — to
  be confirmed against their exact needs.)

### 3.9 `Logger` convenience extensions (the only "facade-ish" sugar — feature #5)
swift-log's native metadata API is verbose. Add ergonomic helpers:
```
log.info("wrote", ["bytes": n, "path": url])     // vs swift-log's .stringConvertible boilerplate
log.debug(…) / log.warning(…) / log.error(…)
```
- Take a plain `[String: CustomStringConvertible]` bag; bridge each value to
  `.stringConvertible` via a tiny `Sendable` wrapper that captures `.description` **eagerly**.
- Forward `file/function/line` so source attribution survives.
- **Additive** on the real `Logger` — not a replacement type.

---

## 4. Cross-cutting rules
- **One record = one line.** Sanitization in the formatter is mandatory (gotcha D).
- **Stable field order** for the leading fields, emitted by hand (gotcha C).
- **No I/O on the caller's thread** beyond enqueueing; destinations own their queues.
- **Path-agnostic**: every file path derives from the injected `logDir`.
- **Thread-safety via queue confinement**, `@unchecked Sendable` only where state is provably
  queue-confined.

### 4.1 Concurrency contract (Adam's requirement)
- **The public interface needs NO async/await.** This falls out naturally: swift-log's `Logger`
  API is synchronous and fire-and-forget, `bootstrap(...)` is synchronous, and the convenience
  sugar is synchronous. A pre-concurrency / non-async call site can use the entire logging path
  without ever entering an `async` context. This is the default and the goal.
- **The write path stays fire-and-forget sync.** `write(line)` does `queue.async { performWrite }`;
  the caller (swift-log's sync `log()`) never blocks and never awaits. This is exactly why the
  serial-queue-class-not-actor choice pays off — it satisfies Adam's "no async in the public
  interface" for free. (log-helper confirmed this was 100% synchronous end-to-end in production.)
- **The ONE genuine dual-API surface is `drain`/`flush`** (export is deferred). Provide three shapes:
  1. **Sync `flush()` = `queue.sync {}`** — a barrier that blocks until all prior enqueued writes
     (and init-time prune/open) drain. **Test / known-safe-thread use only.** Document the two
     hazards: calling `queue.sync` from the **main thread** at shutdown risks a priority-inversion
     stall if the writer is mid-large-write; and you must **never** `queue.sync` from inside an
     `async` context (it blocks a cooperative thread-pool thread — a Swift-concurrency no-no).
  2. **Callback form (source of truth):** `func drain(completion: @escaping @Sendable () -> Void)`
     implemented as `queue.async { completion() }` — enqueues a no-op AFTER all pending writes and
     fires when reached. Non-blocking, safe from anywhere (main thread, async context). This is the
     production shutdown/pre-export call.
  3. **async form derived from #2:** `func drain() async { await withCheckedContinuation { c in
     drain { c.resume() } } }`. `drain` doesn't throw → plain `withCheckedContinuation`. Reserve the
     **throwing** continuation (`withCheckedThrowingContinuation`) for `export` if/when it lands.
- **Implementation rule:** write the callback form as the source of truth; derive the `async`
  form from it via a continuation. One code path, two surfaces — they can't drift.
- The internal `DispatchQueue`-confined writer stays as-is (no actors — gotcha N3); the
  async surface is only a wrapper at the public boundary, never in the hot logging path.

### 4.2 Swift 6 / complete concurrency (build clean from day one)
This is a fresh reusable package, so target **Swift 6 language mode / `-strict-concurrency=complete`
from the start** — do NOT inherit log-helper's 5.9-no-strict baseline (the one place their package
is behind where ours should be). The two friction points and their fixes (from log-helper):
- **(a) The `[String: Any]` logfmt bag** in `format(...)` is not Sendable. Keep it strictly **local**:
  build and consume it inside the one synchronous function, and pass only the **already-formatted
  `String`** (Sendable) into `write()`. Never let the `Any` bag escape into the `queue.async` closure.
- **(b) `ISO8601DateFormatter` is not Sendable**, so a `static let` of it warns under complete
  checking. **Use `Date.ISO8601FormatStyle` instead** (a Sendable value type) — it sidesteps the
  warning entirely and is the right choice when targeting Swift 6 from day one. (Fallback only if a
  format gap appears: `nonisolated(unsafe) static let`, justified by configure-once-never-mutate.)
- **(c) No workaround needed for swift-log composition:** `StreamLogHandler` / `MultiplexLogHandler`
  are already `Sendable` in 1.14, and the `LogHandler` protocol is `Sendable` (which is *why* our
  custom handler — and the writer it captures — must be `Sendable`; hence `@unchecked` on the
  queue-confined writer, the canonical, non-smell use of `@unchecked`).

---

## 5. Package layout (target)
```
Package.swift                       # swift-log + adamwulf/Logfmt deps; FellerBuncher lib + test target
Sources/FellerBuncher/
  FellerBuncher.swift               # bootstrap() + public config types
  LogRecord.swift
  LogfmtFormatter.swift
  LogDestination.swift              # protocol
  FileDestination.swift             # rotation + prune
  MemoryDestination.swift           # ring buffer
  ConsoleDestination.swift          # OSLog / stderr
  FellerBuncherLogHandler.swift     # swift-log LogHandler fan-out
  Logger+Convenience.swift          # ergonomic sugar
  # LogExporter.swift               # DEFERRED (Q5): Foundation-only zip plumbing, no UIKit
Tests/FellerBuncherTests/           # inject temp dir
plans/PLAN.md                       # this file
```

---

## 6. Test plan (inject a temp dir — never touch real containers)
- logfmt formatting: stable leading-field order; correct escaping/quoting via String.logfmt.
- Sanitization: `\r\n` + control chars stripped from message AND every metadata value.
- Rotation: file rolls at the size threshold; rotated files shift correctly.
- Rotation fallback: simulated rename failure → truncate-in-place, size bound held.
- Pruning: by count and by age; **active file is never pruned**.
- Bootstrap idempotency: second `bootstrap` call is a safe no-op (no trap).
- Fan-out + filtering: a record goes only to destinations whose filter passes.
- Memory destination: ring buffer caps at capacity; snapshot returns recent records in order.
- Convenience sugar: metadata bag bridged correctly; file/function/line forwarded.

---

## 7. Open questions

**To log-helper — ALL RESOLVED (answers folded into the sections above):**
- ✅ **Q1** Defaults: 10 MB / keep 5 / 7 days / hourly prune guard; start as constants. → §3.4, §3.8.
- ✅ **Q2** Console: `ConsoleMode` enum `.osLog` (default) / `.stderr` / `.none`; OSLog needs
  `privacy: .public`; plus an always-on OSLog breadcrumb channel for writer degradation. → §3.6, §3.8.
- ✅ **Q3** `level=level.rawValue`, all 7 distinct, no collapsing. → §3.2.
- ✅ **Q4** ISO8601 + fractional seconds + UTC `Z`; frozen `static let` formatter. → §3.2.
- ✅ **Q5** Zip = optional package plumbing (deferred); share/save presentation = always the app.
  If built: zip via `NSFileCoordinator(.forUploading)` and **copy the zip INSIDE the coordinator
  accessor block** — Apple unlinks the temp file the instant the block returns, so copying after
  `coordinate()` returns hands back a dead URL. Test that the returned URL is readable AFTER the
  block. Deferred for now — least reusable piece. → see §5 (commented out).

**To muse-ios (interview pending Adam's intro):** what's unique/important in their
SwiftyBeaver setup — in-memory target shape, filtering logs to different destinations,
profiling mode, synchronous startup, and more. → blocks §3.5, refines §3.3/§3.6/§3.7/§3.8.

---

## 8. Phasing
1. **Now:** finalize boundary with log-helper (Q1–Q5), lock this plan.
2. **Interview muse-ios:** fold SwiftyBeaver requirements into §3.3/§3.5/§3.7/§3.8.
3. **Build:** Package.swift → LogRecord/Formatter → destinations → handler → bootstrap → sugar.
4. **Test:** suite per §6 with injected temp dir.
5. **Review cycle**, then offer as the muse-ios SwiftyBeaver replacement.
