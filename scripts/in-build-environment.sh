#!/bin/sh
set -euf

unix_variables="HOME USER LOGNAME TMPDIR LANG LC_ALL LC_CTYPE XDG_CACHE_HOME XDG_CONFIG_HOME"
proxy_variables="http_proxy https_proxy no_proxy all_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY ALL_PROXY"
toolchain_variables="DEVELOPER_DIR SDKROOT TOOLCHAINS SWIFTLY_HOME_DIR SWIFTLY_BIN_DIR SWIFTLY_TOOLCHAINS_DIR"
variables_the_build_reads="PKG_CONFIG_PATH PKG_CONFIG_ALLOW_SYSTEM_CFLAGS PKG_CONFIG_ALLOW_SYSTEM_LIBS USE_SYSTEM_FRIDA
    FRIDA_SWIFT_ROOT LUMA_FRIDA_DEVKIT LUMA_VERSION SHADER_TOOLCHAIN_ROOT PHARO_VM_ROOT SQLITE_ENABLE_PREUPDATE_HOOK
    GIR_EXTRA_SEARCH_PATH"

for name in $unix_variables $proxy_variables $toolchain_variables $variables_the_build_reads; do
    eval "is_set=\${$name+yes}"
    if [ "$is_set" = yes ]; then
        eval "value=\$$name"
        set -- "$name=$value" "$@"
    fi
done

searched_directories=
IFS=:
for directory in $PATH; do
    [ -d "$directory" ] || continue
    case ":$searched_directories:" in
        *":$directory:"*) ;;
        *) searched_directories=${searched_directories:+$searched_directories:}$directory ;;
    esac
done

exec env -i PATH="$searched_directories" "$@"
