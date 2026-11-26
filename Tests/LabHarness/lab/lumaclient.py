import queue
import threading
import time
import uuid

import frida

PORT = 27142


class Member:
    def __init__(self, login, gid, host, protocol=4, app_version="4.0.0", port=PORT):
        self.login = login
        self.address = f"{host}:{port}"
        mgr = frida.get_device_manager()
        self.device = mgr.add_remote_device(self.address, token=f"user:{login}:{gid}")
        self.others = []
        self.welcome = None
        self.bus = self.device.bus
        self.inbox = queue.Queue()
        self.results = {}
        self.cond = threading.Condition()
        self.bus.on("message", self._on_message)
        self.bus.attach()
        self.lab_id = None
        self.hello = self.request(".hello", "/session", {"protocol": protocol, "client": {"platform": "macos", "app_version": app_version}})

    def close(self):
        try:
            frida.get_device_manager().remove_remote_device(self.address)
        except Exception:
            pass

    def _on_message(self, message, data):
        if message.get("type") == "+welcome":
            self.welcome = message.get("payload")
        if message.get("type") in ("+result", "+error"):
            with self.cond:
                self.results[message["id"]] = (message, data)
                self.cond.notify_all()
        else:
            self.inbox.put((message, data))

    def request(self, type_, path, payload=None, data=None, timeout=10):
        rid = str(uuid.uuid4())
        msg = {"to": path, "type": type_, "id": rid}
        if payload is not None:
            msg["payload"] = payload
        self.bus.post(msg, data)
        deadline = time.time() + timeout
        with self.cond:
            while rid not in self.results:
                left = deadline - time.time()
                if left <= 0:
                    raise TimeoutError(f"{self.login}: no reply to {type_} {path}")
                self.cond.wait(left)
            msg, data = self.results.pop(rid)
        if msg["type"] == "+error":
            raise RuntimeError(f"{self.login}: {type_} {path} -> {msg['error']}")
        return msg.get("payload", {}), data

    def create_lab(self, title):
        payload, _ = self.request(".create", "/labs", {"title": title, "picture": {"content_type": "image/png"}}, data=b"\x89PNG")
        self.lab_id = payload["lab"]["id"]
        return self.lab_id

    def join(self, lab_id):
        payload, _ = self.request(".join", f"/labs/{lab_id}")
        self.lab_id = lab_id
        return payload

    def snapshot(self):
        payload, _ = self.request(".snapshot", f"/labs/{self.lab_id}")
        return payload

    def drain(self):
        out = []
        while True:
            try:
                out.append(self.inbox.get_nowait())
            except queue.Empty:
                return out

    def op(self, path_suffix, kind, timeout=5, **fields):
        op_id = str(uuid.uuid4()).upper()
        payload = {"op_id": op_id, "kind": kind, **fields}
        self.bus.post({"to": f"/labs/{self.lab_id}/{path_suffix}", "type": "+op", "payload": payload})
        deadline = time.time() + timeout
        echo = None
        while time.time() < deadline:
            try:
                msg, _ = self.inbox.get(timeout=max(0.01, deadline - time.time()))
            except queue.Empty:
                break
            p = msg.get("payload", {})
            if p.get("op_id") != op_id:
                self.others.append(msg)
                continue
            if msg["type"] == "+op":
                echo = p
            elif msg["type"] == "+op-ack":
                return ("acked", echo)
            elif msg["type"] == "+op-rejected":
                return ("rejected", p["reason"])
        return ("timeout", echo)

    def wait_op(self, op_kind, timeout=3):
        for i, msg in enumerate(self.others):
            if msg["type"] == "+op" and msg.get("payload", {}).get("kind") == op_kind:
                del self.others[i]
                return msg["payload"]
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                msg, _ = self.inbox.get(timeout=max(0.01, deadline - time.time()))
            except queue.Empty:
                break
            if msg["type"] == "+op" and msg.get("payload", {}).get("kind") == op_kind:
                return msg["payload"]
        return None

    def post_op(self, path_suffix, kind, **fields):
        op_id = str(uuid.uuid4()).upper()
        self.bus.post({"to": f"/labs/{self.lab_id}/{path_suffix}", "type": "+op",
                       "payload": {"op_id": op_id, "kind": kind, **fields}})
        return op_id

    def settle(self, op_ids, timeout=60):
        pending = set(op_ids)
        outcome = {}
        echoes = {}
        deadline = time.time() + timeout
        while pending and time.time() < deadline:
            try:
                msg, _ = self.inbox.get(timeout=max(0.01, deadline - time.time()))
            except queue.Empty:
                break
            p = msg.get("payload", {})
            oid = p.get("op_id")
            if oid not in pending:
                self.others.append(msg)
                continue
            if msg["type"] == "+op":
                echoes[oid] = p
            elif msg["type"] == "+op-ack":
                outcome[oid] = ("acked", echoes.get(oid))
                pending.discard(oid)
            elif msg["type"] == "+op-rejected":
                outcome[oid] = ("rejected", p["reason"])
                pending.discard(oid)
        for oid in pending:
            outcome[oid] = ("timeout", None)
        return outcome
