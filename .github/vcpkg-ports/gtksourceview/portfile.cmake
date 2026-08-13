vcpkg_check_linkage(ONLY_DYNAMIC_LIBRARY)

string(REGEX MATCH [[^[0-9][0-9]*\.[1-9][0-9]*]] VERSION_MAJOR_MINOR ${VERSION})
vcpkg_download_distfile(ARCHIVE
    URLS
        "https://download.gnome.org/sources/${PORT}/${VERSION_MAJOR_MINOR}/${PORT}-${VERSION}.tar.xz"
        "https://www.mirrorservice.org/sites/ftp.gnome.org/pub/GNOME/sources/${PORT}/${VERSION_MAJOR_MINOR}/${PORT}-${VERSION}.tar.xz"
    FILENAME "GNOME-${PORT}-${VERSION}.tar.xz"
    SHA512 d0d25ab7098d6626bde49bbd5c29986838f0958cd3e31b5cab74016eb37a4caea3351be9ce4268464a8d1cb42b10b698aa819b215f652c8c97382e0900df7893
)

vcpkg_extract_source_archive(SOURCE_PATH
    ARCHIVE "${ARCHIVE}"
    PATCHES
        0001-drop-icon-cache-post-install.patch
)

set(GLIB_TOOLS_DIR "${CURRENT_HOST_INSTALLED_DIR}/tools/glib")

vcpkg_find_acquire_program(PKGCONFIG)
get_filename_component(PKGCONFIG_DIR "${PKGCONFIG}" DIRECTORY)
vcpkg_add_to_path("${PKGCONFIG_DIR}")
vcpkg_add_to_path("${GLIB_TOOLS_DIR}")

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

if("introspection" IN_LIST FEATURES)
    list(APPEND OPTIONS_RELEASE -Dintrospection=enabled)
    vcpkg_get_gobject_introspection_programs(PYTHON3 GIR_COMPILER GIR_SCANNER)
else()
    list(APPEND OPTIONS_RELEASE -Dintrospection=disabled)
endif()

vcpkg_configure_meson(
    SOURCE_PATH ${SOURCE_PATH}
    OPTIONS
        -Dbuild-testsuite=false
        -Dinstall-tests=false
        -Ddocumentation=false
        -Dsysprof=false
        -Dvapi=false
    OPTIONS_RELEASE
        ${OPTIONS_RELEASE}
    OPTIONS_DEBUG
        -Dintrospection=disabled
    ADDITIONAL_BINARIES
        glib-genmarshal='${GLIB_TOOLS_DIR}/glib-genmarshal'
        glib-mkenums='${GLIB_TOOLS_DIR}/glib-mkenums'
        glib-compile-resources='${GLIB_TOOLS_DIR}/glib-compile-resources${VCPKG_HOST_EXECUTABLE_SUFFIX}'
        glib-compile-schemas='${GLIB_TOOLS_DIR}/glib-compile-schemas${VCPKG_HOST_EXECUTABLE_SUFFIX}'
        "g-ir-compiler='${GIR_COMPILER}'"
        "g-ir-scanner='${GIR_SCANNER}'"
)

vcpkg_install_meson(ADD_BIN_TO_PATH)
vcpkg_copy_pdbs()
vcpkg_fixup_pkgconfig()
vcpkg_install_copyright(FILE_LIST "${SOURCE_PATH}/COPYING")
file(REMOVE_RECURSE "${CURRENT_PACKAGES_DIR}/debug/share")
