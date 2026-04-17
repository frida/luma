@echo off
setlocal
if "%VCPKG_PREFIX%"=="" set "VCPKG_PREFIX=C:\src\vcpkg\installed\x64-windows-release"
if "%FRIDA_PREFIX%"=="" set "FRIDA_PREFIX=C:\src\dist"
set "MODE=debug"
if /i "%~1"=="release" ( set "MODE=release" & shift )
set "PATH=%VCPKG_PREFIX%\bin;%FRIDA_PREFIX%\bin;%PATH%"
"%~dp0.build\%MODE%\LumaGtk.exe" %*
