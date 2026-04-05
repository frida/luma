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

There are no tests or linting commands. Code formatting follows
`.swift-format` (4-space indent, 140-char line length).

## Architecture

Luma is a macOS SwiftUI application for interactive dynamic
instrumentation using the [Frida](https://frida.re) framework. It
is a document-based app (SwiftData persistence) where each document
is a project.

### Two-process model

1. **Host (Swift)** — the macOS app. Manages UI, persistence, and
   Frida session lifecycle.
2. **Agent (TypeScript)** — compiled JS injected into the target
   process via Frida. Exposes RPC methods for instrumentation, REPL
   evaluation, memory access, and symbolication.

The agent entry point is `Luma/Agent/core/luma.ts`, which re-exports
all RPC methods from sibling modules. Agent source is compiled and
embedded into `Luma/Generated/LumaAgent.swift` by the
`LumaBundleCompiler` build tool target. The `Generated/` directory
is gitignored — it is produced at build time.

### Key host-side types

- **`Workspace`** (`Workspace.swift`) — central `@MainActor
  ObservableObject` that owns the `DeviceManager`, all
  `ProcessNode` instances, the event stream, package management,
  and collaboration state. Extended in `Workspace+Packages.swift`
  and `Workspace+Collaboration.swift`.
- **`ProcessNode`** (`Models/ProcessNode.swift`) — represents one
  attached process. Holds the Frida `Session` + `Script`, the
  `R2Core` (Radare2 disassembler), loaded modules, and
  `InstrumentRuntime` instances.
- **`InstrumentRuntime`** (`Models/InstrumentRuntime.swift`) —
  manages a single instrument instance's lifecycle and config
  synchronisation with the agent via RPC.
- **`MainWindowView`** — top-level SwiftUI view; splits into
  sidebar (process/instrument list) and detail area.

### Persistence (SwiftData)

Models: `ProjectUIState`, `ProjectPackagesState`,
`InstalledPackage`, `ProjectCollaborationState`, `NotebookEntry`,
`TargetPickerState`, `ProcessSession`, `RemoteDeviceConfig`,
`REPLCell`. Schema version managed via `LumaVersionedSchema` /
`LumaMigrationPlan` in `LumaApp.swift`.

### Dependencies (Swift Package Manager)

- `frida-swift` — Frida bindings
- `SwiftyR2` — Radare2 integration for disassembly / address
  insights
- `SwiftyMonaco` — Monaco code editor component

### Agent modules (`Luma/Agent/core/`)

Each module corresponds to a group of RPC methods: `env`,
`instrument`, `memory`, `repl`, `resolver`, `symbolicate`,
`console`, `pkg`, `value`. Built-in instruments live in
`Luma/Agent/instruments/` (e.g. `tracer.ts`, `codeshare.ts`).

## Commit Style

- Subject line: max 50 characters
- Body lines: max 72 characters

## Requirements

- macOS 15.6+
- Xcode 26+
