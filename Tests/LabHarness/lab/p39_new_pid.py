import json, os, subprocess, sys, time
from lab import *
s = state(); lab_id = s["lab"]
first = target_pid()
second_proc = subprocess.Popen([TARGET], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL, text=True, start_new_session=True)
second = int(second_proc.stdout.readline())
alice = Member("alice")
bob = Member("bob")
say("alice", alice("collab", lab=lab_id)["status"])
say("bob", bob("collab", lab=lab_id)["status"])
sid = alice("attach", pid=first)["session"]
def srv_pid():
    row = db().execute("select process_json from session where lab_id=? and upper(id)=?", (lab_id, sid.upper())).fetchone()
    return json.loads(row[0])["pid"] if row else None
def bob_pid():
    return next((x["pid"] for x in bob("sessions")["sessions"] if x["id"] == sid), None)
bob.until("bob to see the first pid", lambda: bob_pid() == first, 30)
alice("detach", session=sid)
alice("attach", pid=second, session=sid)
got = alice.until("the server to hold the new pid", lambda: srv_pid() == second, 30)
check("the server's session holds the new process's pid after the host re-attaches", srv_pid() == second, (first, second, srv_pid()))
bob.until("bob to see the new pid", lambda: bob_pid() == second, 30)
check("a member's Luma shows the new pid", bob_pid() == second, (first, second, bob_pid()))
alice.quit(); bob.quit()
os.killpg(second_proc.pid, 15)
summary()
