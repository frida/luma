import json, sys, time
from lab import *
s = state(); lab_id = s["lab"]
pid = target_pid()
proxy("reset")
alice, bob = Member("alice"), Member("bob")
for m in (alice, bob): say(m.login, m("collab", lab=lab_id)["status"])
sid = alice("attach", pid=pid)["session"]
bob.until("the session", lambda: any(x["id"] == sid and x["phase"] == "attached" for x in bob("sessions")["sessions"]), 30)
d = alice("instr-rich", name="Every Setting")["def"]
shape = alice("instr-shape", **{"def": d})["shape"]
bob.until("bob has the definition", lambda: bob("instr-shape", **{"def": d})["shape"] is not None, 20)
check("a definition with settings of every kind and widgets with actions reaches the other member unchanged", bob("instr-shape", **{"def": d})["shape"] == shape, (shape, bob("instr-shape", **{"def": d})["shape"]))
row = db().execute("select obj_json from custom_instrument_def where lab_id=? and def_id=?", (lab_id, d.upper())).fetchone() or db().execute("select obj_json from custom_instrument_def where lab_id=? and lower(def_id)=?", (lab_id, d.lower())).fetchone()
stored = json.loads(row["obj_json"]) if row else {}
ports = next((x for x in stored.get("settings", []) if x["id"] == "ports"), {})
rules = next((x for x in stored.get("settings", []) if x["id"] == "rules"), {})
check("the server holds settings, plain array defaults and one spelling", "features" not in stored and ports.get("schema", {}).get("default") == [80, 443]
      and rules.get("schema", {}).get("default") == [{"depth": 5}] and "enabled_by_default" in rules, (sorted(stored), ports, rules))
custom = alice("instance-add", session=sid, descriptor=f"custom:{d}")["instance"]
tracer = alice("tracer-with-hook", session=sid)["instance"]
codeshare = alice("codeshare-add", session=sid)["instance"]
time.sleep(4)
mine = {i["id"]: i for i in alice("instances", session=sid)["instances"]}
bob.until("bob has all three instances", lambda: {custom, tracer, codeshare} <= {i["id"] for i in bob("instances", session=sid)["instances"]}, 30)
theirs = {i["id"]: i for i in bob("instances", session=sid)["instances"]}
check("a custom instrument's, the tracer's and Code Share's config reach the other member unchanged", all(theirs[x]["config"] == mine[x]["config"] for x in (custom, tracer, codeshare)), (mine, theirs))
hook = json.loads(theirs[tracer]["config"])["hooks"][0]
share = json.loads(theirs[codeshare]["config"])
check("the tracer's and Code Share's config travel in snake case at every depth",
      sorted(json.loads(theirs[tracer]["config"])) == ["hooks", "thread_traces"] and {"display_name", "address_anchor", "last_edited_at"} <= set(hook)
      and not {"displayName", "addressAnchor", "lastEditedAt"} & set(hook)
      and {"last_synced_hash", "frida_version", "allow_remote_updates"} <= set(share) and "allowRemoteUpdates" not in share, (hook, share))
bob.quit(); bob = Member("bob"); bob("collab", lab=lab_id); time.sleep(4)
again = {i["id"]: i for i in bob("instances", session=sid)["instances"]}
check("and after a rejoin", all(again.get(x, {}).get("config") == mine[x]["config"] for x in (custom, tracer, codeshare)) and bob("instr-shape", **{"def": d})["shape"] == shape, again)
def keys_of(cfg): return sorted(json.loads(cfg).keys())
check("a custom instance's config arrives as exactly {def_id, settings}, at the other member and after a rejoin",
      keys_of(theirs[custom]["config"]) == ["def_id", "settings"] and keys_of(again[custom]["config"]) == ["def_id", "settings"], (theirs[custom]["config"], again[custom]["config"]))
bad = {}
con = db()
for (table,) in con.execute("select name from sqlite_master where type='table'").fetchall():
    for row in con.execute(f"select * from {table}").fetchall():
        for value in row:
            if isinstance(value, str):
                for key in ('"features"', '"defID"', '"enabledByDefault"', '"config_json"', '"pending_user_text"', '"displayName"', '"addressAnchor"',
                            '"threadTraces"', '"lastEditedAt"', '"lastSyncedHash"', '"allowRemoteUpdates"', '"fridaVersion"'):
                    if key in value:
                        bad.setdefault(table, set()).add(key)
check("the server's stored JSON has none of the old spellings anywhere, tracer and Code Share keys included", not bad, {k: sorted(v) for k, v in bad.items()})
for m in (alice, bob):
    w = m("warnings")["warnings"]
    check(f"nothing refused at {m.login}", not [x for x in w if "turned a change away" in x], w[-4:])
alice.quit(); bob.quit(); summary()
