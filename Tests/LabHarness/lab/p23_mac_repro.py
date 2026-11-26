import sqlite3, sys, time
from lab import *
s = state(); lab_id = s["lab"]
pid = target_pid()
alice, bob = Member("alice"), Member("bob")
for m in (alice, bob): say(m.login, m("collab", lab=lab_id)["status"])
sid = alice("attach", pid=pid)["session"]
bob.until("the session", lambda: any(x["id"] == sid and x["phase"] == "attached" for x in bob("sessions")["sessions"]), 30)
start = alice("start-chat", code=f"((LumaProject sessions items detect: [ :s | s id = '{sid}' ]) functionNamed: 'main') pointer instruction")["id"]
alice("show-subject", chat=start)
probe = alice("start-chat", code=f"((LumaProject sessions items detect: [ :s | s id = '{sid}' ]) functionNamed: 'main') pointer instruction next next")["id"]
address = "0x%x" % (int(alice("show-subject", chat=start)["address"], 16) + 8)
say("   main + 8 at", address)
chat = alice("start-instruction-chat", session=sid, address=address)["id"]
alice("post", chat=chat, text="Here.")
bob.until("bob has the chat", lambda: any(c["id"] == chat for c in bob("chats")["chats"]), 20)
time.sleep(8)
db_path = f"{L}/run/bob.luma/db.sqlite"
rows = lambda: sqlite3.connect(f"file:{db_path}?mode=ro", uri=True).execute("select count(*) from address_insight").fetchone()[0]
before = rows()
b = bob("show-subject", chat=chat)
after = [rows() for _ in range(6) if time.sleep(0.5) is None]
say("   bob:", b, "rows before", before, "after", after)
time.sleep(3)
say("   bob's warnings:", bob("warnings")["warnings"][-3:], "rows now", rows())
check("bob's Show Subject stores an insight that stays", b.get("in_store") and b.get("in_cache") and after[-1] >= before + 1, (b, before, after))
alice.quit(); bob.quit(); summary()
