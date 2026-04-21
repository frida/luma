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

- macOS ≥ 15.0
- Xcode ≥ 26 (with the Metal toolchain installed — open Xcode once
  and accept the Metal SDK download prompt, or install it via
  **Settings → Components**)

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

## Building the GTK frontend (Linux)

### Prerequisites (Fedora)

Install the toolchains and `-devel` packages for Luma and its native
dependencies:

```sh
sudo dnf install -y \
    gcc-c++ libstdc++-static patch golang-bin nodejs swift-lang \
    libadwaita-devel atk-devel webkitgtk6.0-devel \
    libgee-devel json-glib-devel libsoup3-devel \
    libunwind-devel libdwarf-devel libnice-devel \
    ngtcp2-crypto-ossl-devel libbpf-devel capstone-devel \
    lzfse-devel
```

Build and install `frida-core` into `/usr/local` (Fedora's `libbpf`
is too old, so force a subproject fallback):

```sh
cd ~/src
git clone git@github.com:frida/frida-core.git
cd frida-core
./configure --enable-shared --without-prebuilds=sdk \
    --enable-barebone-backend --enable-compiler-backend \
    -- --force-fallback-for=libbpf
make
sudo make install
```

Build and install `radare2` into `/usr/local`. The stock
`sys/install.sh` builds without optimization, so override `CFLAGS`
and strip unused code with `--gc-sections`:

```sh
cd ~/src
git clone git@github.com:radareorg/radare2.git
cd radare2
CFLAGS="-O2 -g -ffunction-sections -fdata-sections" \
    LDFLAGS="-Wl,--gc-sections" \
    ./sys/install.sh --install
```

### Build and run

From `LumaGtk/`:

```sh
make           # incremental build → .build/debug/LumaGtk
make run       # build + launch
make install PREFIX=/usr/local
```

## Building the GTK frontend (Windows)

Requires Swift for Windows, Visual Studio 2022 (for `cl.exe`),
vcpkg with gtk4, and prebuilt `frida-core` / `radare2` prefixes.
Launch a **Developer PowerShell for VS** and run from `LumaGtk/`:

```powershell
.\scripts\windows\build.ps1                            # debug
.\scripts\windows\build.ps1 -Configuration release
.\scripts\windows\package-msi.ps1 -Version 0.1.0       # build\Luma-*.msi
.\scripts\windows\run.ps1                              # launch with DLL PATH set
```

Prefix locations default to `C:\vcpkg\installed\x64-windows-release`
and `C:\src\dist`; override with `-VcpkgPrefix`, `-FridaPrefix`,
`-R2Prefix` (or `$env:VCPKG_PREFIX` etc.).
