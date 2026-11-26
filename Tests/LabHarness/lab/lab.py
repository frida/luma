import json
import os
import queue
import signal
import socket
import sqlite3
import subprocess
import sys
import threading
import time

HARNESS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
L = HARNESS + "/lab"
BUILD = os.environ.get("LAB_HARNESS_BUILD", HARNESS + "/.build/debug")
BIN = BUILD + "/LabCheck"
TARGET = BUILD + "/LabTarget"
PORTS = {"alice": 29201, "bob": 29202, "carol": 29203, "dave": 29204, "erin": 29204, "frank": 29204, "gina": 29201, "hank": 29202, "ivy": 29203}
GIDS = {"alice": 1001, "bob": 1002, "carol": 1003, "dave": 1004, "erin": 1005, "frank": 1006, "gina": 1007, "hank": 1008, "ivy": 1009}
RESULTS = []


def say(*parts):
    print(*parts, flush=True)


def check(label, cond, evidence=""):
    RESULTS.append((label, bool(cond), evidence))
    say(("PASS" if cond else "FAIL"), label, "--", evidence)
    return cond


def state():
    try:
        return json.load(open(L + "/run/state.json"))
    except Exception:
        return {}


def save_state(**kv):
    s = state()
    s.update(kv)
    json.dump(s, open(L + "/run/state.json", "w"), indent=1)


class Member:
    def __init__(self, login, port=None, extra_env=None, project=None):
        self.login = login
        self.project = f"{L}/run/{project or login}.luma"
        home = f"{L}/run/home-{project or login}"
        os.makedirs(home, exist_ok=True)
        env = dict(os.environ)
        env.update({
            "LAB_LOGIN": login,
            "LAB_GID": str(GIDS[login]),
            "LAB_PROJECT": self.project,
            "CFFIXED_USER_HOME": home,
            "LUMA_PORTAL_ADDRESS": f"127.0.0.1:{port or PORTS[login]}",
            "LUMA_STORE_CATALOG_URL": "http://127.0.0.1:8990/store/",
        })
        env.update(extra_env or {})
        self.log = open(f"{L}/run/{project or login}.log", "a", buffering=1)
        self.log.write(f"\n===== start {time.ctime()}\n")
        self.proc = subprocess.Popen([BIN], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log, text=True, bufsize=1)
        self.replies = {}
        self.events = []
        self.cond = threading.Condition()
        self.next_id = 0
        threading.Thread(target=self._read, daemon=True).start()
        self.wait_event("ready", 120)

    def _read(self):
        for line in self.proc.stdout:
            if not line.startswith("@@"):
                self.log.write(line)
                continue
            msg = json.loads(line[2:])
            with self.cond:
                if "_id" in msg:
                    self.replies[msg["_id"]] = msg
                else:
                    self.events.append(msg)
                    self.log.write("EVENT " + json.dumps(msg) + "\n")
                self.cond.notify_all()

    def wait_event(self, name, timeout=30, since=0):
        deadline = time.time() + timeout
        with self.cond:
            while True:
                for e in self.events[since:]:
                    if e.get("event") == name:
                        return e
                left = deadline - time.time()
                if left <= 0:
                    raise TimeoutError(f"{self.login}: no event {name}")
                self.cond.wait(left)

    def __call__(self, cmd, timeout=60, **args):
        self.next_id += 1
        rid = self.next_id
        args["cmd"] = cmd
        args["_id"] = rid
        self.proc.stdin.write(json.dumps(args) + "\n")
        self.proc.stdin.flush()
        deadline = time.time() + timeout
        with self.cond:
            while rid not in self.replies:
                left = deadline - time.time()
                if left <= 0:
                    raise TimeoutError(f"{self.login}: no reply to {cmd}")
                self.cond.wait(left)
            reply = self.replies.pop(rid)
        self.log.write(f"CMD {cmd} {json.dumps(args)[:300]} -> {json.dumps(reply)[:600]}\n")
        if not reply.get("ok"):
            raise RuntimeError(f"{self.login}: {cmd} failed: {reply.get('error')}")
        return reply

    def until(self, what, cond, timeout=30, interval=0.2):
        deadline = time.time() + timeout
        last = None
        while time.time() < deadline:
            last = cond()
            if last:
                return last
            time.sleep(interval)
        check(f"{self.login} waited for {what} ({timeout} s)", False, f"timed out; last: {last!r}"[:300])
        return last

    def thread(self, chat):
        return self("thread", chat=chat)

    def quit(self):
        try:
            self("quit", timeout=15)
        except Exception:
            pass
        try:
            self.proc.wait(10)
        except Exception:
            self.proc.kill()


def proxy(command):
    with socket.create_connection(("127.0.0.1", 29200)) as s:
        s.sendall((command + "\n").encode())
        data = b""
        while not data.endswith(b"\n"):
            chunk = s.recv(65536)
            if not chunk:
                break
            data += chunk
    text = data.decode().strip()
    return json.loads(text) if text.startswith("{") else text


def server_pid():
    out = subprocess.run(["pgrep", "-f", "LumaServer --control-port 29442"], capture_output=True, text=True).stdout.split()
    return int(out[0]) if out else None


def stop_server():
    pid = server_pid()
    if pid:
        os.kill(pid, signal.SIGTERM)
        for _ in range(100):
            if server_pid() is None:
                return
            time.sleep(0.1)


def start_server():
    try:
        socket.create_connection(("127.0.0.1", 29442), timeout=0.2).close()
        raise RuntimeError("port 29442 is already taken: not starting against someone else's server")
    except OSError:
        pass
    subprocess.Popen([L + "/server.sh"], stdin=subprocess.DEVNULL, start_new_session=True)
    for _ in range(100):
        try:
            socket.create_connection(("127.0.0.1", 29442), timeout=0.2).close()
            return
        except OSError:
            time.sleep(0.1)
    raise RuntimeError("server did not come up")


def db():
    conn = sqlite3.connect(f"file:{L}/run/luma.db?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    return conn


def target_pid():
    s = state()
    pid = s.get("target_pid")
    if pid:
        try:
            os.kill(pid, 0)
            return pid
        except OSError:
            pass
    proc = subprocess.Popen([TARGET], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL, text=True, start_new_session=True)
    pid = int(proc.stdout.readline())
    save_state(target_pid=pid)
    return pid


def summary():
    passed = sum(1 for _, ok, _ in RESULTS if ok)
    say(f"== {passed}/{len(RESULTS)} passed")
    for label, ok, ev in RESULTS:
        if not ok:
            say("   FAILED:", label, "--", ev)
    sys.exit(0 if passed == len(RESULTS) else 1)

SERVER_PORT = 29442
