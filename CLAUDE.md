# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when
working with code in this repository.

## Build Commands

```sh
make          # Incremental release build via xcodebuild → build/Luma.app
make clean    # Remove build artifacts
```

glslang and SPIRV-Cross do the GLSL→Metal translation, at build time
and at run time, and build under neither SwiftPM nor Xcode. CI makes
them into `ShaderToolchain.xcframework` and publishes it against a
`shader-toolchain-<version>` tag; the manifest names that artifact, so
a build downloads it and nothing local is needed.

To work on the toolchain itself, make one and say so:

```sh
scripts/make-shader-toolchain-xcframework.sh
export SHADER_TOOLCHAIN_ROOT=artifacts/ShaderToolchain.xcframework
```

Both Makefiles set that themselves when the artifact is there. Only
Apple platforms have any of this: OpenGL takes the GLSL as it stands,
so `CShaderTranslate` is not a target at all elsewhere.

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
- **`AddressAction` / `ThreadAction`** — pluggable per-address and
  per-thread action providers. The tracer registers itself at engine
  init; future instrument kinds can call
  `engine.registerAddressActionProvider` /
  `registerThreadActionProvider`. `AddressContext` (kind: code /
  function / data) lets providers tailor actions per call site.
- **Persistence (GRDB / SQLite)** — `.luma` is a directory document
  containing `db.sqlite` and `traces/<uuid>.bin`. `ProjectStore` owns
  the database with row models for `ProcessSession`,
  `InstrumentInstance`, `REPLCell`, `NotebookEntry`, `ITrace` (metadata
  only; data lives in `TraceStore`), `AddressInsight`,
  `RemoteDeviceConfig`, `ProjectPackagesState`, `InstalledPackage`,
  `ProjectCollaborationState`, `TargetPickerState`, plus UI-state
  singletons `ProjectUIState` and per-session `SessionUIState`.
  Schema is created with `if not exists` on every open; pre-release,
  no migrations.
- **`TraceStore`** — file-backed blob store for raw ITrace data.
  Engine routes reads through `loadTraceData(traceID:sessionID:expectedSize:)`,
  which checks live in-memory pending state, then the local file,
  then falls back to a paginated server fetch via `CollaborationSession`.
- **`CollaborationSession`** — portal bus, rooms, notebook sync,
  chat. `GitHubAuth` is a separate `@Observable` actor that owns
  the OAuth device flow and token storage; `Engine.startCollaboration`
  awaits `gitHubAuth.requestToken()`, which suspends until the host
  finishes presenting the sign-in sheet.

- **Canvas (`CanvasScene`, `CanvasDrawable`, `CanvasRegistry`)** — a
  scene the image holds by handle and changes; the host draws it.
  A drawable carries the author's own vertex and fragment stages,
  their own attribute layout, named uniforms, data buffers, a
  transform and a visibility flag. `CanvasRegistry` is lock-guarded
  rather than main-actor, because the image's thread needs a handle
  back at once; changes reach the frontends through
  `CanvasRegistry.onChange` on the main thread.
- **Audio (`Synth`, `SynthEngine`, `EventChime`)** — `SynthEngine` is
  the mixer, running on the audio device's thread. Its storage is
  allocated once and reached through unsafe pointers, and the control
  side speaks to it only through a lock-free ring, so nothing under
  the callback allocates, retains or locks. Eight channels, each with
  its own patch and pattern on its own step clock. `CLumaAudio` holds
  only the device layer (miniaudio); the voices are Swift.
- **Pharo bridges (`Sources/LumaCore/Pharo/`)** — `PharoHostBridge`
  publishes record feeds; `PharoSynthBridge` and `PharoCanvasBridge`
  are the image's entry points into the synthesiser and the canvas.
  `PharoLumaBindings` compiles the `Luma*` classes into the image on
  the way up. See the symbol-visibility note below: nothing in Swift
  calls these `@_cdecl` exports, and that has bitten twice.

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

### Shaders (`Shaders/`)

Effects are authored once, body-only, in GLSL, against a preamble the
host supplies (`v_uv`, `frag_color`, `u_resolution`, `u_time`,
`u_scheme`, `u_activity`, `u_pulse`, `dataAt()`, `u_mvp`).

