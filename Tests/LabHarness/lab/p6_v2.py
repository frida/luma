import sys, threading, time, uuid
from lab import *
from lumaclient import Member as Raw
s = state(); lab_id, conv, chat = s["lab"], s["conversation"], s["object_chat"]
alice, bob, carol = Member("alice"), Member("bob"), Member("carol")
for m in (alice, bob, carol): say(m.login, m("collab", lab=lab_id)["status"])
time.sleep(2)

r = bob("add-object", chat=chat, code="String new: 2000000 withAll: $x", name="big")
time.sleep(2)
row = db().execute("select obj_json from object_chat_object where lab_id=? and chat_id=? and object_id=?", (lab_id, chat, r["object_id"])).fetchone()
check("6a. a 2 MB snapshot: stored with snapshot null, nothing refused", r["snapshot_bytes"] > 512*1024 and row is not None and json.loads(row["obj_json"]).get("snapshot") is None and not bob("warnings")["warnings"], (r, bob("warnings")["warnings"]))

for m in (alice, bob):
    m("set", runs_without_asking=True)
    m("steps", channel="chat", steps=[{"text": "Evaluating. ", "tools": [{"name": "chat_evaluate", "args": {"code": "3 + 4"}}]}, {"text": "Seven."}])
    m("column", chat=conv)
barrier = threading.Barrier(2)
def ask(m):
    barrier.wait()
    m("ask", chat=conv, text=f"{m.login}: what is 3 + 4?", wait=True)
ts = [threading.Thread(target=ask, args=(m,)) for m in (alice, bob)]
[t.start() for t in ts]; [t.join() for t in ts]
time.sleep(3)
warnings = alice("warnings")["warnings"] + bob("warnings")["warnings"]
check("6b. two simultaneous asks: nothing is refused", not [w for w in warnings if "taken" in w or "turned" in w], warnings)
srv = {json.loads(r["obj_json"])["object_id"]: json.loads(r["obj_json"]) for r in db().execute("select obj_json from object_chat_object where lab_id=? and chat_id=?", (lab_id, conv))}
for m in (alice, bob):
    last = [x for x in m.thread(conv)["calls"] if x["tool"] == "chat_evaluate" and x["asked_by"] == m.login][-1]
    held = srv.get(last["object_id"] or "")
    check(f"6b. {m.login}'s call names its own object, which the lab holds as {m.login}'s", last["status"] == "succeeded" and last["object_id"].endswith("." + m.login) and held and held["produced_by"] == last["id"] and held["added_by"]["id"] == m.login, (last["object_id"], held and (held["produced_by"], held["added_by"])))
    mine = [o for o in m.thread(conv)["objects"] if o["object_id"] == last["object_id"]]
    check(f"6b. in {m.login}'s image that object is live and the row is {m.login}'s", mine and mine[0]["live"] and mine[0]["added_by"] == m.login, mine)

check("6b. negative of the old finding: no 'object id taken' anywhere", not [w for w in warnings if "object id taken" in w], warnings)
proxy("reset"); time.sleep(20); c = proxy("counts")
check("6b. nothing sent in the 20 s after", all(not v.get("op") and not v.get("snapshot") for v in c.values()), c)
raw = Raw("carol", 1003, "127.0.0.1", port=29442); raw.join(lab_id)
NOW = "2026-11-24T10:15:00Z"
res = raw.op("object-chats", "object_chat_object_upsert", object={"chat_id": conv, "object_id": "o77.bob", "class_name": "X", "print_string": "x", "created_at": NOW, "updated_at": NOW})
check("6b. the server refuses an object id carrying someone else's member id", res[0] == "rejected" and "not your object id" in res[1], res)
res2 = raw.op("object-chats", "object_chat_object_upsert", object={"chat_id": conv, "object_id": "o77.carol", "class_name": "X", "print_string": "x", "created_at": NOW, "updated_at": NOW})
check("6b. and accepts one carrying the sender's own", res2[0] == "acked", res2)
res3 = raw.op("object-chats", "object_chat_remove", chat_id=chat)
check("6c. a raw remove of bob's chat by carol is refused", res3[0] == "rejected" and "not creator or owner" in res3[1], res3)
raw.close()

