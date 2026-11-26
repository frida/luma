import sys, threading, time, uuid
from lab import *
gina, hank, ivy = Member("gina"), Member("hank"), Member("ivy")
lab = gina("collab")["lab"]
for m in (hank, ivy): say(m.login, m("collab", lab=lab)["status"])
conv = str(uuid.uuid5(uuid.NAMESPACE_URL, f"luma:lab:{lab}:conversation")).upper()
def clean(label):
    ps = {m.login: m("problems")["problems"] for m in (gina, hank, ivy)}
    ws = {m.login: m("warnings")["warnings"] for m in (gina, hank, ivy)}
    check(f"{label}: no problem recorded, nothing refused", not any(ps.values()) and not any(ws.values()), (ps, ws))
    check(f"{label}: no 'object id taken'", not any("taken" in w for v in ws.values() for w in v), ws)
def srv_objs(chat): return [json.loads(r["obj_json"])["object_id"] for r in db().execute("select obj_json from object_chat_object where lab_id=? and chat_id=?", (lab, chat))]
def ask_all(chat, members, label):
    for m in members:
        m("set", runs_without_asking=True)
        m("steps", channel="chat", steps=[{"text": "On self. ", "tools": [{"name": "chat_evaluate", "args": {"code": "self printString size"}}]}, {"text": "Done."}])
        m("ask", chat=chat, text=f"{m.login} asks", wait=True)
        call = [c for c in m.thread(chat)["calls"] if c["asked_by"] == m.login][-1]
        check(f"{label}: {m.login} asks the assistant and its expression on o1 runs", call["status"] == "succeeded", call)
for m in (gina, hank, ivy):
    m("conv"); time.sleep(2)
time.sleep(2)
for m in (gina, hank, ivy):
    o = [x for x in m.thread(conv)["objects"] if x["object_id"] == "o1"]
    check(f"in turn: {m.login} holds the conversation with one local o1", m.thread(conv)["exists"] and len(o) == 1, m.thread(conv)["objects"])
say("   server objects of the conversation:", srv_objs(conv))
check("in turn: the project's o1 is not uploaded", "o1" not in srv_objs(conv), srv_objs(conv))
clean("in turn")
ask_all(conv, (gina, hank, ivy), "in turn")
clean("in turn, after asking")
for m in (gina, hank, ivy): m("stop")
gina.quit(); hank.quit(); ivy.quit()
import shutil
for n in ("gina", "hank", "ivy"):
    shutil.rmtree(f"{L}/run/{n}.luma", ignore_errors=True)
gina, hank, ivy = Member("gina"), Member("hank"), Member("ivy")
lab2 = gina("collab")["lab"]
for m in (hank, ivy): m("collab", lab=lab2)
conv2 = str(uuid.uuid5(uuid.NAMESPACE_URL, f"luma:lab:{lab2}:conversation")).upper()
lab_save = lab; lab = lab2
barrier = threading.Barrier(3)
def open_(m):
    barrier.wait(); m("conv")
ts = [threading.Thread(target=open_, args=(m,)) for m in (gina, hank, ivy)]
[t.start() for t in ts]; [t.join() for t in ts]
time.sleep(4)
for m in (gina, hank, ivy):
    check(f"at once: {m.login} holds the conversation with one o1", m.thread(conv2)["exists"] and len([x for x in m.thread(conv2)["objects"] if x["object_id"] == "o1"]) == 1, m.thread(conv2)["objects"])
editors = json.loads(db().execute("select obj_json from object_chat where lab_id=? and chat_id=?", (lab2, conv2)).fetchone()["obj_json"])["editors"]
check("at once: one conversation on the server, edited by all three", sorted(e["id"] for e in editors) == ["gina", "hank", "ivy"], editors)
clean("at once")
ask_all(conv2, (gina, hank, ivy), "at once")
clean("at once, after asking")
pc = hank("start-chat", code="LumaProject", label="the project")["id"]
hank("post", chat=pc, text="hank opens it")
ivy.until("ivy to receive it", lambda: ivy.thread(pc)["exists"], 15)
check("project chat: ivy holds o1 locally although it is never uploaded", any(o["object_id"] == "o1" for o in ivy.thread(pc)["objects"]) and "o1" not in srv_objs(pc), (ivy.thread(pc)["objects"], srv_objs(pc)))
ask_all(pc, (ivy,), "project chat")
clean("project chat")
pid = target_pid()
sid = gina("attach", pid=pid)["session"]
hank.until("hank to see the session", lambda: any(x["id"] == sid for x in hank("sessions")["sessions"]), 20)
ic = gina("start-chat", code="(LumaProject sessions items first functionNamed: 'luma_target_score') pointer instruction next next", label="instr")
say("   instruction chat attempt:", ic)
ic = ic["id"]
gina("post", chat=ic, text="gina opens it")
time.sleep(2)
say("   gina's chats:", [(c["id"][:8], c["subject"][:30]) for c in gina("chats")["chats"]])
hank.until("hank to receive it", lambda: hank.thread(ic)["exists"], 15)
for m in (gina, hank):
    m("set", runs_without_asking=True)
    m("steps", channel="chat", steps=[{"text": "Its class. ", "tools": [{"name": "chat_evaluate", "args": {"code": "self class name"}}]}, {"text": "Done."}])
    m("ask", chat=ic, text=f"{m.login}: what is it?", wait=True)
    call = [c for c in m.thread(ic)["calls"] if c["asked_by"] == m.login][-1]
    say(f"   {m.login}'s call in the instruction chat:", call["status"], call["summary"] or call["error"])
check("instruction chat: gina's (the host's) expression on o1 runs", [c for c in gina.thread(ic)["calls"] if c["asked_by"] == "gina"][-1]["status"] == "succeeded", "")
clean("instruction chat")
oc = hank("start-chat", code="(OrderedCollection new) add: 1; add: 2; yourself", label="hank's collection")["id"]
hank("post", chat=oc, text="hank opens it")
ivy.until("ivy to receive it", lambda: ivy.thread(oc)["exists"], 15)
r = ivy("add-object", chat=oc, code="(OrderedCollection new) add: 7; yourself", name="mine", in_place_of="o1")
say("   ivy's stand-in:", r)
time.sleep(2)
ivy("set", runs_without_asking=True)
ivy("steps", channel="chat", steps=[{"text": "Size. ", "tools": [{"name": "chat_evaluate", "args": {"code": "self size"}}]}, {"text": "Done."}])
ivy("ask", chat=oc, text="ivy: how big?", wait=True)
call = [c for c in ivy.thread(oc)["calls"] if c["asked_by"] == "ivy"][-1]
check("in place of o1: ivy's stand-in is hers on the server and her expression on o1 runs against it", call["status"] == "succeeded" and (call["summary"] or "").endswith("1") and r["object_id"].endswith(".ivy") and r["object_id"] in srv_objs(oc), (call, r, srv_objs(oc)))
check("in place of o1: hank's o1 on the server is untouched (still hank's)", json.loads(db().execute("select obj_json from object_chat_object where lab_id=? and chat_id=? and json_extract(obj_json,'$.object_id')='o1'", (lab2, oc)).fetchone()["obj_json"])["added_by"]["id"] == "hank", "")
clean("in place of o1")
gina.quit(); hank.quit(); ivy.quit(); summary()
