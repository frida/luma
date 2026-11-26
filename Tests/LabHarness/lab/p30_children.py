import subprocess, sys, time
from lab import *
s = state(); lab_id = s["lab"]
alice, bob, carol = Member("alice"), Member("bob"), Member("carol")
M = (alice, bob, carol)
for m in M: say(m.login, m("collab", lab=lab_id)["status"])
target = subprocess.Popen([TARGET], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL, text=True, start_new_session=True)
pid = int(target.stdout.readline())
proxy("unblock 29203")
alice("set-role", user="bob", role="owner")
bob.until("bob is an owner", lambda: any(x["id"] == "bob" and x["role"] == "owner" for x in bob("status")["members"]), 20)
sid = alice("attach", pid=pid)["session"]
alice.until("attached", lambda: any(x["id"] == sid and x["phase"] == "attached" for x in alice("sessions")["sessions"]), 30)
inst = alice("children-instrument", session=sid)["instance"]
bob.until("bob can press", lambda: bob("can-press", instance=inst, action="add")["can"], 30)
w0 = {m.login: len(m("warnings")["warnings"]) for m in M}
def kids(m): return m("kids", instance=inst)["children"]
def ids(m): return [k["id"] for k in kids(m)]

bob("press-log", instance=inst, action="add")
bob("press-log", instance=inst, action="add2")
for m in M:
    m.until(f"{m.login} sees both children", lambda: ids(m) == ["b1", "b2"] and kids(m)[0]["rows"] == ["r"] and kids(m)[0]["note"] == ["hello from b1"], 20)
k = kids(carol)[0]
check("children made by the host's agent reach every member, with their rows and their widgets' state",
      k["title"] == "first" and k["subtitle"] == "GstPipeline" and k["badge"] == {"text": "playing", "tone": "active"} and ids(bob) == ids(carol) == ["b1", "b2"], k)

bob("press-log", instance=inst, action="rename")
carol.until("the rename at carol", lambda: kids(carol)[0]["title"] == "renamed", 20)
check("an update reaches everyone in place", kids(carol)[0]["badge"]["tone"] == "waiting" and ids(carol) == ["b1", "b2"], kids(carol))

n = len(alice("log", instance=inst)["log"])
bob("press-child-row", instance=inst, template="bin", id="b1", widget="rows", action="poke", item="r")
pressed = alice.until("the child's press at the host", lambda: "pressed poke on bin/b1 row r" in alice("log", instance=inst)["log"][n:], 20)
check("a member's press on a child's widget reaches the host's agent with the child", pressed, alice("log", instance=inst)["log"][n:])

bob("press-log", instance=inst, action="show")
sel = bob.until("bob's selection", lambda: bob("selection")["selection"], 20)
time.sleep(1)
check("respond.show reaches only the member who pressed", sel == {"instance": inst, "child": {"template": "bin", "id": "b1"}}
      and alice("selection")["selection"] is None and carol("selection")["selection"] is None, (sel, alice("selection"), carol("selection")))
bob("consume-selection")

bob("press-log", instance=inst, action="remove")
for m in M:
    m.until(f"b2 gone at {m.login}", lambda: ids(m) == ["b1"], 20)
check("a removal reaches everyone", all(ids(m) == ["b1"] for m in M), {m.login: ids(m) for m in M})

proxy("block 29203")
carol.until("carol offline", lambda: carol("status")["status"] != f"joined:{lab_id}", 20)
bob("press-log", instance=inst, action="addtmp")
alice.until("t1 at alice", lambda: "t1" in ids(alice), 20)
proxy("unblock 29203"); carol("collab", lab=lab_id)
carol.until("carol back", lambda: carol("status")["status"] == f"joined:{lab_id}", 30)
carol.until("carol catches up", lambda: ids(carol) == ["b1", "t1"], 20)
check("a member who joins late sees the current set of children", kids(carol)[0]["rows"] == ["r"], kids(carol))

for m in M:
    new = m("warnings")["warnings"][w0[m.login]:]
    check(f"no warnings at {m.login}", new == [], new)
alice("set-role", user="bob", role="member")
for m in M: m.quit()
target.terminate()
summary()
