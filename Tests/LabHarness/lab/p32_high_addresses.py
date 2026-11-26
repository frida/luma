import json, subprocess, sys, time
from lab import *
s = state(); lab_id = s["lab"]
alice, bob = Member("alice"), Member("bob")
for m in (alice, bob): say(m.login, m("collab", lab=lab_id)["status"])
target = subprocess.Popen([TARGET], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL, text=True, start_new_session=True)
pid = int(target.stdout.readline())
sid = alice("attach", pid=pid)["session"]
alice.until("attached", lambda: any(x["id"] == sid and x["phase"] == "attached" for x in alice("sessions")["sessions"]), 30)
HIGHS = ["0xffffffffffffffff", "0x8000000000000000", "0x7fffffffffffffff"]
ids = alice("high-insights", session=sid)["insights"]
def anchors(m): return {i["id"]: (i["anchor"], i["last"]) for i in m("insight-anchors", session=sid)["insights"] if i["id"] in ids}
mine = alice.until("alice's insights", lambda: (lambda x: x if len(x) == 3 else None)(anchors(alice)), 20)
check("the host keeps each anchor exactly", sorted(a["address"] for a, _ in mine.values()) == sorted(HIGHS)
      and sorted(l for _, l in mine.values()) == sorted(HIGHS), mine)
theirs = bob.until("bob's insights", lambda: (lambda x: x if len(x) == 3 else None)(anchors(bob)), 30)
check("a member receives them exactly, through the server", theirs == mine, (mine, theirs))
bob.quit(); bob = Member("bob"); bob("collab", lab=lab_id)
bob.until("bob back", lambda: bob("status")["status"] == f"joined:{lab_id}", 30)
again = bob.until("bob's insights after rejoining", lambda: (lambda x: x if len(x) == 3 else None)(anchors(bob)), 30)
check("and exactly again from the join reply", again == mine, again)
stored = [row[0] for row in db().execute("select payload_json from session_insight").fetchall()] if any(
    r[0] == "session_insight" for r in db().execute("select name from sqlite_master where type='table'").fetchall()) else []
text = " ".join(stored)
check("the server stores the canonical strings", all(h in text for h in HIGHS) and "9223372036854775807" not in text and "-1," not in text, text[:400])
for m in (alice, bob):
    w = [x for x in m("warnings")["warnings"] if "turned a change away" in x]
    check(f"nothing refused at {m.login}", not w, w)
alice.quit(); bob.quit(); target.terminate()
summary()
