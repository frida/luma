#!/bin/sh
L=$(cd "$(dirname "$0")" && pwd)
exec "${LUMA_SERVER:?set LUMA_SERVER to a LumaServer built with -Xswiftc -DLUMA_TEST_AUTH}" --control-port 29442 --cluster-port 29452 --browser-port 8990 --database-path "$L/run/luma.db" --vapid-key-path "$L/run/vapid.pem" >> "$L/run/server.log" 2>&1
