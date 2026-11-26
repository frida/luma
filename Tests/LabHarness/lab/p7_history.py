import sys, time
from lab import *
from lumaclient import Member as Raw
s = state(); lab_id, chat = s["lab"], s["object_chat"]
alice, bob = Member("alice"), Member("bob")
for m in (alice, bob): say(m.login, m("collab", lab=lab_id)["status"])
before = len(bob.thread(chat)["messages"])
say("   messages before:", before)
t = time.time()
bob("post-many", chat=chat, count=2050, prefix="flood", timeout=600)
say("   posted 2050 in", round(time.time() - t, 1), "s")
bob.until("bob's outbox to drain", lambda: bob("outbox", timeout=60)["total"] == 0, 300, 2)
alice.until("alice to have them", lambda: len(alice.thread(chat)["messages"]) >= before + 2050, 120, 2)
with db() as conn:
    n, lo, hi = conn.execute("select count(*), min(idx), max(idx) from object_chat_message where lab_id=? and chat_id=?", (lab_id, chat)).fetchone()
say("   server holds", n, "messages, idx", lo, "..", hi)
check("7. the server keeps a window of 2000", n == 2000, (n, lo, hi))
raw = Raw("dave", 1004, "127.0.0.1", port=29442)
j = raw.join(lab_id)
th = [x for x in j["object_chats"] if x["id"] == chat][0]
raw.close()
check("7. the join reply's history_from moved to the lowest index held", th["history_from"] == lo and lo > 0, (th["history_from"], lo))
check("7. the join reply carries the window", len(th["messages"]) == 2000, len(th["messages"]))
for m in (alice, bob):
    n_local = len(m.thread(chat)["messages"])
    check(f"7. {m.login} keeps everything it saw ({before + 2050})", n_local == before + 2050, n_local)
proxy("reset")
for m in (alice, bob):
    m("stop"); m("collab", lab=lab_id)
time.sleep(5)
c = proxy("counts")
for m in (alice, bob):
    n_local = len(m.thread(chat)["messages"])
    st = m.thread(chat)["stored_messages"]
    check(f"7. after rejoining, {m.login} still holds the rolled-off messages (memory and store)", n_local == before + 2050 and st == n_local, (n_local, st))
check("7. rejoining re-uploads nothing", all(not v.get("op") for v in c.values()), c)
bob_objs_before = [o["object_id"] for o in bob.thread(chat)["objects"]]
bob.quit(); bob = Member("bob"); bob("collab", lab=lab_id); time.sleep(2)
added = bob("add-object", chat=chat, code="3 @ 4", name="after restart")
nums = [int(o.split(".")[0][1:]) for o in bob_objs_before if o.endswith(".bob")]
say("   bob's objects before:", bob_objs_before, "added:", added)
check("7. after the roll-off and a restart of bob's engine, his next object id is new and his own", added["object_id"].endswith(".bob") and int(added["object_id"].split(".")[0][1:]) > max(nums + [0]) and added["object_id"] not in bob_objs_before, added)
time.sleep(2)
check("7. the server accepts it", db().execute("select count(*) from object_chat_object where lab_id=? and chat_id=? and json_extract(obj_json,'$.object_id')=?", (lab_id, chat, added["object_id"])).fetchone()[0] == 1 and not bob("warnings")["warnings"], bob("warnings")["warnings"])
frank = Member("frank")
say("frank", frank("collab", lab=lab_id, timeout=90)["status"])
ft = frank.thread(chat)
check("7. a member who joins afterwards gets the window of 2000", len(ft["messages"]) == 2000 and ft["messages"][0]["index"] == lo, (len(ft["messages"]), ft["messages"][0]["index"] if ft["messages"] else None))
with db() as conn:
    so = [json.loads(r["obj_json"])["object_id"] for r in conn.execute("select obj_json from object_chat_object where lab_id=? and chat_id=?", (lab_id, chat))]
say("   frank objects:", [o["object_id"] for o in ft["objects"]], "server:", so)
check("7. o1 survives the roll-off on the server and frank holds the server's objects", "o1" in so and sorted(o["object_id"] for o in ft["objects"]) == sorted(so), so)
fa = frank("add-object", chat=chat, code="5 @ 6", name="frank's")
check("7. frank's first object id is his own", fa["object_id"].endswith(".frank"), fa)
frank.quit(); alice.quit(); bob.quit(); summary()
