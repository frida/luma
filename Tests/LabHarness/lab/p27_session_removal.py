import subprocess, sys, time
from lab import *
s = state(); lab_id = s["lab"]
targets = []
def fresh_target():
    p = subprocess.Popen([TARGET], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL, text=True, start_new_session=True)
    targets.append(p)
    return int(p.stdout.readline())
alice, bob, carol = Member("alice"), Member("bob"), Member("carol")
M = (alice, bob, carol)
for m in M: say(m.login, m("collab", lab=lab_id)["status"])
def ids(m): return {x["id"] for x in m("sessions")["sessions"]}
def chat_ids(m): return {c["id"] for c in m("chats")["chats"]}
def srv_sessions(): return {r["id"].upper() for r in db().execute("select id from session where lab_id=?", (lab_id,)).fetchall()}
def instr(sid, n=1): return f"((LumaProject sessions items detect: [ :s | s id = '{sid}' ]) functionNamed: 'luma_target_score') pointer instruction" + " next" * n
def attach(m, others):
    sid = m("attach", pid=fresh_target())["session"]
    for o in others:
        o.until(f"{o.login} sees the session", lambda: sid in ids(o), 30)
    return sid
def refusals(m): return [w for w in m("warnings")["warnings"] if "turned a change away" in w]
start_refusals = {}

a = attach(alice, (bob, carol))
chat = alice("start-chat", code=instr(a))["id"]
alice("post", chat=chat, text="About this instruction.")
bob.until("bob has the chat", lambda: chat in chat_ids(bob), 20)
bob.until("bob's marker", lambda: bool(bob("markers", session=a)["markers"]), 20)
check("A. the host may remove her session from the lab", alice("can-remove-from-lab", session=a)["can"] and not bob("can-remove-from-lab", session=a)["can"], "")
alice("session-delete", session=a)
bob.until("bob loses the session", lambda: a not in ids(bob), 20)
check("A. the host's delete removes it for everyone: the session, its chats and its markers", a not in ids(bob) and a not in ids(carol) and chat not in chat_ids(bob)
      and not bob("markers", session=a)["markers"] and a.upper() not in srv_sessions(), (ids(bob), chat_ids(bob)))

bpid = fresh_target()
b = alice("attach", pid=bpid)["session"]
for o in (bob, carol):
    o.until(f"{o.login} sees the session", lambda: b in ids(o), 30)
alice.until("attached", lambda: any(x["id"] == b and x["phase"] == "attached" for x in alice("sessions")["sessions"]), 30)
alice("detach", session=b)
bob.until("detached", lambda: any(x["id"] == b and x["phase"] != "attached" for x in bob("sessions")["sessions"]), 30)
alice("set-role", user="bob", role="owner"); bob.until("bob is an owner", lambda: any(x["id"] == "bob" and x["role"] == "owner" for x in bob("status")["members"]), 20)
bob("claim", session=b, pid=bpid)
alice.until("bob hosts it", lambda: any(x["id"] == b and x["host"] == "bob" for x in alice("sessions")["sessions"]), 30)
alice("set-role", user="bob", role="member"); bob.until("bob is a member", lambda: any(x["id"] == "bob" and x["role"] == "member" for x in bob("status")["members"]), 20)
check("B. a lab owner may remove a session someone else hosts", alice("can-remove-from-lab", session=b)["can"], "")
alice("session-delete", session=b)
bob.until("the host loses it", lambda: b not in ids(bob), 20)
check("B. the owner's delete removes it at its host and everyone else", b not in ids(bob) and b not in ids(carol) and b.upper() not in srv_sessions(), "")

c = attach(alice, (bob, carol))
check("C. a plain member may not remove someone else's session from the lab", not carol("can-remove-from-lab", session=c)["can"], "")
carol("session-delete", session=c)
time.sleep(3)
check("C. a plain member's delete removes it only for them", c not in ids(carol) and c in ids(alice) and c in ids(bob) and c.upper() in srv_sessions(), "")
carol.quit(); carol = Member("carol"); carol("collab", lab=lab_id); time.sleep(4)
check("C. and it does not come back when they rejoin", c not in ids(carol), ids(carol))

