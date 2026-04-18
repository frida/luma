# It installs only shared libs, regardless build type.
vcpkg_check_linkage(ONLY_DYNAMIC_LIBRARY)

# Source frida/gtk rather than an upstream tarball so we can ship the
# Windows CSD / DWM shadow fix (GNOME/gtk!8929) ahead of its upstream
# merge — without it, libadwaita windows render a solid black shadow
# margin on Windows for lack of a GDK compositor.
vcpkg_from_github(
    OUT_SOURCE_PATH SOURCE_PATH
    REPO frida/gtk
    REF 68e5f298872eae30e89c614f7dd23f935062e4df
    SHA512 ef86640305705c42bc48188ae158ccc0baad1240ffc0137f638b4d6ec1f63f424a0941420e5b3bbce28feda6b9d6f95334a6b4e0c071877eaf03ec71ad6dd077
    HEAD_REF main
    PATCHES
        0001-build.patch
)

vcpkg_find_acquire_program(PKGCONFIG)
get_filename_component(PKGCONFIG_DIR "${PKGCONFIG}" DIRECTORY )
vcpkg_add_to_path("${PKGCONFIG_DIR}") # Post install script runs pkg-config so it needs to be on PATH
vcpkg_add_to_path("${CURRENT_HOST_INSTALLED_DIR}/tools/glib/")

# vcpkg_find_acquire_program(PKGCONFIG) returns msys2's pkg-config which
# doesn't understand Windows-style PKG_CONFIG_PATH entries. g-ir-scanner
# invokes pkg-config directly at startup (and meson probes its --help
# output during configure) to prefill DLL search paths and detect
# --extra-library support; with a Windows-native pkgconf + an env
# PKG_CONFIG_PATH both work cleanly and the gir-scanner doesn't fall
# over on Windows SDK static-only deps like dxguid / DirectX-Headers.
if(VCPKG_TARGET_IS_WINDOWS)
    set(NATIVE_PKGCONF "${CURRENT_INSTALLED_DIR}/tools/pkgconf/pkgconf.exe")
    if(EXISTS "${NATIVE_PKGCONF}")
        set(ENV{PKG_CONFIG} "${NATIVE_PKGCONF}")
        get_filename_component(NATIVE_PKGCONF_DIR "${NATIVE_PKGCONF}" DIRECTORY)
        vcpkg_add_to_path(PREPEND "${NATIVE_PKGCONF_DIR}")
    endif()
    set(ENV{PKG_CONFIG_PATH}
        "${CURRENT_INSTALLED_DIR}/lib/pkgconfig${VCPKG_HOST_PATH_SEPARATOR}${CURRENT_INSTALLED_DIR}/share/pkgconfig")
endif()

set(x11 false)
set(win32 false)
set(osx false)
if(VCPKG_TARGET_IS_LINUX)
    set(OPTIONS -Dwayland-backend=false) # CI missing at least wayland-protocols
    set(x11 true)
    # Enable the wayland gdk backend (only when building on Unix except for macOS)
elseif(VCPKG_TARGET_IS_WINDOWS)
    set(win32 true)
elseif(VCPKG_TARGET_IS_OSX)
    set(osx true)
endif()

list(APPEND OPTIONS -Dx11-backend=${x11}) #Enable the X11 gdk backend (only when building on Unix)
list(APPEND OPTIONS -Dbroadway-backend=false) #Enable the broadway (HTML5) gdk backend
list(APPEND OPTIONS -Dwin32-backend=${win32}) #Enable the Windows gdk backend (only when building on Windows)
list(APPEND OPTIONS -Dmacos-backend=${osx}) #Enable the macOS gdk backend (only when building on macOS)

if("introspection" IN_LIST FEATURES)
    list(APPEND OPTIONS_RELEASE -Dintrospection=enabled)
    vcpkg_get_gobject_introspection_programs(PYTHON3 GIR_COMPILER GIR_SCANNER)
else()
    list(APPEND OPTIONS_RELEASE -Dintrospection=disabled)
endif()

vcpkg_configure_meson(
    SOURCE_PATH ${SOURCE_PATH}
    OPTIONS
        ${OPTIONS}
        -Dbuild-demos=false
        -Dbuild-testsuite=false
        -Dbuild-examples=false
        -Dbuild-tests=false
        -Ddocumentation=false
        -Dman-pages=false
        -Dmedia-gstreamer=disabled  # Build the gstreamer media backend
        -Dprint-cups=disabled       # Build the cups print backend
        -Dvulkan=disabled           # Enable support for the Vulkan graphics API
        -Dcloudproviders=disabled   # Enable the cloudproviders support
        -Dsysprof=disabled          # include tracing support for sysprof
        -Dtracker=disabled          # Enable Tracker3 filechooser search
        -Dcolord=disabled           # Build colord support for the CUPS printing backend
        -Df16c=disabled             # Enable F16C fast paths (requires F16C)
    OPTIONS_RELEASE
        ${OPTIONS_RELEASE}
    OPTIONS_DEBUG
        -Dintrospection=disabled
    ADDITIONAL_BINARIES
        glib-genmarshal='${CURRENT_HOST_INSTALLED_DIR}/tools/glib/glib-genmarshal'
        glib-mkenums='${CURRENT_HOST_INSTALLED_DIR}/tools/glib/glib-mkenums'
        glib-compile-resources='${CURRENT_HOST_INSTALLED_DIR}/tools/glib/glib-compile-resources${VCPKG_HOST_EXECUTABLE_SUFFIX}'
        gdbus-codegen='${CURRENT_HOST_INSTALLED_DIR}/tools/glib/gdbus-codegen'
        glib-compile-schemas='${CURRENT_HOST_INSTALLED_DIR}/tools/glib/glib-compile-schemas${VCPKG_HOST_EXECUTABLE_SUFFIX}'
        sassc='${CURRENT_HOST_INSTALLED_DIR}/tools/sassc/bin/sassc${VCPKG_HOST_EXECUTABLE_SUFFIX}'
        "g-ir-compiler='${GIR_COMPILER}'"
        "g-ir-scanner='${GIR_SCANNER}'"
)

vcpkg_install_meson(ADD_BIN_TO_PATH)

vcpkg_copy_pdbs()

vcpkg_fixup_pkgconfig()

vcpkg_install_copyright(FILE_LIST "${SOURCE_PATH}/COPYING")

set(TOOL_NAMES gtk4-builder-tool
               gtk4-encode-symbolic-svg
               gtk4-path-tool
               gtk4-query-settings
               gtk4-rendernode-tool
               gtk4-update-icon-cache
               gtk4-image-tool)
if(VCPKG_TARGET_IS_LINUX)
    list(APPEND TOOL_NAMES gtk4-launch)
endif()
vcpkg_copy_tools(TOOL_NAMES ${TOOL_NAMES} AUTO_CLEAN)

file(REMOVE_RECURSE "${CURRENT_PACKAGES_DIR}/debug/share")

if(VCPKG_LIBRARY_LINKAGE STREQUAL "static")
    file(REMOVE_RECURSE "${CURRENT_PACKAGES_DIR}/bin" "${CURRENT_PACKAGES_DIR}/debug/bin")
endif()