- **`LumaShaderCompiler`** translates each `Shaders/*.frag.glsl` at
  build time: a Swift catalog of the GLSL for OpenGL hosts, and a
  Metal fragment function via glslang and spirv-cross. Driven by
  `LumaShaderPlugin` for SwiftPM, by an Xcode target feeding a script
  phase on `AgentBundle`, and by a Makefile rule for LumaGtk, whose
  plugins do not run when the package is resolved as a dependency.
- **`CShaderTranslate`** does the same translation at *runtime*, for
  shaders written in a snippet, and answers what the compiler said
  when they will not compile.
- **Two flavours, deliberately.** OpenGL takes the source as it
  stands, at a version with no explicit locations, binding attributes
  by name; Metal's goes through glslang, which wants both. The
  generated preambles differ accordingly.
- **spirv-cross numbers MSL resources in the order it meets them**,
  not by the binding written in the shader. `translate.c` pins every
  binding explicitly — buffers 0 and 1 for the two uniform blocks,
  textures and samplers above — and vertices bind at index 30, clear
  of the range. Getting this wrong binds each buffer where another was
  expected, which no compiler will catch.

`LumaText` letters a scene from a glyph atlas the **host** rasterises
-- Core Text on macOS, Pango on GTK -- because what fonts an image can
reach is its own business, and the bundled one finds no scalable
family at all: every point size comes back as the same 14-pixel bitmap.
The frontends register a `GlyphAtlasRasteriser` on the way up; each
string becomes two triangles a letter. Saying something else goes
through `remesh:primitive:`, which sets vertices without a commit, so
text that changes every frame costs a buffer rather than a rasterise
and a shader compile. Its point size is in the units the rest of
the interface uses, and the atlas is rasterised to match: `u_scale`
carries how many physical pixels a logical one is worth, so the quads
land on whole pixels instead of being scaled, which is what would
make the lettering soft.

Keep `gl_Position.z` within 0..1. OpenGL's clip space runs -1..1 and
Metal's runs 0..1, so a negative depth draws on GTK and is clipped
away on macOS -- which no compiler will catch either.

The preambles are generated text, and generated text is worth
compiling. `ShaderVocabulary`, `CanvasGeometry` and `CanvasScene`
depend on nothing but Foundation, so they can be built on their own
and their output handed to `glslang` — which catches what a Swift
build cannot, a shader that compiles nowhere:

```sh
swiftc -o gencheck Sources/LumaCore/{ShaderVocabulary,CanvasGeometry,CanvasScene,CanvasInput}.swift main.swift
glslang -S frag generated.frag          # OpenGL flavour
glslang -S frag -V generated.frag       # Metal flavour, as translated
```

### Symbol visibility (macOS)

An exported-symbols list is a whitelist: everything the image resolves
by name has to be in it, not just Luma's own entry points. SwiftyPharo's
`swifty_pharo_*` bridge is resolved the same way, and leaving it out
takes Pharo down entirely -- in release builds only.

The image resolves the host's `luma_*` entry points by name through
dlsym, and nothing in Swift calls them. Two consequences, both of
which have already caused bugs:

- **Release** builds with link-time optimisation, which internalises
  anything unreferenced. `Luma/PharoBridgeExports.exp` names them so
  it cannot. That list is a *whitelist*, so it is set on the Release
  configuration only — on Debug it would hide the entry point the stub
  executable looks for in `Luma.debug.dylib`, and the app aborts on
  launch.
- **LumaGtk** passes `-export_dynamic` for the same reason.

A change to symbol visibility on the app target must be checked in
both configurations; a passing Release build says nothing about Debug.

### Dependencies (Swift Package Manager)

- `frida-swift` — Frida bindings
- `SwiftyR2` — Radare2 integration (used inside `LumaCore` for
  disassembly)
- `GRDB.swift` — SQLite persistence
- `swift-crypto` — collaboration crypto
- `SwiftyMonaco` — Monaco code editor component (host only)
- `SwiftyPharo` — Pharo VM, image and the `<gtView>` builder shim
- `miniaudio` — vendored in `Sources/CLumaAudio`, device layer only
- `glslang` + `spirv-cross` — GLSL to Metal, at build time and at
  runtime. Found wherever they happen to be installed; shipping wants
  prebuilt libraries beside the Pharo VM's, neither project building
  under SwiftPM.

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