d = attach(alice, (bob, carol))
dchat = alice("start-chat", code=instr(d, 2))["id"]
alice("post", chat=dchat, text="Here.")
bob.until("bob has it", lambda: dchat in chat_ids(bob), 20)
proxy("block 29202")
bob.until("bob offline", lambda: bob("status")["status"] != f"joined:{lab_id}", 20)
bob("post", chat=dchat, text="Typed while offline.")
alice("session-delete", session=d)
time.sleep(2)
proxy("unblock 29202"); bob("collab", lab=lab_id)
bob.until("bob back", lambda: bob("status")["status"] == f"joined:{lab_id}", 30)
time.sleep(4)
check("D. a member offline during the delete loses the session and its chats when back, and nothing queued for them is reported",
      d not in ids(bob) and dchat not in chat_ids(bob) and not refusals(bob), (ids(bob), refusals(bob)))

e = attach(alice, (bob,))
alice("steps", channel="mission", steps=[{"text": "Patching. ", "tools": [{"name": "write_memory", "args": {"session_id": e, "address": "0x1000", "bytes_hex": "00"}}]}, {"text": "Fine, it is gone."}])
mid = alice("mission-start", goal="Patch a session about to go")["id"]
alice.until("the pending action", lambda: any(x["status"] == "pending" for x in next(m for m in alice("missions")["missions"] if m["id"] == mid)["actions"]), 30)
alice("session-delete", session=e)
done = alice.until("the mission to go on", lambda: (lambda x: x if x["status"] == "completed" else None)(next(m for m in alice("missions")["missions"] if m["id"] == mid)), 30)
check("E. a tool call pending in the removed session is rejected and the mission goes on", all(x["status"] == "rejected" for x in done["actions"]), done["actions"])

fpid = fresh_target()
f = alice("attach", pid=fpid)["session"]
for o in (bob, carol):
    o.until(f"{o.login} sees the session", lambda: f in ids(o), 30)
alice.until("attached", lambda: any(x["id"] == f and x["phase"] == "attached" for x in alice("sessions")["sessions"]), 30)
alice("detach", session=f)
bob.until("detached", lambda: any(x["id"] == f and x["phase"] != "attached" for x in bob("sessions")["sessions"]), 30)
alice("set-role", user="bob", role="owner"); bob.until("bob is an owner", lambda: any(x["id"] == "bob" and x["role"] == "owner" for x in bob("status")["members"]), 20)
bob("claim", session=f, pid=fpid)
alice.until("bob hosts it", lambda: any(x["id"] == f and x["host"] == "bob" for x in alice("sessions")["sessions"]), 30)
alice("set-role", user="bob", role="member"); bob.until("bob is a member", lambda: any(x["id"] == "bob" and x["role"] == "member" for x in bob("status")["members"]), 20)
w0 = len(bob("warnings")["warnings"])
proxy("block 29202")
bob.until("bob offline", lambda: bob("status")["status"] != f"joined:{lab_id}", 20)
bob("instance-add", session=f, descriptor="tracer")
alice("session-delete", session=f)
time.sleep(2)
proxy("unblock 29202"); bob("collab", lab=lab_id)
bob.until("bob back", lambda: bob("status")["status"] == f"joined:{lab_id}", 30)
time.sleep(6)
new = bob("warnings")["warnings"][w0:]
check("F. the host offline during the owner's removal ends without the session, still connected, told once and refused nothing",
      f not in ids(bob) and bob("status")["status"] == f"joined:{lab_id}" and len(new) == 1 and "you were hosting was removed" in new[0], new)

for m in (alice, bob, carol):
    check(f"nothing refused at {m.login}", not refusals(m), refusals(m))
for m in (alice, bob, carol): m.quit()
for p in targets: p.terminate()
summary()
