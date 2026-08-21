#!/usr/bin/env python3
"""Lobby publisher contract test against a mock Lobby.

Stands up a stdlib HTTP server standing in for the FujiNet Lobby, points a
publisher at it (keepalive shortened), and asserts the wire contract the real
Lobby and the INTV Lobby client depend on:

  1. registration POST on startup, platform "intv", nonzero appkey,
     game/serverurl as configured, maxplayers matching the seat count;
  2. an unprompted keepalive re-POST within the keepalive interval
     (the Lobby drops stale entries by lastping);
  3. a final status:"offline" POST on shutdown.

Both implementations are covered:

    SERVER=py tools/test_lobby_pub.py    # LobbyPublisher, in-process
    SERVER=c  tools/test_lobby_pub.py    # server/c/intv-relay, as a process

The C run additionally asserts the request body is BYTE-IDENTICAL to what
json.dumps() produces for the reference payload -- field-by-field equality
would not catch a separator or key-order change, and the Lobby is not the
only consumer of that JSON.

The C build POSTs plain HTTP: the Lobby's Go server binds :8080 and the relay
reaches it directly, so --lobby-url takes an http:// URL.  That is why this
test can point both implementations at the same mock.

Run from the repo root.
"""
import importlib.util
import json
import os
import signal
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

SERVER = os.environ.get("SERVER", "py")
SEATS = int(os.environ.get("SEATS", "2"))
REPO = Path(__file__).resolve().parent.parent
RELAY_C = REPO / "server" / "c" / "intv-relay"

APPKEY = 99
SERVERURL = "TCP://example:9999/"
CLIENT_URL = "TNFS://example/game.rom"
GAME = "NASL Soccer"
SERVER_NAME = "Soccer Netplay"

posts = []
bodies = []
posts_lock = threading.Lock()


class MockLobby(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        with posts_lock:
            bodies.append(body)
            posts.append(json.loads(body))
        self.send_response(201)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"success": true}')

    def log_message(self, *a):
        pass


def wait_for(cond, timeout, what):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        with posts_lock:
            if cond():
                return
        time.sleep(0.05)
    with posts_lock:
        snapshot = list(posts)
    sys.exit(f"FAIL: timed out waiting for {what}; posts so far: {snapshot}")


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def run_python(base):
    server_py = next(REPO.glob("server/*_server.py"))
    spec = importlib.util.spec_from_file_location("relay", server_py)
    relay = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(relay)
    relay.LobbyPublisher.KEEPALIVE_SECS = 1.0     # shrink for the test
    pub = relay.LobbyPublisher(base, SERVERURL, CLIENT_URL, appkey=APPKEY,
                               game_name=GAME, server_name=SERVER_NAME)
    pub.update(0)
    return pub.shutdown


def run_c(base):
    if not os.access(RELAY_C, os.X_OK):
        sys.exit(f"SERVER=c: {RELAY_C} is not built -- run: make -C server/c")
    proc = subprocess.Popen(
        [str(RELAY_C), "--port", str(free_port()),
         "--max-seats", str(SEATS), "--lobby-enabled",
         "--lobby-url", base, "--lobby-appkey", str(APPKEY),
         "--lobby-serverurl", SERVERURL, "--lobby-client-url", CLIENT_URL,
         "--lobby-keepalive", "1.0", "--game-name", GAME,
         "--server-name", SERVER_NAME],
        cwd=REPO, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def shutdown():
        proc.send_signal(signal.SIGINT)
        try:
            proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=5)
    return shutdown


def main():
    if SERVER not in ("py", "c"):
        sys.exit(f"SERVER must be 'py' or 'c' (got {SERVER!r})")
    if SERVER == "py" and SEATS != 2:
        sys.exit("this repo's Python server hardcodes maxplayers=2")

    httpd = HTTPServer(("127.0.0.1", 0), MockLobby)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{httpd.server_address[1]}"

    shutdown = run_python(base) if SERVER == "py" else run_c(base)

    wait_for(lambda: len(posts) >= 1, 10, "the registration POST")
    reg = posts[0]
    assert reg["status"] == "online", reg
    assert reg["appkey"] == APPKEY, reg
    assert reg["serverurl"] == SERVERURL, reg
    assert reg["maxplayers"] == SEATS, \
        f"maxplayers must track the seat count: {reg}"
    assert reg["clients"] == [{"platform": "intv", "url": CLIENT_URL}], \
        f"platform must be 'intv' (the INTV Lobby client's filter): {reg}"
    assert 2 <= len(reg["game"]) <= 16, reg
    print(f"ok: registration ({reg['game']!r}, appkey {reg['appkey']}, "
          f"maxplayers {reg['maxplayers']})")

    # The reference body, in the Python payload dict's insertion order.
    expect = json.dumps({
        "game": GAME, "appkey": APPKEY, "server": SERVER_NAME, "region": "us",
        "serverurl": SERVERURL, "status": "online", "maxplayers": SEATS,
        "curplayers": 0,
        "clients": [{"platform": "intv", "url": CLIENT_URL}]}).encode()
    assert bodies[0] == expect, (
        "registration body is not byte-identical to json.dumps:\n"
        f"  got : {bodies[0]!r}\n  want: {expect!r}")
    print("ok: body byte-identical to json.dumps")

    n = len(posts)
    wait_for(lambda: len(posts) > n, 10, "a keepalive re-POST")
    assert posts[-1]["status"] == "online"
    print("ok: keepalive re-POST within the interval")

    shutdown()
    wait_for(lambda: posts and posts[-1]["status"] == "offline", 15,
             "the offline POST on shutdown")
    print("ok: offline POST on shutdown")
    httpd.shutdown()
    print(f"LOBBY PUBLISHER PASS (SERVER={SERVER})")


if __name__ == "__main__":
    main()
