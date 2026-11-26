import json, sys, time, urllib.request
from lab import *
s = state(); lab_id = s["lab"]
pid = target_pid()
alice, bob = Member("alice"), Member("bob")
for m in (alice, bob): say(m.login, m("collab", lab=lab_id)["status"])
sid = alice("attach", pid=pid)["session"]
bob.until("the session", lambda: any(x["id"] == sid and x["phase"] == "attached" for x in bob("sessions")["sessions"]), 30)
sent = alice("send-shapes", session=sid)
ids, expected = sent["ids"], sent["encoded"]
got = bob.until("bob holds every shape", lambda: (lambda r: r if r["complete"] else None)(bob("read-shapes", session=sid, ids=ids)), 30)
check("a member receives the REPL results of each kind, the trace's origin, the styled details and the Pharo snapshot exactly as sent",
      got is not None and got["encoded"] == expected, (expected, got))

cells = [json.loads(r["payload_json"]) for r in db().execute("select payload_json from session_repl_cell where lab_id=? and session_id=?", (lab_id, sid))]
results = [json.dumps(c["result"], sort_keys=True, separators=(",", ":")) for c in cells if c["id"] in ids["cells"]]
traces = [json.loads(r["payload_json"]) for r in db().execute("select payload_json from session_trace where lab_id=? and session_id=?", (lab_id, sid))]
origin = next((t["origin"] for t in traces if t["id"] == ids["trace"]), None)
entries = [json.loads(r["obj_json"]) for r in db().execute("select obj_json from notebook_entry where lab_id=?", (lab_id,))]
entry = next((e for e in entries if e["id"] == ids["entry"]), {})
check("the server stores them in the same shapes",
      sorted(results) == sorted(expected["results"]) and json.dumps(origin, sort_keys=True, separators=(",", ":")) == expected["origin"]
      and json.dumps(entry.get("styled_details"), sort_keys=True, separators=(",", ":")) == expected["styled_details"]
      and json.dumps(entry.get("pharo_snapshot"), sort_keys=True, separators=(",", ":")) == expected["pharo_snapshot"],
      (results, origin, sorted(entry)))
try:
    page = urllib.request.urlopen(f"http://127.0.0.1:8990/l/{lab_id}", timeout=10).read().decode()
except Exception as e:
    page = str(e)
check("the lab page renders the snapshot from the new keys", "Graph" in page and "pharo-text" in page and "<svg" in page, page[:300])

carol = Member("carol")
say("carol", carol("collab", lab=lab_id)["status"])
carol.until("carol to see the session", lambda: any(x["id"] == sid for x in carol("sessions")["sessions"]), 30)
late = carol.until("carol holds every shape", lambda: (lambda r: r if r["complete"] else None)(carol("read-shapes", session=sid, ids=ids)), 30)
check("a member who joins later gets them whole in the join reply", late is not None and late["encoded"] == expected, (expected, late))
problems = {m.login: (m("problems")["problems"], m("warnings")["warnings"]) for m in (alice, bob, carol)}
check("no member recorded a problem or refused anything", not any(p or w for p, w in problems.values()), problems)
alice.quit(); bob.quit(); carol.quit(); summary()
