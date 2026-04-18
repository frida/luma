@echo off
setlocal EnableDelayedExpansion

if "%VCPKG_PREFIX%"=="" set "VCPKG_PREFIX=C:\src\vcpkg\installed\x64-windows-release"
if "%FRIDA_PREFIX%"=="" set "FRIDA_PREFIX=C:\src\dist"

set "MODE=debug"
if /i "%~1"=="release" ( set "MODE=release" & shift )
if /i "%~1"=="debug"   ( set "MODE=debug"   & shift )

set "ARGS="
:collect
if "%~1"=="" goto run
set ARGS=!ARGS! %1
shift
goto collect
:run

set "PATH=%VCPKG_PREFIX%\bin;%VCPKG_PREFIX%\tools;%FRIDA_PREFIX%\bin;%PATH%"
set "GDK_PIXBUF_MODULE_FILE=%VCPKG_PREFIX%\lib\gdk-pixbuf-2.0\2.10.0\loaders.cache"
if defined XDG_DATA_DIRS (
    set "XDG_DATA_DIRS=%VCPKG_PREFIX%\share;%XDG_DATA_DIRS%"
) else (
    set "XDG_DATA_DIRS=%VCPKG_PREFIX%\share"
)

rem /SUBSYSTEM:WINDOWS means cmd doesn't wait for the exe by default;
rem use `start /wait` so run.bat blocks until LumaGtk exits.
start "Luma" /wait "%~dp0.build\%MODE%\LumaGtk.exe" %ARGS%
