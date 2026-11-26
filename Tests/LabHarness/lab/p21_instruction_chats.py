import subprocess, sys, time
from lab import *
s = state(); lab_id = s["lab"]
pid = target_pid()
proxy("reset")
alice, bob = Member("alice"), Member("bob")
for m in (alice, bob): say(m.login, m("collab", lab=lab_id)["status"])
sid = alice("attach", pid=pid)["session"]
bob.until("the session", lambda: any(x["id"] == sid and x["phase"] == "attached" for x in bob("sessions")["sessions"]), 30)
def instr(n): return f"((LumaProject sessions items detect: [ :s | s id = '{sid}' ]) functionNamed: 'luma_target_score') pointer instruction" + " next" * n
def markers(m): return {x["address"]: x["chats"] for x in m("markers", session=sid)["markers"]}
def chat_ids(m): return [c["id"] for c in m("chats")["chats"]]

chat_a = alice("start-chat", code=instr(1))["id"]
check("live: a started chat is a draft, not listed or marked", chat_a not in chat_ids(alice) and not any(chat_a in v for v in markers(alice).values()), markers(alice))
alice("post", chat=chat_a, text="What is this?")
addr = alice("show-subject", chat=chat_a)["address"]
check("live: the first post saves and marks it at its address", markers(alice).get(addr) == [chat_a], markers(alice))

bob.until("bob has alice's chat", lambda: chat_a in chat_ids(bob), 20)
bob.until("bob's marker", lambda: markers(bob).get(addr) == [chat_a], 20)
check("two members: bob sees the chat marked at the same instruction", markers(bob).get(addr) == [chat_a], markers(bob))
sb = bob("show-subject", chat=chat_a)
check("two members: bob's Show Subject has an insight and the disassembly", sb.get("in_cache") and sb.get("lines") and sb.get("memory_reason") is None, sb)
next_addr = "0x%x" % (int(addr, 16) + 4)
started = bob("start-instruction-chat", session=sid, address=next_addr)
check("two members: bob, who does not host, starts a chat about an instruction from its address", "id" in started, started)
chat_b = started["id"]
bob("steps", channel="chat", steps=[{"text": "At the host. ", "tools": [{"name": "list_modules", "args": {"session_id": sid}}]}, {"text": "Done."}])
bob("ask", chat=chat_b, text="Modules?")
call = bob.until("bob's routed call", lambda: next((c for c in bob("calls", chat=chat_b)["calls"] if c["tool"] == "list_modules"), None), 30)
check("two members: bob's session tool is executed by the host and waits for her", call["executor"] == "alice" and call["status"] == "proposed" and call["hold"] is None, call)
alice.until("alice sees it waiting", lambda: any(c["id"] == call["id"] for c in alice("waiting")["calls"]), 20)
alice("detach", session=sid)
h = bob.until("the detached hold", lambda: (lambda c: c["hold"] if c["hold"] == "sessionDetached" else None)(next(c for c in bob("calls", chat=chat_b)["calls"] if c["id"] == call["id"])), 20)
check("two members: the call holds while the session is detached", h == "sessionDetached", h)
alice("attach", pid=pid, session=sid)
alice.until("re-attached", lambda: any(x["id"] == sid and x["phase"] == "attached" for x in alice("sessions")["sessions"]), 30)
bob.until("the hold clears", lambda: next(c for c in bob("calls", chat=chat_b)["calls"] if c["id"] == call["id"])["hold"] is None, 20)
alice("run", call=call["id"])
done = bob.until("the call succeeds at bob", lambda: (lambda c: c if c["status"] == "succeeded" else None)(next(c for c in bob("calls", chat=chat_b)["calls"] if c["id"] == call["id"])), 30)
check("two members: alice's approval runs it at her engine and bob gets the result", done["status"] == "succeeded", done)
time.sleep(3)

alice("post", chat=chat_b, text="Seen.")
time.sleep(2)
la, lb = alice("listed")["listed"], bob("listed")["listed"]
check("sidebar: both members list the chats in the same order, newest activity first", la == lb and la.index(chat_b) < la.index(chat_a), (la, lb))
alice.quit(); bob.quit()
alice, bob = Member("alice"), Member("bob")
for m in (alice, bob): m("collab", lab=lab_id)
time.sleep(4)
check("sidebar: the same order after both restart", alice("listed")["listed"] == la and bob("listed")["listed"] == la, (alice("listed"), bob("listed")))

alice.quit()
fresh = subprocess.Popen([TARGET], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL, text=True, start_new_session=True)
pid2 = int(fresh.stdout.readline()); save_state(target_pid=pid2)
alice = Member("alice"); alice("collab", lab=lab_id)
alice("attach", pid=pid2, session=sid)
alice.until("re-attached to the new process", lambda: any(x["id"] == sid and x["phase"] == "attached" and x["live_here"] for x in alice("sessions")["sessions"]), 30)
time.sleep(3)
addr2 = alice("show-subject", chat=chat_a)["address"]
check("re-attach: alice's marker follows the anchor to the new address", markers(alice).get(addr2) == [chat_a], (addr, addr2, markers(alice)))
bob.until("bob's marker follows", lambda: markers(bob).get(addr2) == [chat_a], 30)
check("re-attach: so does bob's", markers(bob).get(addr2) == [chat_a], (addr2, markers(bob)))

bob("delete", chat=chat_b)
alice.until("alice loses the deleted chat", lambda: chat_b not in chat_ids(alice), 20)
def on_server(chat): return db().execute("select count(*) from object_chat where lab_id=? and chat_id=?", (lab_id, chat)).fetchone()[0] > 0
check("delete: the chat and its marker are gone at both, and from the server", chat_b not in chat_ids(bob) and chat_b not in chat_ids(alice) and not on_server(chat_b)
      and not any(chat_b in v for v in markers(alice).values()) and not any(chat_b in v for v in markers(bob).values()), (chat_ids(alice), on_server(chat_b), markers(alice), markers(bob)))

alice("session-delete", session=sid); time.sleep(5)
check("session deleted at its host: its chats are gone there", chat_a not in chat_ids(alice), chat_ids(alice))
say("   (no client tells the lab a session was removed, so bob keeps it:", chat_a in chat_ids(bob), ")")

c = proxy("counts")
notes = {p: {k: v for k, v in d.items() if "address" in k} for p, d in c.items()}
check("wire: no address-note op was sent by anyone", not any(notes.values()), c)
import sqlite3
tables = {name: [r[0] for r in sqlite3.connect(f"file:{path}?mode=ro", uri=True).execute("select name from sqlite_master where type='table' and name like '%address_note%'")]
          for name, path in [("server", f"{L}/run/luma.db"), ("alice", f"{L}/run/alice.luma/db.sqlite"), ("bob", f"{L}/run/bob.luma/db.sqlite")]}
check("store: no address-note table on the server or in either project", not any(tables.values()), tables)
for m in (alice, bob):
    say(f"   {m.login} warnings:", m("warnings")["warnings"][-3:])
alice.quit(); bob.quit(); fresh.terminate(); summary()
