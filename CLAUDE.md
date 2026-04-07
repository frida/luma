# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when
working with code in this repository.

## Build Commands

```sh
make          # Incremental release build via xcodebuild → build/Luma.app
make clean    # Remove build artifacts
```

Or open `Luma.xcodeproj` in Xcode and build with Cmd+B (set
destination to **My Mac**).

`LumaCore` (the cross-platform Swift package) can be built and
type-checked on Linux without Xcode:

```sh
swift build --target LumaCore
```

There are no tests or linting commands. Code formatting follows
`.swift-format` (4-space indent, 140-char line length).

Avoid "headline comments" that narrate what the next block does.
Prefer aptly named variables and functions to make code
self-explanatory. Only add comments as a last resort, for
non-obvious *why* (hidden constraints, workarounds).

## Architecture

Luma is an interactive dynamic instrumentation app built on
[Frida](https://frida.re). All business logic lives in **LumaCore**,
a portable Swift package. The current shipping frontend is a macOS
SwiftUI app; a GTK/Adwaita frontend for Linux can be added against
the same `LumaCore`.

```
+-----------------------------+      +---------------------------+
|  SwiftUI frontend (macOS)   |      |  GTK frontend (Linux)     |
|  Luma/                      |      |  (planned)                |
+--------------+--------------+      +-------------+-------------+
               |                                   |
               +---------------+-------------------+
                               |
                  +------------v-------------+
                  |        LumaCore          |
                  |   (Swift package, all    |
                  |    business logic)       |
                  +------------+-------------+
                               |
                +--------------+--------------+
                |              |              |
          frida-swift      SwiftyR2       GRDB.swift
                               |
                  +------------v-------------+
                  |   Agent (TypeScript)     |
                  |   compiled & embedded    |
                  +--------------------------+
```

### Two-process model

1. **Host (Swift)** — owns the UI, persistence, and Frida session
   lifecycle (via `LumaCore`).
2. **Agent (TypeScript)** — compiled JS injected into the target
   process via Frida. Exposes RPC methods for instrumentation, REPL
   evaluation, memory access, and symbolication.

The agent entry point is `Agent/core/luma.ts`, which re-exports all
RPC methods from sibling modules. Agent source is compiled and
embedded into `Sources/LumaCore/Generated/LumaAgent.swift` by the
`LumaBundleCompiler` build tool target. The `Generated/` directory
is gitignored — it is produced at build time.

### LumaCore (`Sources/LumaCore/`)

- **`Engine`** — central `@Observable @MainActor` class. Owns the
  `DeviceManager`, all `ProcessNode` instances, the event log,
  `CollaborationSession`, `GitHubAuth`, `HookPackLibrary`, the
  `Disassembler` cache, address annotations, the descriptor
  registry, and the address-action provider list. Single public
  entry point: `start()` (called from the host once at launch).
- **`ProcessNode`** — represents one attached process. Holds the
  Frida `Session` + `Script`, loaded modules, and `InstrumentRef`s.
  Exposes `AsyncStream` event sources (events, REPL results, ITrace
  captures, module snapshots, detach events).
- **`EventLog`** — `@Observable` ring buffer with batched 16ms
  flushing. Frontends read `events` / `totalReceived` directly via
  Observation; no mirror in the host.
- **`Disassembler` / `TraceDisassembler`** — concrete `@MainActor`
  classes wrapping `R2Core` for live and trace disassembly. Both
  return portable `DisassemblyLine` / `StyledText` (RGB-spans, no
  AppKit/SwiftUI dependency). Frontends ship a tiny extension to
  convert `StyledText` into their preferred styled-text type.
- **`HookPackLibrary`** — discovers hook packs from a directory and
  produces `InstrumentDescriptor`s. Engine owns one rooted at
  `dataDirectory/HookPacks`.
- **`AddressAction`** — pluggable per-address action providers.
  The tracer registers itself at engine init; future instrument
  kinds can call `engine.registerAddressActionProvider`.
- **Persistence (GRDB / SQLite)** — `ProjectStore` with
  `ProcessSession`, `InstrumentInstance`, `REPLCell`,
  `NotebookEntry`, `ITraceCaptureRecord`, `AddressInsight`,
  `RemoteDeviceConfig`, `ProjectPackagesState`, `InstalledPackage`,
  `ProjectCollaborationState`, `TargetPickerState`. Schema
  migrations live in `migrator` inside `ProjectStore.swift`.
- **`CollaborationSession`** — portal bus, rooms, notebook sync,
  chat. `GitHubAuth` is a separate `@Observable` actor that owns
  the OAuth device flow and token storage; `Engine.startCollaboration`
  awaits `gitHubAuth.requestToken()`, which suspends until the host
  finishes presenting the sign-in sheet.

### Host (`Luma/`)

- **`Workspace`** — thin host adapter. Owns `Engine`, exposes a few
  UI-only flags (`targetPickerContext`, `isCollaborationPanelVisible`,
  `monacoFSSnapshot`), wires the SwiftUI instrument-UI registry,
  and provides `processNode(for: event)` / `instrument(for: event)`
  / `sidebarItem(for: NavigationTarget)` lookup helpers.
- **`MainWindowView`** — top-level SwiftUI view; splits into
  sidebar (process/instrument list) and detail area.
- **`Luma/Instruments/`** — per-instrument SwiftUI factories
  (`TracerUI`, `HookPackUI`, `CodeShareUI`), the `InstrumentUI`
  protocol, the `InstrumentUIRegistry` dispatcher, and
  `InstrumentEventMenuItem`.
- **`Luma/Editor/`** — SwiftyMonaco glue: `TypeScriptEnvironment`,
  `CodeShareEditorProfile`, `TracerEditorProfile`.
- **`StyledTextSwiftUI.swift`** — host-side conversion of
  `LumaCore.StyledText` to `AttributedString` (SwiftUI) and
  `NSAttributedString` (AppKit / Metal CFG renderer).

### Dependencies (Swift Package Manager)

- `frida-swift` — Frida bindings
- `SwiftyR2` — Radare2 integration (used inside `LumaCore` for
  disassembly)
- `GRDB.swift` — SQLite persistence
- `swift-crypto` — collaboration crypto
- `SwiftyMonaco` — Monaco code editor component (host only)

### Agent modules (`Agent/`)

`Agent/core/` contains the RPC modules: `env`, `instrument`,
`memory`, `repl`, `resolver`, `symbolicate`, `console`, `pkg`,
`value`. Built-in instruments live in `Agent/instruments/`
(e.g. `tracer.ts`, `codeshare.ts`).

## Commit Style

- Subject line: max 50 characters
- Body lines: wrap at 72 characters (use the full width, or
  slightly less if it avoids making the next line awkward)

## Requirements

- macOS 15.6+
- Xcode 26+
