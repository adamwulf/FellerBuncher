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
| logfmt formatting (per-destination config) | ✅ formatter | ✅ picks options |
| File writing, rotation (pluggable), pruning | ✅ file destination | ✅ policy/retention |
| In-memory ring buffer + coalesced change hook | ✅ memory destination | ✅ sets callback |
| Console / OSLog mirroring | ✅ console destination | — |
| `LogDestination` protocol + runtime registry | ✅ | ✅ add/remove, custom dests |
| `LogCategory` (the field type) | ✅ | — |
| The category ENUM + its plist codegen | — | ✅ (240 values, app-specific) |
| One-call bootstrap + idempotency + preConfigLogs replay | ✅ | — |
| `effectiveLevel` accessor + change callback | ✅ | ✅ pushes to closed SDKs |
| Dynamic-level entry `custom(level:)` (closure path) | ✅ | ✅ calls it from its closure |
| Routing existing closures in | ✅ doc/pattern only (no type) | ✅ app closure calls the public API |
| Eager thread capture (`ThreadKind`) | ✅ at construction | — |
| Log directory path (per process) | — | ✅ (param) |
| Per-destination level / category include-exclude / force-include | ✅ mechanism | ✅ config |
| Which logger labels + metadata + category to attach | — | ✅ |
| Rate-limit / coalescing | ⏸ not v1 (noted) | ✅ at the source |
| Anonymization (shape-preserving) | ⏸ optional hook point | ✅ call-site transform |
| Remote/error sinks (e.g. Sentry) | ✅ protocol generalizes | ✅ supplies the destination |
| Log zip (plumbing) | ⏸ optional, deferred (Q5) | ✅ collects both dirs |
| Log viewer UI + share/save **presentation** (UIKit) | — | ✅ always app |

---

## 2. Architecture overview

The muse-ios goal (replace a complex SwiftyBeaver setup) forces a **multi-destination** design
from the start. SwiftyBeaver routes one log event to N destinations, each with its own minimum
level, **category include/exclude filters, and its own format**. FellerBuncher mirrors that shape:
a single swift-log `LogHandler` builds one structured `LogRecord` **eagerly on the calling thread**
and fans it out to a **runtime-mutable registry** of `LogDestination`s, each of which **formats the
record itself** with its own formatter config.

```
                                   ┌──────────────────────────────────┐
 log.info(.syncNetwork,"…",[…])    │  FellerBuncherLogHandler          │
   ───────────────────────────────▶│  (swift-log LogHandler)           │
                                   │  - cheap level gate FIRST          │
                                   │  - builds ONE immutable, sanitized │
                                   │    LogRecord (ts, level, label,    │
                                   │    CATEGORY, msg, metadata, source)│
                                   │    eagerly on the CALLING thread   │
                                   │  - fans out to a mutable registry  │
                                   └─────────────────┬─────────────────┘
                                                     │ for each destination:
                                                     │ if passes its level + category filter →
                       ┌─────────────────────────────┼─────────────────────────────┐
                       ▼                              ▼                              ▼
              ┌──────────────────┐         ┌──────────────────┐          ┌──────────────────┐
              │ FileDestination  │         │ MemoryDestination│          │ ConsoleDestination│
              │ serial queue     │         │ ring buffer 5000 │          │ OSLog / stderr   │
              │ OWN formatter +  │         │ OWN formatter,   │          │ OWN formatter,   │
              │ rotation policy  │         │ change-notify hook│         │ OSLog category=  │
              │ + prune          │         │ (in-app viewer)  │          │ from record      │
              └──────────────────┘         └──────────────────┘          └──────────────────┘
   (runtime add/removeDestination — e.g. a feature-flag-gated 2nd "snapshot" FileDestination)
```

**Formatting is PER-DESTINATION (revised after muse-ios input).** There is no single global
formatter: Muse's memory destination uses local-time + padded level while its file uses UTC, and
its file timestamp shape is not even ISO8601. So each destination holds a `LogfmtFormatter`
*configuration* (timestamp style, level style, field selection/order) and formats from the shared
`LogRecord`. Escaping/sanitization is done **once** when the `LogRecord` is built (so it isn't
re-implemented per destination); only field selection + timestamp/level rendering differ per dest.
The memory destination keeps the structured `LogRecord`s (so the in-app viewer can re-filter) and
renders lazily.

**Category is a first-class field on `LogRecord`** (not a metadata key) — it's the destination
filter key, an optional wire-format field, and the OSLog `category:`. See §3.1a.

> Note: the first shipped version may wire up only `FileDestination` (+ optional console), but the
> `LogDestination` protocol, the **mutable registry**, per-destination formatting, and the
> first-class category are built now so muse-ios's in-memory target, runtime snapshot destination,
> category routing, profiling mode, and per-destination format all slot in without a rearchitecture.

