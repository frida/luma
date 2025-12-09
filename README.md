# Luma

## Requirements

-   macOS ≥ 15.6
-   Xcode ≥ 26

## Building

### Option 1: Build using Xcode (recommended)

1.  Open the project:

    ```sh
    open luma/Luma.xcodeproj
    ```

2.  Ensure the build destination is set to **My Mac** (Luma currently
    uses AppKit-only components and does not yet build for iOS).

3.  Choose **Product → Build** (⌘B).

This performs an incremental build and is the most convenient workflow
during development.

------------------------------------------------------------------------

### Option 2: Build from the command line (also incremental)

A `Makefile` is provided for building Luma without opening Xcode.
This build is **also incremental**, because it uses a persistent Derived
Data directory.

The output app is produced in `./build/`, and intermediate build files
are stored in `./build/.derived`.

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
