import subprocess, sys, time
from lab import *
s = state(); lab_id = s["lab"]
alice, bob, carol = Member("alice"), Member("bob"), Member("carol")
M = (alice, bob, carol)
for m in M: say(m.login, m("collab", lab=lab_id)["status"])
target = subprocess.Popen([TARGET], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL, text=True, start_new_session=True)
pid = int(target.stdout.readline())
alice("set-role", user="bob", role="owner")
bob.until("bob is an owner", lambda: any(x["id"] == "bob" and x["role"] == "owner" for x in bob("status")["members"]), 20)
sid = alice("attach", pid=pid)["session"]
alice.until("attached", lambda: any(x["id"] == sid and x["phase"] == "attached" for x in alice("sessions")["sessions"]), 30)
w0 = {m.login: len(m("warnings")["warnings"]) for m in M}

def_id = bob("gated-def")["def"]
alice.until("bob's instrument at alice", lambda: alice("descriptor", id=f"custom:{def_id}").get("found"), 30)
inst = alice("instance-add", session=sid, descriptor=f"custom:{def_id}")["instance"]
def gate(m): return m("gate", instance=inst)
for m in M:
    m.until(f"{m.login} knows the instance", lambda: gate(m)["known"], 30)
g = alice.until("alice gated", lambda: (lambda x: x if x["wanted"] else None)(gate(alice)), 30)
time.sleep(2)
g = gate(alice)
check("at the host, code a lab member wrote is gated: its agent is not loaded, so its create never ran",
      g["wanted"] == "Bob added or changed it in the lab." and not g["attached"] and g["children"] == [] and g["log"] == [] and not g["can_ping"], g)
c = carol.until("carol sees the host waiting", lambda: (lambda x: x if x["awaits_host"] else None)(gate(carol)), 20)
check("a member can tell the host has not allowed it yet, and is gated herself", c["awaits_host"] == "Alice" and c["wanted"] is not None, c)
b = gate(bob)
check("the author is not gated on his own Luma, and sees the host waiting", b["wanted"] is None and b["awaits_host"] == "Alice", b)

alice("allow", instance=inst)
alice.until("alice's agent to run", lambda: (lambda x: x["attached"] and x["children"] == ["p1"])(gate(alice)), 30)
c = carol.until("state at carol", lambda: (lambda x: x if x["children"] == ["p1"] and x["log"] == ["created"] else None)(gate(carol)), 30)
check("once the host allows, its agent runs; a member who has not allowed still receives the state, while her own gate holds",
      c["wanted"] is not None and c["awaits_host"] is None and not c["can_ping"], c)
carol("allow", instance=inst)
carol.until("carol allowed", lambda: gate(carol)["wanted"] is None, 20)
check("when she allows, her own gate opens", gate(carol)["wanted"] is None, gate(carol))

bob("edit-gated-def", **{"def": def_id})
alice.until("alice gated again", lambda: (lambda x: x if x["wanted"] and not x["attached"] else None)(gate(alice)), 30)
carol.until("carol gated again", lambda: gate(carol)["wanted"] is not None, 30)
time.sleep(1)
b = gate(bob)
check("a definition another member edits after approval gates again on every other Luma, and the host's agent stops until the host allows",
      gate(alice)["wanted"] == "Bob added or changed it in the lab." and b["wanted"] is None and b["awaits_host"] == "Alice", (gate(alice), b))
alice("allow", instance=inst)
alice.until("alice runs again", lambda: gate(alice)["attached"], 30)
check("and runs again when the host allows", gate(bob)["awaits_host"] is None, gate(bob))

for m in M:
    new = [w for w in m("warnings")["warnings"][w0[m.login]:] if "waiting for" not in w]
    check(f"no other warnings at {m.login}", new == [], new)
alice("set-role", user="bob", role="member")
for m in M: m.quit()
target.terminate()
summary()
