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

## Nix

Luma provides a [Nix](https://nixos.org) flake for running and
installing on Linux:

```sh
nix run github:frida/luma        # run Luma without installing
nix shell github:frida/luma      # shell with luma in PATH
nix build github:frida/luma      # build into the Nix store
```

The flake exposes an overlay so you can add Luma to your own Nix
configuration:

```nix
inputs.luma.url = "github:frida/luma";
nixpkgs.overlays = [ luma.overlays.default ];
```

After applying the overlay, `pkgs.luma` is available in your
package set.

## Building the GTK frontend (Linux)

### Prerequisites (Fedora)

Install the toolchains and `-devel` packages for Luma and its native
dependencies:

```sh
sudo dnf install -y \
    gcc-c++ libstdc++-static patch golang-bin nodejs swift-lang \
    libadwaita-devel atk-devel webkitgtk6.0-devel \
    libepoxy-devel librsvg2-devel \
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

Install four things by hand, then let the scripts do the rest:

- **Visual Studio 2022** (or the Build Tools) with the *Desktop
  development with C++* workload
- **[Swift for Windows](https://www.swift.org/install/windows/)** 6.2 or
  newer, on `PATH`
- **Python 3** and **Node.js**, on `PATH`
- **Git for Windows**

Nothing else has to be a Developer PowerShell: the scripts load the MSVC
environment themselves. From `LumaGtk/`, in an ordinary PowerShell:

```powershell
.\scripts\windows\bootstrap.ps1                        # one-time, ~1-2h
.\scripts\windows\build.ps1                            # debug
.\scripts\windows\build.ps1 -Configuration release
.\scripts\windows\package-msi.ps1 -Version 0.1.0       # build\Luma-*.msi
.\scripts\windows\run.ps1                              # launch with DLL PATH set
```

`bootstrap.ps1` provisions everything the build links against —
vcpkg with GTK 4, libadwaita and GtkSourceView, then `frida-core`,
`radare2` and a Pharo VM built from source — into
`%LOCALAPPDATA%\Luma\windows-deps`. It skips whatever is already
there, so re-running it after a failure resumes rather than restarts,
and `-Only <component>` (`vcpkg`, `gnu-tools`, `frida-core`,
`radare2`, `pharo-vm`) rebuilds just one. The upstream revisions come
from `.github/dependency-refs.env`, and CI runs the same script one
component at a time, so what a contributor builds is what CI builds.

One thing bootstrap cannot do for you: radare2 ships a collection of
shellcode as source, and Windows Defender quarantines it mid-build,
which surfaces as `fatal error C1083: Cannot open include file` for a
generated file. Bootstrap asks Defender what it took and says so, but
excluding a directory from your antivirus is your call to make, not a
build script's — from an elevated PowerShell:

```powershell
Add-MpPreference -ExclusionPath "$env:LOCALAPPDATA\Luma\windows-deps"
```

Or point `-R2Prefix` at a radare2 you already have and skip it.

No distribution packages a Pharo VM, and the one bootstrap builds comes
from our fork, which carries the Meson build and the tweaks that make it
compile with MSVC. It generates its own interpreter sources, so Meson,
Ninja and Python are all it needs beyond the compiler — bootstrap
installs the first two if they are missing.

Prefixes are found in `%LOCALAPPDATA%\Luma\windows-deps` first, then the
older `C:\vcpkg`, `C:\src\dist` and `C:\src\pharo` locations; override
any of them with `-VcpkgPrefix`, `-FridaPrefix`, `-R2Prefix`,
`-PharoPrefix` (or `$env:VCPKG_PREFIX` etc.) on every script here.
