# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when
working with code in this repository.

## Build Commands

```sh
make                 # Incremental release build via xcodebuild → build/Luma.app
make check-examples  # Read the Pharo example catalog in the image
make check-patches   # Play every patch offline, and check panning and echo
make check-editor    # Ask the compiler's language server what it completes
make clean           # Remove build artifacts
```

`make -C LumaGtk render-tests` draws the shader effects, a lettered
scene and the projection helpers near and far offscreen, writes a PNG
of each, and fails on a case that drew nothing -- what has gone wrong
in this drawing has been blank frames and mirrored glyphs, which a
compiler cannot see and a PNG shows at a glance.

`LUMA_SOAK=<snippet> make -C LumaGtk soak` plays a snippet in a canvas
and reports what the process is holding as it goes -- the game leaks
nothing, but it took three fixes to get there, and a flat line is only
worth reading once the snippet is seen moving.

`make check-editor` opens a hook in a scratch project and asks the
compiler's language server what it completes, hovers and reports. The
editor draws what that server says, and the server sees the workspace
the way a build does -- so a typing that went missing shows here first.

`PharoExampleCatalog` is Smalltalk inside Swift string literals, which
no compiler reads. `make check-examples` parses each one in the image
and reports syntax errors, names nothing defines, and selectors
nothing implements -- the three ways examples have shipped broken.

glslang and SPIRV-Cross do the GLSL→Metal translation, at build time
and at run time, and build under neither SwiftPM nor Xcode. CI makes
them into `ShaderToolchain.xcframework` and publishes it against a
`shader-toolchain-<version>` tag; the manifest names that artifact, so
a build downloads it and nothing local is needed. It carries a slice
per platform the app ships to -- macOS, the device and the simulator --
since the runtime translation goes wherever the app does.

To work on the toolchain itself, make one and say so:

```sh
Scripts/make-shader-toolchain-xcframework.sh
export SHADER_TOOLCHAIN_ROOT=artifacts/ShaderToolchain.xcframework
```

Both Makefiles set that themselves when the artifact is there. Only
Apple platforms have any of this: OpenGL takes the GLSL as it stands,
so `CShaderTranslate` is not a target at all elsewhere.

Or open `Luma.xcodeproj` in Xcode and build with Cmd+B (set
destination to **My Mac**, or to a simulator for the iOS frontend).

The agent bundles, the TypeScript typings and the shader catalog are
generated Swift inside `LumaCore`, and the Pharo image is a resource
staged into it. Xcode enumerates a package target's sources and
resources when it loads the package graph -- before any build phase or
scheme pre-action runs. Anything produced during a build is therefore
missing from that build, so `Scripts/generate-sources.sh` writes them
before `xcodebuild` is invoked: `make` and CI run it, and the Luma
scheme's pre-action refreshes them, saying what to run when they are
not there yet. A fresh checkout built from Xcode wants it once by
hand. SwiftPM generates the sources through `LumaBundlePlugin` and
`LumaShaderPlugin` instead, and both Makefiles stage the image through
`Scripts/stage-pharo-image.sh`.

`LUMA_LOCAL_PACKAGES="frida-fs=$HOME/src/frida-fs" make` builds the
agent against a checkout instead of the npm package of the same name,
for trying a change before it is published. Space-separated
`name=path` pairs; the checkout must already be built.

`LumaCore` (the cross-platform Swift package) can be built and
type-checked on Linux without Xcode:

```sh
swift build --target LumaCore
```

Only Apple platforms have a published Pharo VM to link against.
Elsewhere SwiftyPharo asks pkg-config for `pharo-vm`, which no
distribution packages, so `make -C LumaGtk build` builds one into
`.build/pharo-vm` on the first run and leaves an installed one alone.
It prefers a sibling `../SwiftyPharo` checkout over the resolved one,
the way the image does, so work on the VM is picked up without
pushing. That first build is long; `PLATFORM=linux tools/build-vm.sh`
in SwiftyPharo is the same thing by hand.