chat2 = bob("start-chat", code="Object new", label="throwaway A")["id"]
bob("post", chat=chat2, text="bob opens it")
carol.until("carol to see it", lambda: carol.thread(chat2)["exists"], 15)
proxy("reset")
proxy("hold 29203")
try:
    carol("post", chat=chat2, text="carol, held at the proxy")
    bob("delete", chat=chat2)
    applied = carol.until("carol's client to apply the removal", lambda: (lambda t: t["removed_in_lab"] or not t["exists"])(carol.thread(chat2)), 15)
    say("   carol after the removal arrived, op still held:", {k: carol.thread(chat2)[k] for k in ("exists", "removed_in_lab")}, carol("unsent"))
    held = proxy("counts")["29203"].get("held_chunks", 0)
finally:
    proxy("release 29203")
time.sleep(3)
t = carol.thread(chat2)
mine = [x for x in t["messages"] if x["body"] == "carol, held at the proxy"]
ws = carol("warnings")["warnings"]
say("   case A:", {k: t[k] for k in ("exists", "removed_in_lab")}, mine, ws, "held chunks:", held)
check("6d.A the op really was held until the removal was applied", held >= 1 and applied, held)
check("6d.A carol's post is kept, unsent, in the chat kept locally as removed in the lab", t["exists"] and t["removed_in_lab"] and mine and mine[0]["unsent"], (t["exists"], t["removed_in_lab"], mine))
sent = proxy("counts")["29203"].get("op:object_chat_message_append", 0)
check("6d.A the post reached the server once and was refused", sent == 1 and db().execute("select count(*) from object_chat_message where lab_id=? and chat_id=? and json_extract(obj_json, '$.body') = 'carol, held at the proxy'", (lab_id, chat2)).fetchone()[0] == 0, sent)
check("6d.A the reason is surfaced at most once", len([w for w in ws if "unknown chat" in w]) <= 1, ws)
proxy("reset"); time.sleep(20); c = proxy("counts")
check("6d.A nothing loops afterwards", all(not v.get("op") and not v.get("snapshot") for v in c.values()), c)
proxy("reset")
carol("resend", chat=chat2, message=mine[0]["id"])
time.sleep(3)
rc = proxy("counts")["29203"]
t = carol.thread(chat2); mine2 = [x for x in t["messages"] if x["id"] == mine[0]["id"]]
say("   after resend:", rc, mine2, carol("warnings")["warnings"][-2:])
check("finding 3. a resend into the removed chat sends nothing (was: one op, refused, plus a resync) and leaves the post unsent, kept", not rc.get("op") and not rc.get("snapshot") and mine2 and mine2[0]["unsent"], (rc, mine2))
carol.quit(); carol = Member("carol"); say("carol back:", carol("collab", lab=lab_id)["status"]); time.sleep(3)
t = carol.thread(chat2); mine3 = [x for x in t["messages"] if x["id"] == mine[0]["id"]]
check("6d.A after carol's engine restarts and rejoins: still kept, unsent, once", t["exists"] and t["removed_in_lab"] and len(mine3) == 1 and mine3[0]["unsent"], (t["exists"], t["removed_in_lab"], mine3, carol("unsent")))
check("6d.A ... and the rejoin sent nothing for it", carol("outbox")["total"] == 0, carol("outbox"))
carol("delete", chat=chat2)
check("6d.A carol can let it go: gone, nothing sent", not carol.thread(chat2)["exists"] and carol("outbox")["total"] == 0, "")

chat3 = bob("start-chat", code="Object new", label="throwaway B")["id"]
bob("post", chat=chat3, text="bob opens it")
carol.until("carol to see it", lambda: carol.thread(chat3)["exists"], 15)
bob("delete", chat=chat3)
carol.until("removal applied", lambda: not carol.thread(chat3)["exists"] or carol.thread(chat3)["removed_in_lab"], 15)
proxy("reset")
try:
    carol("post", chat=chat3, text="carol, too late")
    outcome = "posted"
except RuntimeError as e:
    outcome = str(e)
say("   case B:", outcome, carol.thread(chat3)["exists"])
check("6d.B posting after the removal throws (draft stays with the frontend) and sends nothing", outcome != "posted" and not proxy("counts")["29203"].get("op"), (outcome, proxy("counts")["29203"]))

alice.quit(); bob.quit(); carol.quit(); summary()
