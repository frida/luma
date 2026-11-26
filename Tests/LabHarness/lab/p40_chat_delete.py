import sys, threading, time
from lab import *
gina, hank = Member("gina"), Member("hank")
lab = gina("collab")["lab"]
say("hank", hank("collab", lab=lab)["status"])
def on_server(chat): return db().execute("select count(*) from object_chat where lab_id=? and chat_id=?", (lab, chat)).fetchone()[0] > 0
def chat_ids(m): return [c["id"] for c in m("chats")["chats"]]
def started(label, steps=None, wait=True):
    chat = gina("start-chat", code="OrderedCollection new", label=label)["id"]
    gina("post", chat=chat, text=f"{label}: a message")
    if steps:
        gina("steps", channel="chat", steps=steps)
        gina("ask", chat=chat, text=f"{label}: go", wait=wait)
    hank.until(f"hank to see {label}", lambda: chat in chat_ids(hank), 20)
    gina.until(f"{label} on the server", lambda: on_server(chat), 20)
    return chat
gina("set", runs_without_asking=True)
plain = started("no call")
finished = started("finished calls", [{"text": "Two. ", "tools": [{"name": "chat_evaluate", "args": {"code": "1"}}, {"name": "chat_evaluate", "args": {"code": "2"}}]}, {"text": "Done."}])
running = started("running call", [{"text": "Forever. ", "tools": [{"name": "chat_evaluate", "args": {"code": "[ true ] whileTrue"}}]}], wait=False)
gina.until("the endless call to run", lambda: any(c["status"] == "running" for c in gina.thread(running)["calls"]), 20)
for chat, label in ((plain, "no call"), (finished, "finished calls")):
    gina("delete", chat=chat)
    gone = hank.until(f"hank to lose {label}", lambda: chat not in chat_ids(hank), 20)
    check(f"a chat with {label} deleted by its author leaves the server and the other member", gone and not on_server(chat), (chat in chat_ids(hank), on_server(chat)))
started_at = time.time()
deleting = threading.Thread(target=lambda: gina("delete", chat=running, timeout=60))
deleting.start()
gone = hank.until("hank to lose the running chat", lambda: running not in chat_ids(hank), 20)
took = time.time() - started_at
deleting.join()
check("a chat with a running call deleted by its author leaves the server and the other member before the expression's deadline",
      gone and not on_server(running) and took < 9, (round(took, 1), running in chat_ids(hank), on_server(running)))
gina.quit(); hank.quit(); summary()
