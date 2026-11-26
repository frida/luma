import hashlib, subprocess, sys, time
from lab import *
s = state(); lab_id = s["lab"]
alice, bob, carol = Member("alice"), Member("bob"), Member("carol")
M = (alice, bob, carol)
for m in M: say(m.login, m("collab", lab=lab_id)["status"])
target = subprocess.Popen([TARGET], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL, text=True, start_new_session=True)
pid = int(target.stdout.readline())
proxy("unblock 29202")
alice("set-role", user="bob", role="owner")
bob.until("bob is an owner", lambda: any(x["id"] == "bob" and x["role"] == "owner" for x in bob("status")["members"]), 20)
sid = alice("attach", pid=pid)["session"]
alice.until("attached", lambda: any(x["id"] == sid and x["phase"] == "attached" for x in alice("sessions")["sessions"]), 30)
inst = alice("files-instrument", session=sid)["instance"]
alice.until("alice can press", lambda: alice("can-press", instance=inst, action="export")["can"], 30)
bob.until("bob can press", lambda: bob("can-press", instance=inst, action="export")["can"], 30)
w0 = {m.login: len(m("warnings")["warnings"]) for m in M}
THREE = hashlib.sha256(bytes((i * 7) % 256 for i in range(3 * 1024 * 1024))).hexdigest()
FULL = hashlib.sha256(bytes([7]) * (64 * 1024 * 1024)).hexdigest()
STREAM = hashlib.sha256(bytes([1]) * (2 << 20) + bytes([2]) * (2 << 20) + bytes([3]) * (2 << 20)).hexdigest()
def offered(m): return m("offered")["files"]
def names(m): return [f["name"] for f in offered(m)]
def saved(m, key): return m("saved")["saved"].get(key)
def log(): return alice("log", instance=inst)["log"]
def new_log(n): return log()[n:]
def save(m, key, i=0): m("save-offered", id=offered(m)[i]["id"], key=key)
def done(m, key, timeout=60): return m.until(f"{key} saved or failed", lambda: (lambda r: r if r and r["state"] != "saving" else None)(saved(m, key)), timeout)

alice("press", instance=inst, action="three")
alice.until("alice's own file", lambda: names(alice) == ["three.bin"], 20)
save(alice, "solo")
r = done(alice, "solo")
check("solo-style: the host's own press streams the file to her alone, byte for byte",
      r.get("sha256") == THREE and names(bob) == [] and names(carol) == [], (r, names(bob), names(carol)))

bob("press", instance=inst, action="three")
bob.until("bob's file", lambda: names(bob) == ["three.bin"], 20)
f = offered(bob)[0]
save(bob, "three")
r = done(bob, "three")
check("an owner who is not the host receives a 3 MiB file byte for byte, and only he",
      r.get("sha256") == THREE and f["media_type"] == "application/octet-stream" and f["instrument"] == "Files"
      and names(alice) == [] and names(carol) == [], (r, f))

bob("press", instance=inst, action="full")
bob.until("bob's 64 MiB file", lambda: names(bob) == ["full.bin"], 30)
save(bob, "full")
r = done(bob, "full", 120)
check("64 MiB arrives whole in sixteen 4 MiB chunks through host, server and member", r.get("sha256") == FULL, r)

bob("press", instance=inst, action="three")
bob("press", instance=inst, action="export")
bob.until("both of bob's offers", lambda: len(names(bob)) == 2, 20)
save(bob, "second", 1)
save(bob, "first", 0)
a, b = done(bob, "first"), done(bob, "second")
check("two presses stream alongside, each paced on its own", a.get("sha256") == THREE and b.get("size") == 8, (a, b))

n = len(log())
bob("press", instance=inst, action="stream")
bob.until("bob's stream offer", lambda: names(bob) == ["stream.bin"], 20)
time.sleep(2)
paced = new_log(n)
save(bob, "stream")
r = done(bob, "stream")
alice.until("the agent's stream to finish", lambda: "finished" in new_log(n), 20)
check("a slow receiver paces the sender: the write that fills the first chunk waits until he saves",
      paced == ["written 1"] and r.get("sha256") == STREAM and new_log(n) == ["written 1", "written 2", "written 3", "finished"], (paced, new_log(n), r))

n = len(log())
bob("press", instance=inst, action="stream")
bob.until("another stream offer", lambda: names(bob) == ["stream.bin"], 20)
bob("decline-all")
alice.until("the cancel to reach the agent", lambda: any("the file was not saved" in x for x in new_log(n)), 20)
check("a cancel in the dialog fails the agent's pending write", any(x == "stream error: Error: the file was not saved" for x in new_log(n)), new_log(n))

n = len(log())
bob("press", instance=inst, action="stream")
bob.until("a stream offer to leave", lambda: names(bob) == ["stream.bin"], 20)
time.sleep(1)
proxy("block 29202")
bob.until("bob offline", lambda: bob("status")["status"] != f"joined:{lab_id}", 20)
alice.until("the agent's write to fail", lambda: any(x.startswith("stream error") for x in new_log(n)), 30)
gone = [x for x in new_log(n) if x.startswith("stream error")]
proxy("unblock 29202"); bob("collab", lab=lab_id)
bob.until("bob back", lambda: bob("status")["status"] == f"joined:{lab_id}", 30)
time.sleep(1)
check("the member leaving mid-stream fails the agent's write, and he has no offer left", gone != [] and names(bob) == [], (gone, names(bob)))

bob.until("bob can press again", lambda: bob("can-press", instance=inst, action="streambig")["can"], 30)
n = len(log())
bob("press", instance=inst, action="streambig")
bob.until("the big stream offer", lambda: names(bob) == ["streambig.bin"], 20)
save(bob, "big")
r = done(bob, "big", 120)
alice.until("the agent to see the cap", lambda: any("RangeError" in x for x in new_log(n)), 30)
check("over the cap: the agent's write fails with a RangeError and the member keeps nothing",
      r["state"] == "failed" and not r["exists"], (r, [x for x in new_log(n) if "error" in x]))

n = len(log())
bob("press", instance=inst, action="bad")
alice.until("the refusal", lambda: any("TypeError" in x for x in new_log(n)), 20)
time.sleep(1)
check("a bad name is a TypeError in the agent, and nobody is offered anything",
      any('is not a plain file name: it contains "/"' in x for x in new_log(n)) and names(bob) == [] and names(alice) == [], new_log(n))

bob("steps", channel="mission", steps=[
    {"text": "Export it. ", "tools": [{"name": "invoke_widget_action", "args": {"session_id": sid, "instance_id": inst, "widget": "log", "action": "export"}}]},
    {"text": "Done."}])
mid = bob("mission-start", goal="Export the cube")["id"]
def action_of(m):
    found = [x for x in m("missions")["missions"] if x["id"] == mid]
    return found[0]["actions"][0] if found and found[0]["actions"] else None
proposed = alice.until("the mission's press to reach alice", lambda: action_of(alice), 30)
alice("approve", action=proposed["id"])
finished = bob.until("the mission's press to finish", lambda: (lambda a: a if a and a["result"] else None)(action_of(bob)), 30)
time.sleep(1)
check("a mission's model pressing: the file is dropped with a plain note, offered to nobody",
      "only a person can save" in finished["result"] and names(alice) == [] and names(bob) == [] and names(carol) == [], finished)

for m in M:
    new = m("warnings")["warnings"][w0[m.login]:]
    say(f"   warnings at {m.login}:", new)
alice("set-role", user="bob", role="member")
for m in M: m.quit()
target.terminate()
summary()
