import sys, threading, time
from lab import *
s = state(); lab_id, conv = s["lab"], s["conversation"]
rounds = int(sys.argv[1]) if len(sys.argv) > 1 else 20
fresh = sys.argv[2] == "fresh" if len(sys.argv) > 2 else False
refused = []
for r in range(rounds):
    alice, bob = Member("alice"), Member("bob")
    for m in (alice, bob):
        m("collab", lab=lab_id)
    for m in (alice, bob):
        m("set", runs_without_asking=True)
        m("steps", channel="chat", steps=[{"text": "Evaluating. ", "tools": [{"name": "chat_evaluate", "args": {"code": "3 + 4"}}]}, {"text": "Seven."}])
        m("column", chat=conv)
    barrier = threading.Barrier(2)
    def ask(m):
        barrier.wait()
        m("ask", chat=conv, text=f"{m.login} round {r}", wait=True)
    ts = [threading.Thread(target=ask, args=(m,)) for m in (alice, bob)]
    [t.start() for t in ts]; [t.join() for t in ts]
    time.sleep(3)
    ws = alice("warnings")["warnings"] + bob("warnings")["warnings"]
    turned = [w for w in ws if "turned" in w or "taken" in w]
    say(f"round {r}:", turned or "clean", time.time())
    if turned:
        refused.append((r, turned))
    alice.quit(); bob.quit()
check(f"{rounds} rounds of two simultaneous asks, each after a fresh join: nothing is refused", not refused, refused)
summary()