Luma's version comes from `Scripts/luma-version.sh` and nowhere else:
a tagged commit is its tag, and anything after it is a `-dev.N` build
of the release `VERSION` names, or of the next patch once that release
is tagged. Bump `VERSION` when work toward the next minor or major
starts, so that development builds already count as it: a store item
that asks for that Luma is offered to them. `LUMA_VERSION` overrides
it, which is how CI hands every job the one its `version` job worked
out. The `LumaVersionWriter` tool puts it in LumaCore as
`LumaVersion.string` -- `Scripts/generate-sources.sh`, the LumaGtk
Makefile and `LumaBundlePlugin` all run it -- and `make` passes it to
Xcode as `MARKETING_VERSION`. The tool is Swift rather than a script
because the plugin runs it on Windows too, where there is no shell to
run the script with: there the plugin hands it `LUMA_VERSION`, and
without one the build stops rather than guess.

There are no tests or linting commands. Code formatting follows
`.swift-format` (4-space indent, 140-char line length).

Avoid "headline comments" that narrate what the next block does.
Prefer aptly named variables and functions to make code
self-explanatory. Only add comments as a last resort, for
non-obvious *why* (hidden constraints, workarounds).

## Architecture

Luma is an interactive dynamic instrumentation app built on
[Frida](https://frida.re). All business logic lives in **LumaCore**,
a portable Swift package. The current shipping frontend is a SwiftUI
app for macOS and iOS; a GTK/Adwaita frontend for Linux can be added
against the same `LumaCore`.

The Pharo surface -- the playground, the notebook cells, the source
editor with its inline marks, the inspector columns and the canvas --
is written once for both Apple platforms. `Luma/Platform*.swift` holds
what the two frameworks name differently: a view, a representable, a
hosting view, a font, a color, and what the pointer becomes where
there is one. The source editor is the one place the two really part
company: a text view is inside a scroll view on AppKit and is one on
UIKit, the find bar is the app's on one and the system's on the other,
and completions are a panel where there is a pointer and a strip above
the keyboard where there is not.

```
+-----------------------------+      +---------------------------+
| SwiftUI frontend (macOS/iOS)|      |  GTK frontend (Linux)     |
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
  `CollaborationSession`, `GitHubAuth`, `InstrumentFolderLibrary`, the
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
- **`InstrumentFolder` / `InstrumentFolderLibrary`** — a custom
  instrument as a folder on disk: its sources beside a `package.json`
  whose `main` is the entrypoint, whose `dependencies` are the packages
  it imports, whose `engines.luma` (`>=MAJOR.MINOR.PATCH`, the one form
  taken) is the oldest Luma it runs in, and whose `luma` object carries
  name, icon, compatibility, features and widgets. Instruments in one repository
  share code by naming a `luma.root` above their folders: what the
  sources import by relative path from under that root comes along, and
  the instrument's paths are then relative to it. Linking one brings it into the
  project as a custom instrument and remembers the folder in
  `LumaAppState`, outside the document, so collaborators get the
  instrument without needing the folder. The link remembers what both
  sides held when they last agreed, which is what tells an edit made in
  Luma from one made on disk: the first is written through to the
  folder, the second is offered as a reload rather than taken, since a
  reload drops what running instances hold, and when both changed the
  user picks. `InstrumentFolderMonitor` watches the folder. Names the
  package shows come from `displayName`. The library is the folders under
  `dataDirectory/Instruments`. An instrument's dependencies install
  into its own `node_modules` inside the compiler workspace, ahead of
  the project-wide packages.
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
  `PatternSourceRecord`, `PharoClassDefinition`, `PharoMethodDefinition`,
  `ProjectCollaborationState`,
  `TargetPickerState`, plus UI-state singletons `ProjectUIState` and
  per-session `SessionUIState`. The schema is defined once, in
  `ProjectStore`, and created only in a new database, together with the
  format version in `PRAGMA user_version`, which is bumped whenever the
  schema changes. A project at any other version is refused, saying
  whether an earlier or a newer Luma made it. There are deliberately no
  migrations or compatibility paths while the foundations are still
  moving.
  What has yet to reach a lab waits in one `outbox` table, a row per op
  whatever its family (`OutboxOp`), and is replayed on the next join.
  Widget state carries a revision that the session's host advances with
  every change; on joining, the side holding the higher one gives its
  state to the other.
  What the lab has ever held is kept in `lab_known_subject`, a row per
  `LabSubject`, from the join reply, the ops heard from the lab and the
  acknowledgments of our own. On joining, something the project holds and
  the lab lacks is uploaded when the lab never knew it, and dropped when it
  did, since a member then removed it.
  A change the lab refuses is undone: the client reads the lab again with
  `.snapshot` and takes its copy.
- **`PatternLibrary`** — the project's patterns are rows, materialized
  into `patterns/` in the per-project compiler workspace beside its
  `node_modules`, so a pattern can import an installed package and a
  shared `.luma` carries what its placements refer to. Installed
  packages carrying the `frida-pattern` keyword show up read-only
  beside them, and a custom instrument's pattern files can be placed
  too, though they are edited in the instrument and stay out of the
  pattern list. `PatternDecoder` compiles with the workspace as project
  root and defines `__MEMORY__`, since Luma only decodes process memory.
  A lab shares the project's patterns, since a placement is no use to a
  collaborator without the pattern it names. Placements live on a REPL
  cell, an insight, a notebook entry, an event or a custom instrument's
  hex widget, and any member may set them. A widget's are kept per
  instance and widget and applied to whatever bytes it shows; like a
  cell's and an insight's they travel as `set-placements`, and the join
  reply carries them as `widget_placements`. One on a byte array inside
  a JavaScript value names where those bytes were read (`origin`),
  which is how several arrays in one value keep theirs apart; one with
  no origin is on the holder's own dump. Every hex view that can be
  decoded is the one decode view, and decoding itself is the engine's.
  The lab's web page cannot decode, so a pinned entry also sends a
  `PlacementSnapshot` of what its placements decode to.
- **`TraceStore`** — file-backed blob store for raw ITrace data.
  Engine routes reads through `loadTraceData(traceID:sessionID:expectedSize:)`,
  which checks live in-memory pending state, then the local file,
  then falls back to a paginated server fetch via `CollaborationSession`.
- **`CollaborationSession`** — portal bus, rooms, notebook sync,
  chat. `GitHubAuth` is a separate `@Observable` actor that owns
  the OAuth device flow and token storage; `Engine.startCollaboration`
  awaits `gitHubAuth.requestToken()`, which suspends until the host
  finishes presenting the sign-in sheet.
- **`PortalConnection`** — the one connection to the portal, shared by
  every lab, the welcome screen and the store, since frida-core keeps one
  device per address and the server one lab per connection. Users retain a
  `Lease` and release it; the device goes away when the last one does, or
  for everyone when `GitHubAuth` signs out. Before the first lease it
  checks that the `+welcome` names its protocol and says `.hello` with the
  platform and Luma version; a server on another protocol, or one that
  turns this Luma away, fails the connection with the message to show,
  as `unsupported_protocol` and never an auth failure. It keeps the
  `+welcome` for whoever arrives later, numbers requests across all users,
  and hands every notification and the detach to each of them.
- **`Storefront`** — the store, reached as `engine.storefront`. The catalog is
  plain HTTP under `BackendConfig.storeCatalogURL`, so anyone may browse it
  without signing in. Browsing is a session from `open(for:showing:)` to
  `close()`: `open` takes the device an instrument is being added to, since the
  server ranks what fits it first and then what is trending, and how many
  results the frontend has room for before its own instruments, and loads that
  first page beside the categories. `search(_:)` and `filter(by:)` replace the
  results with the first page for the new text and category, cancelling whatever
  was still being fetched so a late reply cannot overwrite a newer one;
  `loadMore()` appends a longer page while `moreResults` says there is one. What
  is installed, kept by `InstalledStoreItems`, lasts as long as the project
  instead: when the engine starts with anything installed, those items are asked
  for by id, quietly, since they may be anywhere in the ranking, and opening the
  store asks again; a reply that does not come leaves the latest version
  unknown, and one that is older than what was since heard is not taken.
  `results` leaves the installed ones out, `installedItems` holds them, and an
  install or uninstall moves an item between the two without asking again. An
  item's picture is a request of its own, so `icon(of:)` fetches it once per
  item and version and answers the default symbol when it cannot. Only
  installing and publishing ask for a sign-in, through `requireAccount()`, which
  then leases the portal connection and fetches the account, kept current by the
  server's `+update` rather than by asking. The same lease hears the `+update`
  sent for an item whenever a version of it is published, which replaces what is
  known of it, installed or listed. The account is fetched once whenever there
  is a sign-in, the one stored when the engine starts or one made later by any
  route, and again when the store opens; until there is one, and again after a
  sign-out, whether a sponsor item is the user's is unknown rather than no. Its
  `partnerContact` is whether the user lets NowSecure, who sponsor Luma, contact
  them: unanswered until `answerPartnerContact(_:)` says, which may be asked
  anywhere and answered again later. That never asks for a sign-in, being
  offered only to a user who has one, and `BackendConfig.privacyPolicyURL` is
  what to show beside the question. The lease is let go of when the fetch,
  answer, browsing or publishing that wanted it ends, unless there is a sign-in
  and something is installed: then it is held until the project closes, so that
  updates arrive by themselves. A lost connection is not retried; the next thing
  that needs the store connects again. Items install into the instrument library
  as folders named after the item id, which projects then link like any other.
  `linkedInstallation(ofCustomInstrument:)` says which item a linked instrument
  was installed from and whether a newer version is known, and
  `versionsSinceInstalled(of:)` gives the release notes of what updating would
  bring. An install over an item whose folder this project links reloads this
  project's copy from the folder, since that is what was asked for, so updating
  an instrument where it lives is `install` of the newer item; other projects
  linking the folder are offered the reload as for any change made on disk. What
  was installed is remembered in `LumaAppState` with a snapshot of the folder,
  so an update can tell an edited copy from a pristine one and asks before
  replacing it. A project whose linked library folder disappears is unlinked and
  keeps its copy. Publishing reads a linked instrument's folder: `version` and
  `luma.store` (summary, category, access) in its `package.json`, and its
  `README.md` as the description; every version carries release notes.
  `loadCategories()` gives the publish form the categories without loading a
  page. Every catalog request states `app_version`, as the hello does for
  the connection, so the store shows each item at the newest version
  this Luma runs and sends updates only for those; an item whose
  `min_app_version` this Luma does not meet is `.requiresLuma` and is not
  offered for adding. A view widget or `.st` files need Luma 3.0.0, so an
  instrument with either is published only once its `engines.luma` says
  so, and an edit made in Luma that adds a view widget or a `.st` file
  raises it.

- **Instrument views (`Sources/LumaCore/InstrumentViews/`)** — a custom
  instrument's `.st` files are Tonel classes it ships, and a widget of
  kind `view` names one of them. `InstrumentViews` (`engine.instrumentViews`)
  makes one instance per instrument instance and widget once a frontend
  shows the widget, and keeps it until the instance goes, its Smalltalk
  changes or the project closes; across a detach it goes on showing the
  state it was last given. The classes are anonymous, made once per
  instrument definition, session and version of its code, in a
  `LumaInstrumentEnvironment` of their own that resolves their class
  names: instances of one instrument in one session share class-side
  state, as they share the agent's module, and nothing else does.
  Instruments never clash, nothing is left behind in `Smalltalk globals`
  and `LumaJournal` never hears of them. A view runs on a
  `LumaSubscription` process of its own, opened in a `LumaRun` named by
  the view so that stopping it stops nothing else, and fed by a pulled
  stream (`PharoPulledResult`): the host hands it the next item only once it
  took the last, which is what lets moves, scrolls and states coalesce
  while it is busy. Every call into the instrument's object runs under a
  three-second deadline in the image, and anything it raises stops the
  view with the error in its widget, naming the `<gtView>` method when
  one raised it or answered no view. Nothing can show an action button,
  so `SwpView`'s `action…` declarations are replaced in the image: in a
  view's process (`LumaViewing`) they raise `LumaViewRefusal`, which no
  `on: Error` swallows and which stops the view naming the declaration,
  and anywhere else they still do nothing. The
  agent's `setState`/`sendEvent` arrive as `.viewState`/`.viewEvent`
  widget updates, an event's bytes as its message data and a state's in
  pieces after its value; the image reaches those bytes as `LumaBytes`
  lent by `PharoBlobRegistry`, which a drawable can take as vertices
  directly. A value is measured as the UTF-8 bytes of its
  JSON: the agent throws over 256 KiB, and whatever the host refuses all
  the same stops the view with the reason in its widget, once it runs: a
  refusal that arrives sooner waits, so the widget asks for **Allow**
  before it reports anything. A state's bytes
  are persisted in the blob store (`BlobKind.viewState`), not in the
  state's JSON. Whether an instrument's
  Smalltalk may run is `HostCodeTrust`'s: its digest (`HostCode`) is
  allowed when the store published it, when the user approved it on this
  machine (`LumaAppState`), or when the user produced it in Luma's editor
  from an allowed one; anything else waits in the widget for **Allow**.
  In a lab every member's Luma runs the view: the host uploads a state's
  bytes in chunks that members fetch by range, events are relayed, and a
  view's message reaches the host's agent only from a lab owner, as widget
  actions do. Who last changed a definition in a lab (`changed_by`) is what
  the widget names when it asks. A view opens an object in the inspector
  itself with its context's `spawn:`, which describes it as a selected
  row's `send:` is described and hands it, through `spawns(of:)`, to the
  frontends showing the widget, which open it as they open a selected row;
  with none showing it the description is released and `spawn:` answers
  false. Like any other view request it stays in this Luma.
- **Canvas (`CanvasScene`, `CanvasDrawable`, `CanvasRegistry`)** — a
  scene the image holds by handle and changes; the host draws it.
  A drawable carries the author's own vertex and fragment stages,
  their own attribute layout, named uniforms, data buffers, a
  transform and a visibility flag. `CanvasRegistry` is lock-guarded
  rather than main-actor, because the image's thread needs a handle
  back at once; changes reach the frontends through
  `CanvasRegistry.onChange` on the main thread. What the user does
  over a canvas goes through the `CanvasEngagement` of the view
  showing it, which both frontends feed their toolkit's events: a
  click or touch engages the canvas, and the pointer leaving, the
  keyboard focus leaving or the window resigning ends it. Scrolls and
  keys reach the scene only while it is engaged, the rest always; a
  scroll it does not take is the page's, and a key it let through is
  released when it ends, so `isDown:` never answers a key it was not
  sent.
- **Audio (`Synth`, `SynthEngine`, `EventChime`)** — `SynthEngine` is
  the mixer, running on the audio device's thread. Its storage is
  allocated once and reached through unsafe pointers, and the control
  side speaks to it only through a lock-free ring, so nothing under
  the callback allocates, retains or locks. Eight channels, each with
  its own patch and pattern on its own step clock. `CLumaAudio` holds
  only the device layer (miniaudio); the voices are Swift.
- **TypeScript editing (`Sources/LumaCore/TypeScript/`)** — the
  editors ask `Frida.LanguageServer` for what they show, which is the
  compiler's own language server speaking LSP in-process. `LanguageClient`
  does the JSON-RPC, `TypeScriptProject` owns one server per editor
  surface so the declarations a surface adds ambiently stay out of the
  others' programs, and `TypeScriptDocument` is the open file the
  frontends talk to for completions, hover, diagnostics and symbols.
  `TypeScriptEditorSession` opens a project for an `EditorProfile`. The
  server sees the compiler workspace's `node_modules` and the typings
  embedded in the compiler, so the editor and a build agree. Lexical
  coloring is `TypeScriptLexer`, and `SourceSyntaxPalette` its colors,
  shared by both frontends. A file in an instrument is edited as what
  `SourceSyntax(path:)` says it is: scripts as TypeScript, patterns as
  patterns, `.st` files as Smalltalk, and anything else as plain text.
  No server is asked about the last two. A `.st` file is a
  `TonelDocument`, completed by the image as the playground is, and on
  macOS colored by it too, a method at a time with the framing as one
  expression of its own; GTK colors it the way its playground does. The
  instrument's own classes live where the image's completion does not
  look, so what its files define is offered beside it. Opening one starts
  the workspace, as the playground does, so Luma's own classes complete
  whoever started it first.
- **Pharo bridges (`Sources/LumaCore/Pharo/`)** — `PharoAsyncBridge`
  carries the image's requests to the Engine and the answers back,
  one reply or a stream of them; `Engine+PharoRequests` answers for
  the project and `Engine+PharoSessionRequests` for a process.
  `PharoSynthBridge` and `PharoCanvasBridge` are the image's entry
  points into the synthesizer and the canvas. `PharoLumaBindings`
  compiles the `Luma*` classes into the image on the way up, with
  `PharoSessionBindings` and `PharoPatternBindings` after it. Classes
  and methods written in the image are the project's: `LumaJournal`
  hears the system announcer and the Engine keeps them as rows, which
  `PharoWorkspace` replays into the image on the next start. An object
  that says `lumaChanged` has every inspector column showing it reload,
  through `PharoObjectChanges`. A cell evaluates as a `LumaRun` named by
  its id: the subscriptions, tunes and voices it starts, and every process
  it forks, plainly or with `LumaRun fork:` and forks of those included,
  stop when the cell runs again or is deleted. Who owns what a process
  starts is the process's (`LumaRun on:do:`), and every fork inherits it,
  so an instrument view's own process adopts what it starts long after
  the evaluation that opened it returned. See the
  symbol-visibility note below: nothing in Swift calls these
  `@_cdecl` exports, and that has bitten twice.

### Host (`Luma/`)

- **`Workspace`** — thin host adapter. Owns `Engine`, exposes a few
  UI-only flags (`targetPickerContext`, `isCollaborationPanelVisible`),
  wires the SwiftUI instrument-UI registry, and provides
  `processNode(for: event)` / `instrument(for: event)`
  / `sidebarItem(for: NavigationTarget)` lookup helpers.
- **`MainWindowView`** — top-level SwiftUI view; splits into
  sidebar (process/instrument list) and detail area.
- **`Luma/Instruments/`** — per-instrument SwiftUI factories
  (`TracerUI`, `CustomInstrumentUI`, `CodeShareUI`), the `InstrumentUI`
  protocol, the `InstrumentUIRegistry` dispatcher, and
  `InstrumentEventMenuItem`.
- **`Luma/Editor/`** — the TypeScript and JavaScript editor:
  `CodeTextView` is the text view (AppKit and UIKit), `CodeTextEditor`
  the representable that binds it to a `TypeScriptEditorSession`.
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
- **Two flavors, deliberately.** OpenGL takes the source as it
  stands, at a version with no explicit locations, binding attributes
  by name; Metal's goes through glslang, which wants both. The
  generated preambles differ accordingly.
- **spirv-cross numbers MSL resources in the order it meets them**,
  not by the binding written in the shader. `translate.c` pins every
  binding explicitly — buffers 0 and 1 for the two uniform blocks,
  textures and samplers above — and vertices bind at index 30, clear
  of the range. Getting this wrong binds each buffer where another was
  expected, which no compiler will catch.

`LumaText` letters a scene from a glyph atlas the **host** rasterizes
-- Core Text on macOS, Pango on GTK -- because what fonts an image can
reach is its own business, and the bundled one finds no scalable
family at all: every point size comes back as the same 14-pixel bitmap.
The frontends register a `GlyphAtlasRasterizer` on the way up; each
string becomes two triangles a letter. Saying something else goes
through `remesh:primitive:`, which sets vertices without a commit, so
text that changes every frame costs a buffer rather than a rasterize
and a shader compile. Its point size is in the units the rest of
the interface uses, and the atlas is rasterized to match: `u_scale`
carries how many physical pixels a logical one is worth, so the quads
land on whole pixels instead of being scaled, which is what would
make the lettering soft.

The atlas is a `LumaGlyphs` of its own, which `LumaText` is only one
user of: `applyTo:` hands its picture to any drawable as the sampler
`glyphs`, and its measures are what an author lays glyph quads out
with, so a view can letter thousands of labels in one drawable of its
own. Such vertices are built in a `ByteArray` and handed over through
`LumaBytes holding:`, one copy, rather than through `mesh:`, which
crosses into the host a float at a time.

Keep `gl_Position.z` within 0..1. OpenGL's clip space runs -1..1 and
Metal's runs 0..1, so a negative depth draws on GTK and is clipped
away on macOS -- which no compiler will catch either. `LumaDrawable`'s
`perspective:aspect:near:far:` and `orthographicWidth:height:` map
depth onto 0..1 for that reason, with +z toward the viewer.

A Metal view that draws by itself is an `OnScreenMTKView` and stops
while its window is not visible. A covered, hidden, minimized or
ordered-out window's layer hands its drawables back late, so asking for
the next one blocks for up to a second at a time; a screen's display
link fires regardless. Nor is a visible window safe: one that is mostly
covered can hold its drawables just as long. So a shader effect paints
from its display link's own thread (`DisplayLinkThread`), at up to 60
Hz, which an ambient effect has no use for more than, and only that
thread ever waits. A canvas draws when its scene is committed and, for
as long as `CanvasScene.isMoving` says a driver or `u_time` keeps it
moving, on every frame; a still scene costs nothing between changes.
GTK ticks from the widget's frame clock instead, which stops once the
widget is unmapped, and paces a canvas the same way.

The preambles are generated text, and generated text is worth
compiling. `ShaderVocabulary`, `CanvasGeometry` and `CanvasScene`
depend on nothing but Foundation, so they can be built on their own
and their output handed to `glslang` — which catches what a Swift
build cannot, a shader that compiles nowhere:

```sh
swiftc -o gencheck Sources/LumaCore/{ShaderVocabulary,CanvasGeometry,CanvasScene,CanvasInput}.swift main.swift
glslang -S frag generated.frag          # OpenGL flavor
glslang -S frag -V generated.frag       # Metal flavor, as translated
```

### Symbol visibility (macOS)

An exported-symbols list is a whitelist: everything the image resolves
by name has to be in it, not just Luma's own entry points. SwiftyPharo's
`swifty_pharo_*` bridge is resolved the same way, and leaving it out
takes Pharo down entirely -- in release builds only.

The image resolves the host's `luma_*` entry points by name through
dlsym, and nothing in Swift calls them. Two consequences, both of
which have already caused bugs:

- **Release** builds with link-time optimization, which internalizes
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
- `SwiftyPharo` — Pharo VM, image and the `<gtView>` builder shim
- `miniaudio` — vendored in `Sources/CLumaAudio`, device layer only
- `liblzma` — unpacks the Barebone agent off Apple, where
  Compression is not there to do it
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