---

## 3. Components

### 3.1 `LogRecord` (value type)
Immutable, `Sendable` struct produced once per log call (eagerly, on the calling thread) and shared
(by value) to every destination. Fields:
- `timestamp: Date`, `level: Logger.Level`, `label: String`, **`category: LogCategory`**,
  `message: String`, source attribution (`file/function/line`).
- **`thread: ThreadKind`** (Finding 1) — `.main` / `.background`, sampled via `Thread.isMainThread`
  **at construction on the calling thread**. This MUST be captured eagerly: by the time a
  destination's serial queue formats the record, the thread identity is gone/wrong. Muse renders it
  `[UI]`/`[BG]` in both the file line and the OSLog line; rendering it is a per-destination format
  option, but the *capture* is non-negotiably eager. (Test: a record built on main formats `[UI]`
  even though the destination writes it from a background queue.)
- **`metadata`: the structured bag, rendered ONCE to a Sendable logfmt fragment** (Finding 2 — see
  §3.1b). NOT a re-flattenable `[String: String]` map.

Sanitization (newline/control-char stripping, gotcha D) happens **here, once**, applied recursively
to the structured metadata while rendering its fragment, so destinations never re-sanitize and the
`Any?` bag never crosses a queue/Sendable boundary (reconciles with §4.2).

### 3.1b Metadata model (Finding 2 — the one place the wire format could silently change)
Muse's real context is `[String: Any?]`, NOT `[String: CustomStringConvertible]`: it has **nil
values** (logged as a literal marker, not dropped), **nested dictionaries AND arrays** (e.g.
`Error.loggingContext()` → `["underlying_errors": [[…],[…]], "domain": …, "code": Int]`), and
**self-rendering typed values** via `CustomLogfmtStringConvertible` (`QualifiedId`/`SnowflakeId` →
`hexString`), plus `Bool/Int/Double/CGFloat`. A flattened `[String: String]` cannot express nil or
nesting, and re-serializing a flattened map would create a **second, divergent flattening path**
that drifts from `String.logfmt`.
- **Rule: there is exactly ONE metadata rendering path — `String.logfmt` from the adamwulf/Logfmt
  package** (which already owns dot-flattening of nested dicts, array handling, nil rendering, and
  the `CustomLogfmtStringConvertible`/`Loggable` typed-value machinery). Both producers route through
  it: the **closure bridge** hands Muse's `[String: Any?]` straight to `String.logfmt`, and the
  **convenience sugar** (§3.9, Nit A) uses the same `[String: Any?]` + same renderer — never a
  separate one.
- **Where it renders:** eagerly on the calling thread (where the `[String: Any?]` bag is local), the
  bag is rendered to its sanitized logfmt key=value fragment, and `LogRecord` carries that **string
  fragment** (Sendable). This keeps the bag off the queue boundary (Swift-6 clean) AND guarantees
  byte-identical output to Muse today (single renderer). The per-destination format variation is in
  the **leading scalar fields** (ts/level/label/category/thread/source/msg) + which appear, not in
  how the metadata serializes — so rendering the metadata fragment once is safe.
  - **ASSUMPTION to confirm with muse-log-helper:** no destination needs to render a *subset* of
    metadata keys or serialize the bag differently (the memory viewer "re-filters" by
    level/category/text over the rendered line, it doesn't re-serialize metadata). If a destination
    DID need per-key metadata selection, `LogRecord` would instead carry the structured bag wrapped
    in a `Sendable` box rendered lazily — heavier; only if required.
- **Test:** `Error.loggingContext()` with nested `underlying_errors` (array of dicts) + a nil value
  + a `CustomLogfmtStringConvertible` id renders **identically** through the bridge as through Muse's
  current `String.logfmt` path.

### 3.1a `LogCategory` (first-class routable field — muse-ios requirement)
A lightweight wrapper over `String` (`struct LogCategory: Hashable, Sendable,
ExpressibleByStringLiteral { let rawValue: String }`). The package does **not** own any category
enum — Muse codegen's its ~240-value enum from a plist; the app maps it in by raw value (and via
`.other(String)` escape hatch on their side). Category is used three ways:
- **Destination routing key:** per-destination include-set / exclude-set are sets of `LogCategory`.
  A typed field means filters are set membership, not hot-path dict-lookup-then-string-compare.
- **Optional wire-format field:** destinations may render `category=…` in their line.
- **OSLog `category:`** for the console/OSLog destination: one `os.Logger(subsystem: <constant app
  bundle id>, category: record.category.rawValue)`, cached per category (Muse builds ~240 once). Keyed
  on `record.category`, NOT `record.label` (Nit B) — this is how Console.app filtering works for Muse.

