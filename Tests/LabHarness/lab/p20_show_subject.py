import sys, time
from lab import *
s = state(); lab_id = s["lab"]
pid = target_pid()
alice, bob = Member("alice"), Member("bob")
for m in (alice, bob): say(m.login, m("collab", lab=lab_id)["status"])
sid = alice("attach", pid=pid)["session"]
bob.until("the session", lambda: any(x["id"] == sid and x["phase"] == "attached" for x in bob("sessions")["sessions"]), 30)
code = f"((LumaProject sessions items detect: [ :s | s id = '{sid}' ]) functionNamed: 'luma_target_score') pointer instruction next next"
chat = alice("start-chat", code=code)["id"]
alice("post", chat=chat, text="look here")
bob.until("bob has the chat", lambda: any(c["id"] == chat for c in bob("chats")["chats"]), 20)
b = bob("show-subject", chat=chat)
say("   bob first:", b)
time.sleep(5)
b2 = bob("show-subject", chat=chat)
say("   bob 5 s later:", b2)
bob("collab", lab=lab_id); time.sleep(3)
b3 = bob("show-subject", chat=chat)
say("   bob after a rejoin:", b3)
a = alice("show-subject", chat=chat)
say("   alice:", a)
say("   bob:", b)
say("   bob's column:", bob("column", chat=chat))
check("alice: insight in cache and store, lines and instruction", a.get("in_cache") and a.get("in_store") and a.get("lines") and "instruction" in a, a)
check("bob: either a plain reason, or an insight in cache and store with lines and the instruction",
      bool(b.get("reason")) or (b.get("in_cache") and b.get("in_store") and b.get("lines") and "instruction" in b), b)
alice.quit(); bob.quit(); summary()
