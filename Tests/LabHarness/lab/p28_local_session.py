import subprocess, sys, time
from lab import *
s = state(); lab_id = s["lab"]
alice, bob = Member("alice"), Member("bob")
for m in (alice, bob): say(m.login, m("collab", lab=lab_id)["status"])
target = subprocess.Popen([TARGET], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL, text=True, start_new_session=True)
pid = int(target.stdout.readline())
time.sleep(2); proxy("reset")
w0 = len(bob("warnings")["warnings"])
sid = bob("attach", pid=pid)["session"]
time.sleep(3)
bob("instance-add", session=sid, descriptor="tracer")
r = bob("repl-eval", session=sid, code="1 + 1")
chat = bob("start-chat", code=f"((LumaProject sessions items detect: [ :s | s id = '{sid}' ]) functionNamed: 'luma_target_score') pointer instruction")["id"]
bob("post", chat=chat, text="Only mine.")
time.sleep(4)
c = proxy("counts")["29202"]
say("   bob sent:", c)
check("a plain member's own session, its instrument, REPL and chat send nothing to the lab", not c.get("session_path") and not c.get("object_chat_op") and r.get("ok_result"), c)
check("and the lab does not hold its session", not bob("lab-holds", session=sid)["holds"], "")
check("no warning at the member", len(bob("warnings")["warnings"]) == w0, bob("warnings")["warnings"][w0:])
check("the owner sees nothing of it", sid not in {x["id"] for x in alice("sessions")["sessions"]} and chat not in {c["id"] for c in alice("chats")["chats"]}, "")
alice.quit(); bob.quit(); target.terminate(); summary()
