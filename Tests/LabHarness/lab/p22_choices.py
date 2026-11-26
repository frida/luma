import json, sys, time
from lab import *
s = state(); lab_id = s["lab"]
alice, bob = Member("alice"), Member("bob")
for m in (alice, bob): say(m.login, m("collab", lab=lab_id)["status"])
chat = alice("start-chat", code="Object new", label="choices")["id"]
alice("post", chat=chat, text="Let us both ask.")
bob.until("bob has the chat", lambda: any(c["id"] == chat for c in bob("chats")["chats"]), 20)
alice("set-choice", chat=chat, provider="scripted", model="model-alice")
bob("set-choice", chat=chat, provider="scripted", model="model-bob")
for m in (alice, bob):
    m("steps", channel="chat", steps=[{"text": f"Answered for {m.login}."}])
alice("ask", chat=chat, text="alice asks"); alice("await-ask", chat=chat)
bob("ask", chat=chat, text="bob asks"); bob("await-ask", chat=chat)
time.sleep(3)
def answers(m): return {x["body"]: x["model"] for x in m("thread", chat=chat)["messages"] if x["role"] == "assistant"}
aa, ab = answers(alice), answers(bob)
check("each reply records its own asker's model, on both members", aa.get("Answered for alice.") == "model-alice" and aa.get("Answered for bob.") == "model-bob" and aa == ab, (aa, ab))
bob("set-choice", chat=chat, provider="nowhere", model="m")
r = bob("can-answer", chat=chat)
check("a member whose choice is not set up here is told before asking", r["reason"] == "There is no provider nowhere in this Luma.", r)
bob("set-choice", chat=chat, provider="scripted", model="model-bob")
alice.quit(); bob.quit()
alice, bob = Member("alice"), Member("bob")
check("a restart keeps each member's choice for the chat", alice("choice", chat=chat)["model"] == "model-alice" and bob("choice", chat=chat)["model"] == "model-bob", (alice("choice", chat=chat), bob("choice", chat=chat)))
row = db().execute("select obj_json from object_chat where lab_id=? and chat_id=?", (lab_id, chat)).fetchone()
stored = json.loads(row["obj_json"])
check("nothing about the choice reaches the server: its chat row has no provider or model", "provider_id" not in stored and "model_id" not in stored, sorted(stored))
alice.quit(); bob.quit(); summary()
