#!/bin/sh
cd "$(dirname "$0")"
L=$PWD
export XDG_CACHE_HOME="$L/run/cache"
PY=${PYTHON:-python3}
./stop.sh
rm -rf run && mkdir -p run "$XDG_CACHE_HOME"
"$PY" -u "$L/proxy.py" 29200 29201 29202 29203 29204 > run/proxy.out 2>&1 &
disown
"$PY" -c "import lab; lab.start_server()" || exit 1
scripts=${*:-"p1_conversation p5_objectchat p6_v2 p7_history p11_o1 p20_show_subject p21_instruction_chats p22_choices p23_mac_repro p26_instruments p27_session_removal p28_local_session p29_offered_files p30_children p31_gate p32_high_addresses p33_shapes p34_ask_race p35_counters p37_gate_order p38_over_cap_link p39_new_pid p40_chat_delete"}
status=0
for p in $scripts; do
  p=${p%.py}
  perl -e 'alarm shift; exec @ARGV' 1500 "$PY" -u "$p.py" > "run/$p.out" 2>&1
  code=$?
  [ $code -eq 0 ] || status=1
  echo "$p exit $code $(grep -E '^== ' "run/$p.out" | tail -1) $(grep -E '^FAIL|^[A-Za-z]+Error' "run/$p.out" | head -1 | cut -c1-200)"
done
./stop.sh
exit $status
