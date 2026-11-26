# Lab harness

Checks that drive LumaCore as the apps do, alone and as several members
of one lab. macOS only. Nothing here is built by the root package, `make`
or CI; build it here when you want it.

## What is here

- `ChatCheck` runs one suite per invocation: object chats, labs as the
  client sees them, instruments, persistence, throughput. Each check prints
  `PASS` or `FAIL`; the process exits non-zero on any `FAIL` and on any wait
  that times out.
- `LabCheck` is one lab member per process, driven over stdin and stdout
  by the lab scripts.
- `LabTarget` is the process the checks attach to. It exports
  `luma_target_score`. The package builds it at `-O1`, and `live` and
  `reopen` expect the instructions that produces; build it only with
  `swift build` here.
- `Fixtures/` holds projects made by older Luma versions.
- `lab/` holds `lab.py` (members, waits, checks, the server and its
  database), `proxy.py` (sits between each member and the server, counts
  and blocks traffic), `lumaclient.py` (a raw protocol client) and the lab
  scripts `p*.py`, each a story told by two or three members.

The only model provider is the scripted one in `ChatCheck` and
`LabCheck`. It answers from a list each check sets and never calls a real
model. Do not add another.

## What it needs

- Xcode's Swift toolchain, as for the app, and in a fresh checkout one
  run of `Scripts/generate-sources.sh` at the root, which writes the
  generated sources and stages the Pharo image.
- For the lab scripts, `luma-server` built with test authentication,
  which takes a token `user:<login>:<id>` as that identity. Build it in a
  `luma-server` checkout with `swift build -Xswiftc -DLUMA_TEST_AUTH`
  and set `LUMA_SERVER` to the `LumaServer` it built.
- Python 3.9 or later. `p5`, `p6` and `p7` also need the `frida` module.
  Set `PYTHON` to pick an interpreter.
- Ports 29200 to 29204, 29442, 29452 and 8990 free.

Optional, for the suites that use them (they are reported as skipped,
and the run fails, without them):

- `LUMA_INSTRUMENTS`: a `luma-instruments` checkout (`live`, `reopen`,
  `st-probe`).
- `LUMA_WIRE_RECORD`: `docs/lab-protocol-4.md` in a `luma-server`
  checkout (`labs`, `solo-reopen`).

`LAB_HARNESS_BUILD` names the build products' directory, as an absolute
path, when it is not `.build/debug` here.

## Running

With a `luma-server` checkout beside this one, build the server once and
point the harness at it in each shell:

```sh
(cd ../../../luma-server && swift build -Xswiftc -DLUMA_TEST_AUTH)
export LUMA_SERVER=$PWD/../../../luma-server/.build/debug/LumaServer
export LUMA_WIRE_RECORD=$PWD/../../../luma-server/docs/lab-protocol-4.md
```

Then:

```sh
swift build
./suites.sh                     # every ChatCheck suite, about 3 minutes
./suites.sh teardown delete-ops # some
lab/run.sh                      # every lab script, about 11 minutes
lab/run.sh p40_chat_delete      # one
```

Each prints a line per suite or script and exits non-zero if any failed.
Output is in `runs/` and `lab/run/`. `reopen` and `labs` use what `live`
left, and `solo-reopen` and `members` what `solo` left, so run them after
it or with everything. `lab/stop.sh` stops what a lab run left behind.

A lab script fails on a check that does not hold and on a wait that runs
out; a check about another member or the server looks at that member or
the server.
