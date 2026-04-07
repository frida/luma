# Luma

Interactive dynamic instrumentation app built on
[Frida](https://frida.re). All business logic lives in **LumaCore**,
a cross-platform Swift package; the current shipping frontend is a
macOS SwiftUI app, with a GTK/Adwaita frontend for Linux on the way.

## Repository layout

```
Sources/LumaCore/   # cross-platform Swift package — engine, sessions,
                    # persistence, disassembly, collaboration, hook
                    # packs, GitHub auth, address annotations, …
Agent/              # TypeScript agent injected into the target process
Luma/               # macOS SwiftUI frontend
Luma.xcodeproj/     # Xcode project (Luma app + LumaBundleCompiler)
Package.swift       # SPM manifest for LumaCore
```

## Requirements

- macOS ≥ 15.6
- Xcode ≥ 26

`LumaCore` itself only needs Swift 6 and the package dependencies
listed in `Package.swift`. It builds on Linux too:

```sh
swift build --target LumaCore
```

## Building the macOS app

### Option 1: Xcode (recommended)

1.  Open the project:

    ```sh
    open Luma.xcodeproj
    ```

2.  Ensure the build destination is set to **My Mac** (Luma currently
    uses AppKit-only components and does not yet build for iOS).

3.  Choose **Product → Build** (⌘B).

This performs an incremental build and is the most convenient
workflow during development.

### Option 2: Command line (also incremental)

A `Makefile` is provided for building Luma without opening Xcode.
This build is **also incremental**, because it uses a persistent
derived-data directory.

The output app is produced in `./build/`, and intermediate build
files are stored in `./build/.derived`.

To build:

```sh
make
```

To clean:

```sh
make clean
```

The resulting app will be located at:

    build/Luma.app
