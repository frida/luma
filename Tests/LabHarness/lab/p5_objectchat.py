import sys
import threading
import time

from lab import *

s = state()
lab_id = s["lab"]
alice, bob, carol = Member("alice"), Member("bob"), Member("carol")
for m in (alice, bob, carol):
    say(m.login, m("collab", lab=lab_id)["status"])

chat = bob("start-chat", code="(OrderedCollection new) add: 3; add: 4; add: 5; yourself", label="a playground snippet")["id"]
save_state(object_chat=chat)
bob("steps", channel="chat", steps=[{"text": "Its size. ", "tools": [{"name": "chat_evaluate", "args": {"code": "self size"}}]}, {"text": "It holds 3."}])
bob("set", runs_without_asking=True)
bob("ask", chat=chat, text="How big is it?", wait=True)
time.sleep(2)
bt, at, ct = bob.thread(chat), alice.thread(chat), carol.thread(chat)
check("5. alice sees bob's chat with its transcript", [m["id"] for m in at["messages"]] == [m["id"] for m in bt["messages"]] and len(bt["messages"]) == 2, [(m["role"], m["body"][:30]) for m in at["messages"]])
check("5. alice sees its objects as snapshots (o1, o2.bob: ids now carry the maker), none live", [o["object_id"] for o in at["objects"]] == ["o1", "o2.bob"] and all(o["has_snapshot"] and not o["live"] for o in at["objects"]), at["objects"])
check("5. bob's are live", all(o["live"] for o in bt["objects"]), bt["objects"])
check("5. alice sees the call and its result", at["calls"] and at["calls"][-1]["status"] == "succeeded", at["calls"][-1:] )
alice("post", chat=chat, text="Alice here, a note to Bob.")
alice("steps", channel="chat", steps=[{"text": "Trying. ", "tools": [{"name": "chat_evaluate", "args": {"code": "self first"}}]}, {"text": "Could not reach it here."}])
alice("set", runs_without_asking=True)
alice("ask", chat=chat, text="What is its first element?", wait=True)
time.sleep(2)
at = alice.thread(chat)
ac = at["calls"][-1]
say("   alice's call in bob's chat:", ac)
check("5. alice can post and ask in bob's chat; her answer is appended", at["messages"][-1]["role"] == "assistant" and at["messages"][-1]["author"] == "alice", at["messages"][-2:])
check("5. alice's expression on o1 fails back to her model (o1 is not live in her Luma)", ac["status"] == "failed" and "not live" in (ac["result"] or ac["error"] or ""), ac)
check("5. bob sees alice's post, question and answer", len(bob.thread(chat)["messages"]) == len(at["messages"]), len(bob.thread(chat)["messages"]))
bmsg = bt["messages"][0]["id"]
amsg = [m for m in at["messages"] if m["author"] == "alice"][0]["id"]
r1 = alice("edit", chat=chat, message=bmsg, text="alice edits bob")
r2 = bob("edit", chat=chat, message=bmsg, text="How big is it, exactly?")
r3 = bob("remove", chat=chat, message=amsg)
r4 = carol("delete", chat=chat)
check("5. alice cannot edit bob's message (client)", "error" in r1, r1)
check("5. bob edits his own", r2.get("edited"), r2)
check("5. bob cannot remove alice's message (client)", "error" in r3, r3)
check("5. carol cannot delete bob's chat (client)", "error" in r4, r4)
time.sleep(1)
check("5. bob's edit reaches alice and carol", all(m.thread(chat)["messages"][0]["body"] == "How big is it, exactly?" for m in (alice, carol)), "")
r5 = alice("remove", chat=chat, message=bmsg)
time.sleep(1)
check("5. alice, an owner, removes bob's message: accepted, gone everywhere", r5.get("removed") and all(not any(m["id"] == bmsg for m in x.thread(chat)["messages"]) for x in (alice, bob, carol)), r5)
alice("rename", chat=chat, title="Bob's collection")
time.sleep(1)
check("5. any member renames; it reaches the others", all(any(c["id"] == chat and c["title"] == "Bob's collection" for c in x("chats")["chats"]) for x in (bob, carol)), "")
ws = {m.login: m("warnings")["warnings"] for m in (alice, bob, carol)}
check("5. none of that was refused", not any(ws.values()), ws)

alice.quit(); bob.quit(); carol.quit()
summary()
