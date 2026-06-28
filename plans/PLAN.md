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
| Log export / share flow | TBD (see Q5) | TBD |

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
- `level=` tokens: stable strings for all 7 swift-log levels. **PENDING Q3** (match log-helper's
  exact strings for grep-compatibility; decide whether to collapse e.g. `notice→info`).
- `ts=` format. **PENDING Q4** (leaning ISO8601 with fractional seconds + `Z`).

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
- **Pruning**: enforce max rotated-file count and/or max age, **never deleting the active
  file** (APFS keeps an unlinked-but-open file alive only for its holder → silent writes into
  an unreachable inode → data loss). Skip `activeURL` in the prune sweep (gotcha E).
- Defaults (size MB / max files / max age days): **PENDING Q1** (match log-helper unless reason not to).
- Keeps a running byte count to avoid `stat`-ing on every write.

### 3.5 `MemoryDestination` (for muse-ios in-memory target)
Fixed-capacity ring buffer of recent `LogRecord`s behind a small lock/queue. Exposes a
snapshot accessor for an in-app log viewer / export. Capacity configurable. **Details PENDING
muse-ios interview** (size, whether it stores records or formatted lines, thread-safety needs).

### 3.6 `ConsoleDestination`
Dev-time visibility. **PENDING Q2**: plain `stderr`/`print` vs. mirroring to `os.Logger`/OSLog
so it appears in Xcode + Console.app with proper levels. Current lean: offer **OSLog mirroring**
as the default console for Apple platforms, with a stderr option for non-Apple/CLI.

### 3.7 `FellerBuncherLogHandler` (swift-log `LogHandler`)
Holds the destination set + the per-logger `logLevel`/`metadata` swift-log requires. On
`log(...)`: build a `LogRecord` once, fan out to each destination that passes its filter. The
handler itself is cheap; destinations own their own threading.

### 3.8 `FellerBuncher.bootstrap(...)` (entry point)
```
FellerBuncher.bootstrap(
    processName: String,
    logDir: URL,
    // all below default:
    fileRotationBytes: Int = …,        // PENDING Q1
    maxRotatedFiles: Int = …,          // PENDING Q1
    maxLogAgeDays: Int = …,            // PENDING Q1
    console: ConsoleMode = …,          // PENDING Q2
    inMemory: Bool = false,            // muse-ios opt-in
    minimumLevel: Logger.Level = .info
)
```
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

## 7. Open questions (blocking the marked components)

**To log-helper (asked, awaiting answers):**
- **Q1** Default rotation size (MB), max rotated files, max age (days). → blocks §3.4, §3.8.
- **Q2** Console echo: stderr/print vs OSLog mirroring (or both). → blocks §3.6, §3.8.
- **Q3** `level=` token strings for all 7 swift-log levels; any collapsing. → blocks §3.2.
- **Q4** `ts=` format (ISO8601 w/ fractional + Z?). → blocks §3.2.
- **Q5** Is the log exporter (zip/share) part of the **package** or the **app**? → blocks layout.

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
