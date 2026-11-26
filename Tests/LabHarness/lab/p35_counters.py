import json, sys, time
from lab import *
s = state(); lab_id = s["lab"]
pid = target_pid()
alice, bob = Member("alice"), Member("bob")
for m in (alice, bob): say(m.login, m("collab", lab=lab_id)["status"])
sid = alice("attach", pid=pid)["session"]
bob.until("the session", lambda: any(x["id"] == sid and x["phase"] == "attached" for x in bob("sessions")["sessions"]), 30)
d = alice("counter-instr")["def"]
time.sleep(2)
inst = alice("instance-add", session=sid, descriptor=f"custom:{d}")["instance"]
final = lambda m: (lambda c: c if c and c["unit"] == "KiB" else None)(m("counter-text", instance=inst)["counter"])
mine = alice.until("the host's last counter", lambda: final(alice), 30)
check("the host shows a counter with fractionDigits 1 as 1.0, and refused the one with 7", mine is not None and mine["text"] == "1.0" and mine["fraction_digits"] == 1, mine)
theirs = bob.until("bob's last counter", lambda: final(bob), 30)
check("a member receives fraction_digits and shows the same text", theirs is not None and theirs["text"] == "1.0" and theirs["fraction_digits"] == 1, theirs)
time.sleep(3)
rows = [json.loads(r["state_json"]) for r in db().execute("select state_json from session_widget_state where lab_id=?", (lab_id,))]
stored = next((r["counter"] for r in rows if (r.get("counter") or {}).get("unit") == "KiB"), None)
check("the server stores fraction_digits with the counter", stored is not None and stored.get("fraction_digits") == 1, rows)
carol = Member("carol")
say("carol", carol("collab", lab=lab_id)["status"])
late = carol.until("carol's counter", lambda: final(carol), 30)
check("a member who joins later gets it in the join reply", late is not None and late["text"] == "1.0" and late["fraction_digits"] == 1, late)
problems = {m.login: (m("problems")["problems"], m("warnings")["warnings"]) for m in (alice, bob, carol)}
check("nobody was disconnected or refused anything", not any(p or w for p, w in problems.values()), problems)
alice.quit(); bob.quit(); carol.quit(); summary()
