#!/bin/bash
cd "$(dirname "$0")"
H=$PWD
BUILD=${LAB_HARNESS_BUILD:-$H/.build/debug}
R=$H/runs
export XDG_CACHE_HOME=$R/cache
all="live reopen labs teardown teardown-cold delete-ops solo solo-reopen members merge missions removals files children banner configs edits store batching marker refusals provider-errors st-probe"
suites=${*:-$all}
[ $# -eq 0 ] && rm -rf "$R"
mkdir -p "$XDG_CACHE_HOME"
"$BUILD/LabTarget" > "$R/target-pid.txt" &
disown
sleep 1
P=$(head -1 "$R/target-pid.txt")
status=0

run() {
  name=$1
  limit=$2
  shift 2
  perl -e 'alarm shift; exec @ARGV' "$limit" "$BUILD/ChatCheck" "$@" > "$R/$name.txt" 2>&1
  code=$?
  [ $code -eq 0 ] || status=1
  echo "$name exit $code pass $(grep -c '^PASS' "$R/$name.txt")"
  grep '^FAIL' "$R/$name.txt" | cut -c1-250
}

skip() {
  echo "$1 skipped: $2 is not set"
  status=1
}

for s in $suites; do
  case $s in
    live) if [ -n "$LUMA_INSTRUMENTS" ]; then run live 240 live "$R/chatproject" $P "$LUMA_INSTRUMENTS/gstreamer"; else skip live LUMA_INSTRUMENTS; fi ;;
    reopen) if [ -n "$LUMA_INSTRUMENTS" ]; then run reopen 240 reopen "$R/chatproject" "$LUMA_INSTRUMENTS/gstreamer"; else skip reopen LUMA_INSTRUMENTS; fi ;;
    labs) if [ -n "$LUMA_WIRE_RECORD" ]; then run labs 240 labs "$R/chatproject" "$R/peerproject" "$LUMA_WIRE_RECORD"; else skip labs LUMA_WIRE_RECORD; fi ;;
    teardown) run teardown 240 teardown "$R/teardownproject" $P ;;
    teardown-cold) run teardown-cold 120 teardown-cold "$R/coldproject" ;;
    delete-ops) run delete-ops 120 delete-ops "$R/deleteopsproject" ;;
    solo) run solo 240 solo "$R/convo" ;;
    solo-reopen) if [ -n "$LUMA_WIRE_RECORD" ]; then run solo-reopen 240 solo-reopen "$R/convo" "$LUMA_WIRE_RECORD"; else skip solo-reopen LUMA_WIRE_RECORD; fi ;;
    members) CHAT_MEMBER=alice run members 240 members "$R/convo" "$R/convo-b" ;;
    merge) run merge 240 merge "$R/mergeproject" ;;
    missions) CHAT_MEMBER=alice run missions 240 missions "$R/missionsproject" "$R/missionsproject-b" ;;
    removals) CHAT_MEMBER=alice run removals 240 removals "$R/removalsproject" ;;
    files) run files 300 files "$R/filesproject" $P ;;
    children) run children 300 children "$R/childrenproject" $P ;;
    banner) run banner 300 banner "$R/bannerproject" $P ;;
    configs) run configs 300 configs "$R/configsproject" $P ;;
    edits) run edits 300 edits "$R/editsproject" $P ;;
    store) run store 120 store "$R/storecheck" ;;
    batching) run batching 200 batching "$R/batchproject" $P ;;
    marker) run marker 1200 marker "$R/markerproject" $P 250 ;;
    refusals) run refusals 200 refusals "$R/refusalsproject" ;;
    provider-errors) run provider-errors 60 provider-errors "$R/providerproject" ;;
    st-probe) if [ -n "$LUMA_INSTRUMENTS" ]; then run st-probe 200 st-probe "$R/probeproject" "$LUMA_INSTRUMENTS/mesh-finder/MeshView.class.st"; else skip st-probe LUMA_INSTRUMENTS; fi ;;
    *) echo "$s: no such suite"; status=1 ;;
  esac
done
kill $P
pkill -f "$XDG_CACHE_HOME/frida"
sleep 1
rm -rf "$XDG_CACHE_HOME"
exit $status
