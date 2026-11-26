import json, os, shutil, sys, time
from lab import *
s = state(); lab_id = s["lab"]
folder = f"{L}/run/over-cap"
shutil.rmtree(folder, ignore_errors=True)
os.makedirs(folder)
with open(f"{folder}/package.json", "w") as f:
    f.write('{ "name": "over-cap", "displayName": "Over Cap", "version": "1.0.0", "main": "main.ts", "engines": { "luma": ">=4.0.0" }, '
            '"luma": { "settings": [], "widgets": [{ "id": "log", "name": "Log", "kind": "console", "config": {} }] } }')
with open(f"{folder}/main.ts", "w") as f:
    f.write('export const instrument: CustomInstrument = { create(ctx) { ctx.widget("log").appendOutput("running"); return {}; } };\n')
for i in range(300):
    with open(f"{folder}/part{i}.ts", "w") as f:
        f.write(f"export const n = {i};\n")
def srv_defs():
    return [r["def_id"].upper() for r in db().execute("select def_id from custom_instrument_def where lab_id=?", (lab_id,))]
def srv_instances(sid):
    return [r[0].upper() for r in db().execute("select id from session_instrument where lab_id=? and upper(session_id)=?", (lab_id, sid))]
pid = target_pid()
alice = Member("alice")
say("alice", alice("collab", lab=lab_id)["status"])
sid = alice("attach", pid=pid)["session"]
d = alice("instr-link", path=folder)["def"]
st = alice("def-state", **{"def": d})
check("an over-cap folder links on its first link and is kept from the lab with the cap as its reason",
      st["stored"] and st["kept_from_lab"] and any("has 301 files; a lab takes at most 256" in r for r in st["lab_problems"]), st)
inst = alice("instance-add", session=sid, descriptor=f"custom:{d}")["instance"]
time.sleep(4)
mine = [i for i in alice("instances", session=sid)["instances"] if i["id"] == inst]
check("its instance runs on the host", len(mine) == 1, mine)
check("neither the definition nor its instance reaches the lab", d.upper() not in srv_defs() and inst.upper() not in srv_instances(sid.upper()),
      (srv_defs(), srv_instances(sid.upper())))
for i in range(300):
    os.remove(f"{folder}/part{i}.ts")
alice("instr-reload", **{"def": d})
st = alice.until("the trimmed definition in the lab", lambda: (lambda x: x if not x["kept_from_lab"] and d.upper() in srv_defs() else None)(alice("def-state", **{"def": d})), 30)
check("once a reload brings it within the caps it is offered to the lab, and its notice goes",
      st is not None and not any("Over Cap" in r for r in st["lab_problems"]), st)
alice.quit(); summary()