It must be cheap to omit: a `Logger`-only consumer that never supplies a category gets a default
(e.g. derived from `label`, or a sentinel `.default`), so the swift-log-direct path is unaffected.

### 3.2 `LogfmtFormatter` (a per-destination CONFIG, not one global formatter)
Each destination holds a `LogfmtFormatter` value configuring how it renders a `LogRecord` to one
line (newline-terminated). It is still a pure `LogRecord -> String` function, but **parameterized**:
- **Timestamp style** (per-destination — muse-ios requirement): `.iso8601` (package default, see
  below) | `.custom(...)` so Muse's file keeps its exact current shape `YYYY-MM-dd HH:mm:ss.SSS`
  UTC (space sep, no T, no Z) and its memory dest uses local time. **The ISO8601 default already
  differs from Muse's current shape**, so this MUST be overridable per destination or Muse's greps
  break (muse-log-helper's catch).
  - **Hard constraint on Muse's custom style:** their in-app viewer grays out characters `0..<24`
    of every line assuming that's the timestamp, so the custom timestamp must be **exactly 24
    chars** (`2026-06-27 12:34:56.789`). The leading field for that destination must be the raw
    timestamp (no `ts=` key prefix) to preserve the 24-char offset. → cover with a test.
- **Level style:** `.raw` (default — `level.rawValue`) | `.paddedUppercase` (Muse memory uses
  `$-5L`-style padding). All 7 levels stay distinct, no collapsing (Q3).
- **Field selection + order:** which of `ts/level/label/category/source/msg/metadata` appear.
- Shared invariants regardless of config:
- Emit **fixed leading fields by hand** in a stable order (e.g. `ts=… level=… label=… category=…`)
  (`String.logfmt` sorts keys alphabetically, so we cannot rely on it for field order — gotcha C).
- Append the message + metadata by handing **one dict** to `String.logfmt` (`["msg": …, …meta]`).
- Sanitize: strip `\r`/`\n` and other control chars from the message and every metadata value
  before formatting, so one record is always exactly one line (gotcha D).
- `level=` tokens: emit `level.rawValue` directly — all 7 distinct, **no collapsing**
  (`trace debug info notice warning error critical`). `grep 'level=error'` just works.
  Collapsing `notice→info` would throw away a level a consumer deliberately chose. (Q3)
- `ts=` **default** format (the `.iso8601` style; per-destination overridable per above):
  **ISO8601 with fractional seconds, UTC, `Z`-suffixed** → `ts=2026-06-27T12:34:56.789Z`.
  Sortable (lexical == chronological) + human-readable. (Q4)
  - **Use `Date.ISO8601FormatStyle` (Sendable value type), NOT `ISO8601DateFormatter`.** Going
    Swift 6 / complete-concurrency from day one (see §4.2), a `static let ISO8601DateFormatter`
    (non-Sendable) warns; the format style sidesteps it entirely and is the right modern choice.
    Configure `.year().month().day()...`/`includingFractionalSeconds: true` with `timeZone: .gmt`
    (or the `ISO8601FormatStyle(...)` initializer with fractional seconds + UTC). Pin UTC
    explicitly so logs from different zones sort and correlate.
  - log-helper's reference used a frozen `static let ISO8601DateFormatter` (safe under their 5.9
    baseline because configure-once-never-mutate); we improve on it with the value-type style.
  - **Byte-identical requirement:** the format-style output MUST exactly match the
    `ISO8601DateFormatter` shape (`.withInternetDateTime` + `.withFractionalSeconds` + UTC `Z`) —
    same fractional-digit count, separators, and `Z` suffix — so the Sendable switch doesn't change
    the wire format and break existing greps/tooling. Locked by a regression test (see §6).

### 3.3 `LogDestination` (protocol) + the mutable registry
```
protocol LogDestination: AnyObject, Sendable {
    var id: ObjectIdentifier { get }              // for removeDestination
    var minimumLevel: Logger.Level { get }
    var includeCategories: Set<LogCategory>? { get } // nil = all; non-nil = ONLY these
    var excludeCategories: Set<LogCategory> { get }  // always dropped (e.g. ephemeral_update)
    func shouldLog(_ record: LogRecord) -> Bool   // level + category include/exclude + force-include
    func receive(_ record: LogRecord)             // must be cheap / non-blocking for caller
}
```
- **Per-destination filtering** (the crux for muse-ios): level + category **include-set** AND
  **exclude-set**, both keyed on the typed `LogCategory`. Main file excludes `ephemeral_update`;
  the snapshot file includes only its ~15 categories.
