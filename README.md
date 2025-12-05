# Luma

## Requirements

-   macOS >= 15.6
-   Xcode 26

## Building

Clone the following three repositories **side-by-side in the same parent
directory**:

``` sh
git clone https://github.com/frida/luma.git
git clone https://github.com/frida/frida-swift.git
git clone https://github.com/oleavr/SwiftyMonaco.git
```

Your folder layout should look like:

    parent/
    ├── luma/
    ├── frida-swift/
    └── SwiftyMonaco/

### 1. Build Frida's Swift bindings

``` sh
cd frida-swift

# Optionally configure features:
./configure -- -Dfrida-core:simmy_backend=disabled

make
```

### 2. Build Luma

``` sh
open luma/Luma.xcodeproj
```

Then build from within Xcode.
