#!/bin/sh
cd "$(dirname "$0")"
L=$PWD
BUILD=${LAB_HARNESS_BUILD:-$(cd .. && pwd)/.build/debug}
pkill -f "$BUILD/LabCheck"
pkill -f "LumaServer --control-port 29442"
pkill -f "$L/proxy.py"
pkill -f "$BUILD/LabTarget"
pkill -f "$L/run/cache/frida"
sleep 2
rm -rf "$L/run/cache"
exit 0