- **Force-include for below-level tracing:** `shouldLog` may accept a record *below* the global
  level when its category/source matches a per-destination allowlist (Muse's always-on tracing of
  hot subsystems like `AsyncBoardRenderer`, `SnapshotTileProvider`).
- Each destination is a **class** (so Muse can conform its own `MemoryDestination` with a custom
  `receive`/send, replacing their SwiftyBeaver `BaseDestination` subclass) and holds its own
  `LogfmtFormatter` config.

**`DestinationRegistry` (runtime-mutable):** the handler fans out to a lock-guarded mutable set of
destinations supporting `addDestination(_:)` / `removeDestination(_:)` at runtime with no relaunch
(Muse's `FeatureFlagChanged` observer toggles the snapshot `FileDestination` live). The lock is
held only to copy the current destination list; fan-out happens outside the lock so a slow
destination can't block registration. This is the seam that maps SwiftyBeaver's `addDestination`.

### 3.4 `FileDestination` (the gnarly one)
Class, private serial `DispatchQueue`, `@unchecked Sendable`. Writes formatted lines to
`logDir/<processName>.log`. Holds its own `LogfmtFormatter` config (Muse's file uses a custom
timestamp; the snapshot file is a second instance with its own include-set).
- **Rotation policy is PLUGGABLE** (muse-ios rotates by calendar day, log-helper by size):
  `RotationPolicy = .size(bytes:) | .dateStamped(granularity:zone:) | .none`. Default `.size(10 MB)`.
  - `.size` (numbered siblings): rename `app.log → app-1.log` (shift rotated files up).
    **Truncate-in-place fallback** if the rename fails, so the size bound always holds and we don't
    trip rotation on every subsequent write (gotcha F). Checked **before** each write → overshoot
    bounded to one record.
  - `.dateStamped` (DATE-IN-FILENAME — Muse's real model, corrected from "minute" per Q-E): the
    active filename embeds the date, e.g. `Muse-App-2026-06-27.log` (`yyyy-MM-dd`, **UTC**). Rotation
    = **roll at the UTC day boundary**, detected by **computed-filename-differs**, not a midnight timer.
    - **No mandatory internal timer (Nit C).** The destination checks "does today's computed filename
      differ from the open file's name?" cheaply **on every `receive()`** (format a Date, compare a
      string) and swaps if so — so the **next write after midnight rolls naturally**, and a cold launch
      the next day opens the fresh dated file on first write. It also exposes an **idempotent
      `rollIfDateChanged()`** the APP may call on any cadence (Muse pokes it ~1/min as
      belt-and-suspenders for a process that's idle across midnight). Cadence is the app's choice; the
      package does not own a Timer.
    - No numbered siblings; pruning is purely age-based over the dated files. Granularity is
      parameterized (`.day` for Muse; could support `.hour`) but the alignment is **calendar**.
- **Pruning**: enforce max rotated-file count and/or max age, **never deleting the active
  file** (APFS keeps an unlinked-but-open file alive only for its holder → silent writes into
  an unreachable inode → data loss). Skip `activeURL` in the prune sweep (gotcha E). Pruning
  is **per-directory** — each process prunes its OWN dir at startup (off-main); no cross-process
  prune coordination (Q-D: the zip step just *collects* both dirs read-only). Prune date field is
  configurable: log-helper uses `contentModificationDate`, Muse uses `creationDate` (3-week cutoff,
  matters for date-stamped files that are written-then-idle).
- **Defaults (Q1):**
  - `maxFileBytes = 10 MB` per active file (`.size` policy)
  - `rotatedFilesToKeep = 5` (`app-1.log` … `app-5.log`; oldest dropped) → worst case ≈ 60 MB/process
  - **`maxFileAge` = 7 days default** (log-helper); Muse overrides to **21 days** (3 weeks). So
    retention is a per-FileDestination param, not a hard constant — promote this one (the two real
    consumers already differ). The rest (`maxFileBytes`, `rotatedFilesToKeep`, `pruneInterval`)
    start as constants, promoted only when a consumer needs to differ.
  - `pruneInterval = 1 hour` — **the non-obvious one**: re-check prune at most hourly so a
    chatty process doesn't `stat` the whole directory on every log line. Do not skip it. (Muse also
    prunes once at startup off-main, which fits the `force: true` init-time prune in the reference.)

### 3.5 `MemoryDestination` (for muse-ios in-memory target)
Fixed-capacity ring buffer of recent `LogRecord`s behind a small lock, **O(1) drop-oldest**,
default capacity **5000** (Muse's cap; configurable). Stores structured `LogRecord`s (not pre-
formatted lines) so the in-app viewer can re-filter and render lazily with its own formatter config.
- **Change-notification hook (Q-B decided):** a single coalesced `@Sendable () -> Void` callback
  (`onChange`) the viewer sets on appear / nils on disappear. The destination does its own
  coalescing (a needs-refresh gate) so a burst of logs yields one UI refresh. No Combine /
  async-stream / multi-observer needed (Muse uses exactly one observer); a single callback +
  coalescing is what they have and is sufficient.
- Peer destination with its **own** min-level + category filters + formatter (Muse's memory format
  differs from file: local time, padded level).

### 3.6 `ConsoleDestination` (Q2 — decided)
Dev-time visibility. Expose a **`ConsoleMode` enum: `.osLog` (default) / `.stderr` / `.none`**.
- `.osLog` (default on Apple platforms): write a small `OSLogDestination` that emits the
  **same formatted logfmt line** at the mapped os level via an `os.Logger` cached **per
  `record.category`** (subsystem = a constant app bundle id; category = `record.category.rawValue`,
  NOT `label` — Nit B). Muse pre-builds ~240 such loggers; we cache lazily on first use per category.
  This is a genuinely better default than stderr when consumers live in Xcode/Console.app — proper
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
References the shared `DestinationRegistry` + the per-logger `logLevel`/`metadata` swift-log
requires. On a log call: **cheap level-gate first** (`guard self.logLevel <= level`) BEFORE building
anything, then build the `LogRecord` once (eagerly, sanitized, with category) and fan out to each
registry destination that passes its level + category filter. The handler is cheap; destinations
own their own threading. The level gate must be cheap enough to leave log calls inline in hot
render/ink paths (muse-ios requirement) — it's a single comparison before any allocation.
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

### 3.8 `FellerBuncher.bootstrap(...)` (entry point) → returns a `LoggingHandle`
```
@discardableResult
FellerBuncher.bootstrap(
    processName: String,
    logDir: URL,
    // all below default:
    console: ConsoleMode = .osLog,     // .osLog / .stderr / .none (Q2)
    inMemory: Bool = false,            // muse-ios opt-in
    minimumLevel: Logger.Level = .info
) -> LoggingHandle
```
Rotation/prune values (10 MB / keep 5 / hourly prune; retention 7d default) start as **constants**
in `FileDestination` (Q1), except retention which is a param (the two consumers differ: 7d vs 21d).
- Builds the destinations + registry, installs the handler via `LoggingSystem.bootstrap`.
- **Idempotency**: an `NSLock`-guarded `Bool` wraps the `LoggingSystem.bootstrap` call so
  repeat calls (app + extension calling per-request) are safe no-ops, never a trap (gotcha A).
- **preConfigLogs replay (muse-ios, supersedes the strict "bootstrap-first" rule):** records
  emitted before bootstrap are captured in a small bounded buffer by a lightweight bootstrap-time
  handler and **replayed into the destinations once they exist, tagged `late=true`** — so early
  startup logs are never lost even though `Logger(label:)` binds its handler at construction
  (gotcha B). We still recommend bootstrapping early, but replay removes the silent-data-loss
  failure mode. (The bootstrap-first rule stays the documented happy path; replay is the safety net.)
- **Synchronous startup**: bootstrap is fully synchronous and the file/dir is ready before it
  returns, so the first log after bootstrap is guaranteed to land.

**`LoggingHandle` (the returned control surface):**
- `addDestination(_:)` / `removeDestination(_:)` — runtime registry mutation (Muse's feature-flag
  snapshot toggle). `removeDestination` drains the destination before teardown (covers Q-C's
  `flush(secondTimeout:)` use without needing a separate timeout API).
- **`effectiveLevel` (get) + `onEffectiveLevelChange` callback (muse-ios "single sink"):** so the
  app can push level changes into **closed SDKs** (Setapp, Sparkle) whose own level setters Muse
  slaves to the logger's level. Setting the level updates the handler(s) and fires the callback.
- `drain(...)` (sync / callback / async per §4.1) — also exposed for dependency-driven flush
  (Muse wires `LogContext.flushLog = { handle.drain {} }`).

### 3.9 `Logger` convenience extensions (the only "facade-ish" sugar — feature #5)
swift-log's native metadata API is verbose. Add ergonomic helpers:
```
log.info("wrote", ["bytes": n, "path": url])     // vs swift-log's .stringConvertible boilerplate
log.debug(…) / log.warning(…) / log.error(…)
log.custom(level: lvl, …)                        // DYNAMIC level — required by the closure path (§3.10)
```
- **Dynamic-level entry (required):** alongside the four fixed-level helpers, expose
  `custom(level:category:_:metadata:file:function:line:)` taking `level` as a runtime value. This is
  what an app's existing closure-based logger calls from inside its closure (the closure receives
  `level` at runtime). Mirrors Muse's `log.custom(level:…)`. Without it, the only dynamic-level path
  is swift-log's `Logger.log(level:_:metadata:source:)` — fine, but the sugar should offer parity.
