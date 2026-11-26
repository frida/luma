import subprocess, sys, time
from lab import *
s = state(); lab_id = s["lab"]
alice, bob, carol = Member("alice"), Member("bob"), Member("carol")
for m in (alice, bob, carol): say(m.login, m("collab", lab=lab_id)["status"])
alice("set-role", user="bob", role="owner")
bob.until("bob is an owner", lambda: any(x["id"] == "bob" and x["role"] == "owner" for x in bob("status")["members"]), 20)
target = subprocess.Popen([TARGET], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL, text=True, start_new_session=True)
pid = int(target.stdout.readline())
sid = alice("attach", pid=pid)["session"]
alice.until("attached", lambda: any(x["id"] == sid and x["phase"] == "attached" for x in alice("sessions")["sessions"]), 30)
def_id = bob("gated-def")["def"]
alice.until("bob's instrument at alice", lambda: alice("descriptor", id=f"custom:{def_id}").get("found"), 30)
inst = alice("instance-add", session=sid, descriptor=f"custom:{def_id}")["instance"]
def gate(m, i=None): return m("gate", instance=i or inst)
carol.until("carol knows the instance", lambda: gate(carol)["known"], 30)
a = alice.until("alice gated", lambda: (lambda x: x if x["gate"] == "you" else None)(gate(alice)), 30)
check("the host only ever waits for herself", a["gate"] == "you" and a["waiting"] == "Waiting for you to allow", a)
b = carol.until("carol waits for the host", lambda: (lambda x: x if x["gate"] == "host:Alice" else None)(gate(carol)), 20)
check("a member waits for the host first, whatever his own approval", b["waiting"] == "Waiting for Alice to allow" and b["shown_children"] == [], b)
carol("allow", instance=inst)
time.sleep(1)
check("a member cannot allow while the host has not", gate(carol)["gate"] == "host:Alice", gate(carol))

alice("allow", instance=inst)
alice.until("alice's agent to run", lambda: (lambda x: x["gate"] == "none" and x["shown_children"] == ["p1"])(gate(alice)), 30)
b = carol.until("carol's own gate", lambda: (lambda x: x if x["gate"] == "you" and x["children"] == ["p1"] and x["log"] == ["created"] else None)(gate(carol)), 30)
check("once the host allows, the member gets his own prompt; what the lab sent is kept but not shown", b is not None and b["shown_children"] == [], b)

dave = Member("dave")
say("dave", dave("collab", lab=lab_id)["status"])
c = dave.until("dave joins late", lambda: (lambda x: x if x["known"] and x["children"] == ["p1"] else None)(gate(dave)), 30)
check("a member who joins late keeps the children the join reply carries, behind her own gate", c is not None and c["gate"] == "you" and c["shown_children"] == [], c)
dave("allow", instance=inst)
c = dave.until("dave allowed", lambda: (lambda x: x if x["gate"] == "none" else None)(gate(dave)), 20)
check("when she allows, everything the lab already sent is there, without a rejoin", c is not None and c["shown_children"] == ["p1"] and c["log"] == ["created"], c)
carol("allow", instance=inst)
b = carol.until("carol allowed", lambda: (lambda x: x if x["gate"] == "none" else None)(gate(carol)), 20)
check("and the same for the member who waited from the start", b is not None and b["shown_children"] == ["p1"], b)

second = alice("instance-add", session=sid, descriptor=f"custom:{def_id}")["instance"]
b = carol.until("the second instance at carol", lambda: (lambda x: x if x["known"] and x["gate"] == "none" else None)(gate(carol, second)), 30)
check("a member who already approved the same code goes straight through once the host has", b is not None, b)
for m in (alice, bob, carol, dave): m.quit()
target.kill()
summary()
