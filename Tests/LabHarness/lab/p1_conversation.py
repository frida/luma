import sys
import time
import uuid

from lab import *

SOLO = "72A469B9-E1D4-5D9C-9639-49D33F0F27D5"

alice = Member("alice")
say("alice ready")
conv = alice("conv")
check("solo conversation id is the v5 of luma:project:conversation", conv["id"] == SOLO and conv["id"] == str(uuid.uuid5(uuid.NAMESPACE_URL, "luma:project:conversation")).upper(), conv)
alice("post", chat=SOLO, text="Solo note one.")
alice("post", chat=SOLO, text="Solo note two.")
alice("steps", channel="chat", steps=[{"text": "Listing. ", "tools": [{"name": "list_sessions", "args": {}}]}, {"text": "None yet."}])
alice("set", runs_without_asking=True)
r = alice("ask", chat=SOLO, text="Any sessions?", wait=True)
solo = alice.thread(SOLO)
check("solo conversation holds posts, a question and its answer", [m["role"] for m in solo["messages"]] == ["user", "user", "user", "assistant"], [(m["index"], m["role"], m["body"][:30]) for m in solo["messages"]])
check("outbox stays empty before a lab", alice("outbox")["total"] == 0, alice("outbox"))

st = alice("collab", timeout=60)
say("alice collab:", st)
lab_id = st["lab"]
check("1. handshake: protocol 4 accepted, lab created", st["status"].startswith("joined:") and lab_id, st)
check("1. identity from the welcome, not from GitHub: localUser alice", st["user"] == "alice", st)
save_state(lab=lab_id)
conv_id = str(uuid.uuid5(uuid.NAMESPACE_URL, f"luma:lab:{lab_id}:conversation")).upper()
save_state(conversation=conv_id)
time.sleep(2)
c = alice("chats")
check("2. on starting a lab the solo conversation is re-keyed to the lab's", c["conversation_id"] == conv_id and any(x["id"] == conv_id for x in c["chats"]) and not any(x["id"] == SOLO for x in c["chats"]), c)
th = alice.thread(conv_id)
check("2. her messages come with it", len(th["messages"]) == 4, [(m["index"], m["body"][:20]) for m in th["messages"]])
alice.until("outbox to drain", lambda: alice("outbox")["total"] == 0, 20)
ob = alice("outbox")
check("2. her rows are uploaded and settled (outbox empty)", ob["total"] == 0, ob)
with db() as conn:
    rows = conn.execute("select idx, obj_json from object_chat_message where lab_id=? and chat_id=? order by idx", (lab_id, conv_id)).fetchall()
    chatrow = conn.execute("select obj_json from object_chat where lab_id=? and chat_id=?", (lab_id, conv_id)).fetchone()
check("2. the server holds the conversation and its four messages", chatrow is not None and len(rows) == 4, [(r["idx"], json.loads(r["obj_json"])["body_markdown"][:20]) for r in rows])
calls = db().execute("select count(*) from object_chat_tool_call where lab_id=? and chat_id=?", (lab_id, conv_id)).fetchone()[0]
check("2c. the solo answer's tool call reached the lab on creating it", calls == len(th["calls"]) == 1, (calls, th["calls"]))
srv_objs = [json.loads(r["obj_json"])["object_id"] for r in db().execute("select obj_json from object_chat_object where lab_id=? and chat_id=?", (lab_id, conv_id))]
check("2c. ... and its objects, except the project's o1, which is never uploaded", sorted(srv_objs) == sorted(o["object_id"] for o in th["objects"] if o["object_id"] != "o1"), (srv_objs, [o["object_id"] for o in th["objects"]]))
check("2c. rows made with no identity are stamped as alice's locally", all(m["author"] == "alice" for m in th["messages"]) and all(c["executor"] == "alice" and c["asked_by"] == "alice" for c in th["calls"]), ([m["author"] for m in th["messages"]], [(c["asked_by"], c["executor"]) for c in th["calls"]]))
check("2. no refusal while creating the lab", not alice("warnings")["warnings"], alice("warnings")["warnings"])

bob = Member("bob")
st = bob("collab", lab=lab_id, timeout=60)
check("2. bob joins", st["status"] == f"joined:{lab_id}", st)
bt = bob.thread(conv_id)
check("2. bob receives the conversation with its messages", len(bt["messages"]) == 4 and bt["exists"], [(m["index"], m["author"], m["body"][:20]) for m in bt["messages"]])
check("2. bob has them unread (4) and alice none", bt["unread"] == 4 and alice.thread(conv_id)["unread"] == 0, (bt["unread"], alice.thread(conv_id)["unread"]))
check("2. bob receives the tool calls of alice's answer", len(bt["calls"]) == len(th["calls"]), (len(bt["calls"]), len(th["calls"])))

import threading
barrier = threading.Barrier(2)
def post(m, text):
    barrier.wait()
    m("post", chat=conv_id, text=text)
ta = threading.Thread(target=post, args=(alice, "alice at the same moment"))
tb = threading.Thread(target=post, args=(bob, "bob at the same moment"))
ta.start(); tb.start(); ta.join(); tb.join()
time.sleep(3)
def order(m):
    return [(x["index"], x["body"]) for x in m.thread(conv_id)["messages"]]
with db() as conn:
    srv = [(r["idx"], json.loads(r["obj_json"])["body_markdown"]) for r in conn.execute("select idx, obj_json from object_chat_message where lab_id=? and chat_id=? order by idx", (lab_id, conv_id))]
say("   server :", srv[-2:])
say("   alice  :", order(alice)[-2:])
say("   bob    :", order(bob)[-2:])
check("2. simultaneous posts: both members end with the server's order and indices", order(alice) == srv and order(bob) == srv, {"server": srv[-2:], "alice": order(alice)[-2:], "bob": order(bob)[-2:]})
check("2. same order (bodies) on both", [b for _, b in order(alice)] == [b for _, b in order(bob)], "")

a_unread = alice("unread", chat=conv_id)
b_unread = bob("unread", chat=conv_id)
say("   unread alice", a_unread, "bob", b_unread)
check("2. alice has bob's post unread", a_unread["unread"] == 1, a_unread)
check("2. onMessageArrived fired at alice for bob's post", any(x["body"] == "bob at the same moment" for x in alice("arrivals")["arrivals"]), alice("arrivals"))
check("2. onMessageArrived fired at bob for alice's posts", any(x["body"] == "alice at the same moment" for x in bob("arrivals")["arrivals"]), [x["body"] for x in bob("arrivals")["arrivals"]])
check("2. onMessageArrived did not fire for one's own", not any(x["author"] == "alice" for x in alice("arrivals")["arrivals"]), "")
alice("mark-read", chat=conv_id)
bob("mark-read", chat=conv_id)
check("2. markRead clears the counts", alice("unread", chat=conv_id)["unread"] == 0 and bob("unread", chat=conv_id)["unread"] == 0, "")

d1 = alice("delete", chat=conv_id)
d2 = bob("delete", chat=conv_id)
check("2. the conversation cannot be deleted by the owner or a member (client)", "error" in d1 and "error" in d2, (d1, d2))
check("2. nothing was sent for it", alice("outbox")["total"] == 0 and bob("outbox")["total"] == 0, "")
say("   proxy counts", proxy("counts"))

alice.quit(); bob.quit()
summary()