- All helpers also accept an optional `category:` so the closure path can supply it.
- Take a `[String: Any?]` bag rendered through the **same `String.logfmt` path** as the closure
  bridge (Nit A) — NOT a separate `[String: CustomStringConvertible]` renderer. One renderer for
  both producers means the sugar and the bridge can't drift (the in-miniature version of Finding 2).
  This keeps nil values, nesting, and `CustomLogfmtStringConvertible` typed values working in the
  sugar too. Values are rendered eagerly on the calling thread (so the `Any?` bag stays local and
  Sendable-clean per §4.2).
- Forward `file/function/line` so source attribution survives.
- **Additive** on the real `Logger` — not a replacement type.

### 3.10 Routing existing closure-based loggers in (doc note — NOT a shipped type)
**Today LogDriver and SwiftToolbox do NOT use swift-log** — they emit through an app-installed
closure (`LogContext.logHandler = { level, msg, file, func, line, context in … }`,
`SwiftToolbox.logHandler = { … }`). The same is true of the closed SDKs (Setapp/Sparkle) and the
Sentry error path.

**Decision (Adam): there is NO `ClosureHandlerBridge` package TYPE — it was over-engineering.**
To route an existing closure-based logger into FellerBuncher, the **app's own closure body calls
FellerBuncher's public log entry point directly** — mapping the runtime `level`, supplying a
`category`, and handing `context` as the metadata bag — exactly as Muse's facade does today. That's
app code calling a public API; the package ships no dedicated "receiver" type. (Bonus: the eager
on-calling-thread capture of thread identity + metadata render happens naturally, because the app's
closure call site *is* the calling thread.)

