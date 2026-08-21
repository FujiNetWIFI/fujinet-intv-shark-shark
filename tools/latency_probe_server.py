#!/usr/bin/env python3
"""TCP echo server for the transport spike.  Echoes bytes back immediately
(TCP_NODELAY) and logs per-connection round counts and timing."""
import socket
import sys
import time

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 9105


def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", PORT))
    srv.listen(1)
    print(f"echo listening on 127.0.0.1:{PORT}", flush=True)
    while True:
        conn, peer = srv.accept()
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        print(f"connection from {peer}", flush=True)
        t0 = time.monotonic()
        rounds = 0
        gaps = []
        last = t0
        try:
            while True:
                data = conn.recv(4096)
                if not data:
                    break
                now = time.monotonic()
                gaps.append(now - last)
                last = now
                conn.sendall(data)
                rounds += 1
        except OSError:
            pass
        dt = time.monotonic() - t0
        if gaps:
            avg = sum(gaps[1:]) / max(len(gaps) - 1, 1)
            print(f"closed: {rounds} recvs in {dt:.3f}s, "
                  f"avg inter-arrival {avg*1000:.2f} ms", flush=True)
        conn.close()


if __name__ == "__main__":
    main()