The **multiple-producers mental model still holds** (a closure is a producer of records), but the
producer is plain app code, not a package type. So the **only** API affordance this requires:
- **A DYNAMIC-LEVEL public log entry** — the closure receives `level` as a runtime value, so the
  fixed-level `.debug/.info/.warning/.error` sugar is not enough on its own. Provide a
  `custom(level:category:_:metadata:…)` variant (mirrors Muse's `log.custom(level:…)`), or document
  using swift-log's `Logger.log(level:_:metadata:source:)` directly. This is the one thing the
  dropped bridge type was implicitly providing → see §3.9.

Scope (Adam, Path A): Muse migrates its call sites onto FellerBuncher over time; **LogDriver/
SwiftToolbox migrate to native swift-log LATER, separately** — no package-migration tasks in this
effort. Architecture is unchanged either way.

### 3.11 Non-file destinations as proof the design generalizes (muse-ios Finding #3b)
Muse forks **error-level** records to **Sentry** (`SentrySDK.capture`) with typed context mapped
(e.g. `QualifiedId.hexString`) and file/func/line as extras. This is just another `LogDestination`:
a `SentryDestination` with `minimumLevel = .error` and a value transform. Naming it here is the
proof that the per-destination + typed-category/context design generalizes beyond files
(file / memory / OSLog / **remote error sink** all conform to the same protocol + registry). The
package ships the protocol + registry; the app supplies app-specific destinations like Sentry.

### 3.12 Rate-limit / coalescing (muse-ios Finding #3a — note, likely app-owned)
Muse throttles spammy sources via `LogContext.logInterval = 1.0` (≤1 msg/sec from very-verbose
LogDriver). Today this lives in LogDriver, not the logger. **Decision: keep throttling app/producer-
owned for v1** (it belongs at the source, before a record is built, so it also saves record-building
cost). But the design must **not fight it**: the cheap level-gate-first + per-destination filters
compose with an upstream throttle. If feature-parity is later wanted in-package, a per-category /
per-source token-bucket predicate slots in as a filter stage — noted, not built.

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
- **(a) The `[String: Any?]` metadata bag** is not Sendable. Render it to its sanitized logfmt
  fragment **eagerly on the calling thread** (where it's local) and have `LogRecord` carry that
  **Sendable string fragment** (§3.1b), never the bag. The leading scalar fields stay structured for
  per-destination formatting, but they're all Sendable value types. So the `Any?` bag is consumed
  before any `queue.async` boundary and never crosses it — Swift-6 clean by construction.
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
  FellerBuncher.swift               # bootstrap() -> LoggingHandle + public config types
  LoggingHandle.swift               # control surface: add/removeDestination, effectiveLevel, drain
  LogRecord.swift                   # value type; sanitized once; category + ThreadKind + source + rendered-metadata fragment
  LogCategory.swift                 # first-class routable field (String wrapper, app maps its enum)
  LogfmtFormatter.swift             # per-destination CONFIG (ts style, level style, thread, fields); ONE metadata renderer via String.logfmt
  LogDestination.swift              # protocol (level + category include/exclude + force-include)
  DestinationRegistry.swift         # runtime-mutable, lock-guarded fan-out target
  FileDestination.swift             # serial queue; pluggable RotationPolicy (.size/.dateStamped, app-poked rollIfDateChanged); prune
  MemoryDestination.swift           # ring buffer 5000, O(1) drop-oldest, coalesced onChange
  ConsoleDestination.swift          # OSLog (os.Logger cached per CATEGORY) / stderr
  FellerBuncherLogHandler.swift     # swift-log LogHandler: level-gate, build record, fan out
  Logger+Convenience.swift          # ergonomic sugar (debug/info/warning/error + custom(level:) + [String:Any?] bag)
  # NOTE: NO ClosureHandlerBridge type (dropped) — apps route existing closures by calling custom(level:) (§3.10)
  # LogExporter.swift               # DEFERRED (Q5): Foundation-only zip plumbing, no UIKit
  # SentryDestination.swift         # APP-OWNED example, not shipped — proof the protocol generalizes
Tests/FellerBuncherTests/           # inject temp dir
plans/PLAN.md                       # this file
```

---

## 6. Test plan (inject a temp dir — never touch real containers)
- logfmt formatting: stable leading-field order; correct escaping/quoting via String.logfmt.
- **Timestamp wire-format lock (regression guard):** assert `Date.ISO8601FormatStyle` output is
  **byte-identical** to `ISO8601DateFormatter` with `[.withInternetDateTime, .withFractionalSeconds]`
  + UTC `Z` for a fixed sample date (e.g. exactly `2026-06-27T12:34:56.789Z`: same fractional-digit
  count, same separators, same `Z` suffix). The Sendable switch (§3.2/§4.2) must NOT silently change
  the wire format, or existing logfmt greps/tooling break. (log-helper flagged this as the one place
  the format could drift.)
- Sanitization: `\r\n` + control chars stripped from message AND every metadata value.
- **Eager thread capture (Finding 1):** a record built on the **main thread** formats as `[UI]` even
  when the destination writes it from its **background** queue (proves `Thread.isMainThread` is
  sampled at construction, not at format time).
- **Metadata wire-fidelity (Finding 2):** `Error.loggingContext()` with nested `underlying_errors`
  (array of dicts) + a nil value + a `CustomLogfmtStringConvertible` id renders **identically**
  through the public entry as through Muse's current `String.logfmt` path (single renderer, no
  divergent flatten). Also: the sugar (`[String: Any?]`) and the closure path produce the same bytes
  for the same bag (one renderer, Nit A).
- **Per-destination format:** two destinations render the same `LogRecord` differently (one ISO8601
  UTC, one custom local-time padded-level + `[UI]/[BG]` thread) — verify each formatter config
  independently (pure func).
- **24-char timestamp constraint:** Muse's `.custom` style emits exactly 24 chars
  `2026-06-27 12:34:56.789` as the leading field (no `ts=` prefix) so the viewer's `0..<24` gray-out holds.
- `.size` rotation: file rolls at the size threshold; rotated siblings shift correctly.
- `.size` rotation fallback: simulated rename failure → truncate-in-place, size bound held.
- **`.dateStamped` rotation:** filename embeds UTC date; the swap is driven by **"today's computed
  filename differs from the open file's name,"** NOT by a timer assuming the app was alive at midnight.
  - **Cold-launch-after-day-boundary (muse-log-helper's locked test):** simulate a launch at e.g. 2pm
    the day *after* the last write — the first write must open the new dated file, with **nothing lost
    to yesterday's file**. This is the failure mode poll-and-swap exists to prevent.
- Pruning: by count and by age; **active file is never pruned** (gotcha E); per-directory only.
- Bootstrap idempotency: second `bootstrap` call is a safe no-op (no trap).
- **preConfigLogs replay:** records emitted before bootstrap replay into destinations tagged `late=true`.
- Fan-out + filtering: a record goes only to destinations whose level + category include/exclude passes.
- **Category routing:** include-set admits only its categories; exclude-set drops (e.g. ephemeral_update);
  **force-include** admits a below-global-level record for an allowlisted category/source.
- **Runtime registry:** add/removeDestination mid-stream changes where subsequent records land;
  removeDestination drains before teardown.
- **effectiveLevel:** changing it updates the handler and fires `onEffectiveLevelChange`.
- Memory destination: ring buffer caps at 5000, O(1) drop-oldest; snapshot in order; coalesced onChange fires.
- **Closure path:** a record produced by calling `custom(level:category:metadata:…)` (as an app's
  closure would) lands in the registry identically to one from the swift-log handler — and a dynamic
  `level` passed as a value routes/filters correctly.
- **OSLog per-category:** the OSLog destination caches one `os.Logger` per `record.category` (not per
  label); two records with different categories use different loggers.
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

**To muse-ios (muse-log-helper) — ALL RESOLVED (folded into sections above):**
- ✅ **Q-A** Per-destination format: OPTIONS suffice (ts style, level style/padding, field order/
  presence, separator) — no $-token template DSL. Viewer colors by regex over the logfmt line. → §3.2.
- ✅ **Q-B** Memory change hook: a single coalesced `@Sendable () -> Void` callback. → §3.5.
- ✅ **Q-C** Flush: drain-to-completion (sync/callback/async); timeout NOT load-bearing if
  removeDestination drains first. `flush` is dependency-driven (`LogContext.flushLog`). → §3.8, §4.1.
- ✅ **Q-D** Cross-process: collect-at-zip; each process prunes its OWN dir; no cross-dir prune. → §3.4.
- ✅ **Q-E** Rotation = **UTC calendar-day** dated filename (`Muse-App-yyyy-MM-dd.log`), poll-and-swap
  (1-min poll detects the midnight boundary); minute is the poll, not the boundary. → §3.4 `.dateStamped`.
- New findings folded: routing-closures-via-public-API doc note (§3.10, NO bridge type — dropped per
  Adam), Sentry-as-destination proof (§3.11), rate-limit/coalescing app-owned for v1 (§3.12), 24-char
  timestamp viewer constraint (§3.2).

**Review-pass findings (muse-log-helper, all folded):** Finding 1 — eager `ThreadKind` capture (§3.1).
Finding 2 — single `String.logfmt` metadata renderer over `[String: Any?]`, `LogRecord` carries the
rendered fragment, no divergent flatten (§3.1b). Nit A — sugar uses the same renderer/`[String: Any?]`
(§3.9). Nit B — OSLog `os.Logger` cached per CATEGORY (§3.6). Nit C — `.dateStamped` has no internal
timer; cheap check on every `receive()` + app-poked `rollIfDateChanged()` (§3.4).

**Adam's decisions (folded):** (1) **Scope = Path A** — Muse migrates its call sites over time;
LogDriver/SwiftToolbox go native swift-log LATER, separately; **no package-migration tasks here**.
(2) **No `ClosureHandlerBridge` type** — apps route existing closures by calling the public
`custom(level:…)` from inside their own closure (§3.10); the one required affordance is a
dynamic-level entry (§3.9).

**Remaining muse-ios invariants to honor (not questions — design constraints):** 240 build-time
categories (app-owned enum), the logfmt context contract with self-rendering typed values
(`QualifiedId.hexString`), per-destination category routing, synchronous-cheap-when-disabled calls.

---

## 8. Phasing
1. ✅ Finalize boundary with log-helper (Q1–Q5) — done.
2. ✅ Interview muse-ios (muse-log-helper), fold requirements (Q-A–Q-E + findings) — done.
3. **Build:** Package.swift → LogCategory/LogRecord(+ThreadKind)/Formatter → LogDestination/registry →
   File/Memory/Console destinations → handler → bootstrap/LoggingHandle → sugar (incl. `custom(level:)`).
   (No closure-bridge type — §3.10 is a doc note.)
4. **Test:** suite per §6 with injected temp dir.
5. **Review cycle** (log-helper: generic A–F + Swift-6; muse-log-helper: muse-ios reality), then
   offer as the muse-ios SwiftyBeaver replacement.

**Muse cutover sequencing (DECIDED — Adam, Path A):**
- Land FellerBuncher in Muse with **ZERO behavior change** to LogDriver/SwiftToolbox (their existing
  closures call FellerBuncher's `custom(level:…)` directly — no package change). The Muse cutover is
  already big on its own (SwiftyBeaver→FellerBuncher under Muse's facade, re-implement MemoryDestination
  on our protocol, port the snapshot runtime toggle + daily dated rotation, wire SentryDestination,
  preserve the 24-char wire format). Prove the log files + support bundles + in-app viewer + Sentry are
  byte-for-byte as expected.
- **THEN**, as a separate follow-up, migrate LogDriver/SwiftToolbox to native swift-log — observable
  change is only "same records arrive via a different producer." "Slow is smooth, smooth is fast."
- **No package-migration tasks in THIS effort.** Architecture is identical either way.
