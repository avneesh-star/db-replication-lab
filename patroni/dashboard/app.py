"""Failover dashboard: shows the Patroni cluster, runs write tests through HAProxy,
and stops/starts node containers through the Docker socket.

Local lab tool only: it has no authentication and controls Docker.
"""
import http.client
import json
import os
import socket
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import psycopg2

NODES = ["pg-node1", "pg-node2", "pg-node3"]
PROJECT = os.environ.get("COMPOSE_PROJECT", "patroni-lab")
DSN = "host=haproxy port={port} dbname=lab user=postgres password=postgres connect_timeout=2"


class DockerConn(http.client.HTTPConnection):
    def __init__(self):
        super().__init__("localhost")

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect("/var/run/docker.sock")


def docker(method, path):
    conn = DockerConn()
    conn.request(method, path)
    resp = conn.getresponse()
    body = resp.read()
    conn.close()
    return resp.status, (json.loads(body) if body and body[:1] in b"{[" else None)


def container(node):
    return f"{PROJECT}-{node}-1"


def node_state(node):
    info = {"name": node, "container": "unknown", "role": None, "state": None, "timeline": None}
    try:
        status, data = docker("GET", f"/containers/{container(node)}/json")
        if status == 200:
            info["container"] = data["State"]["Status"]
    except Exception:
        pass
    try:
        with urllib.request.urlopen(f"http://{node}:8008/patroni", timeout=1.5) as r:
            d = json.load(r)
        role = d.get("role")
        info["role"] = "leader" if role in ("master", "primary") else role
        info["state"] = d.get("replication_state") or d.get("state")
        info["timeline"] = d.get("timeline")
    except Exception:
        info["role"] = "down"
    return info


def run_write():
    t0 = time.time()
    try:
        conn = psycopg2.connect(DSN.format(port=5000))
        conn.autocommit = True
        with conn.cursor() as cur:
            cur.execute("INSERT INTO failover_test (note) VALUES ('dashboard write')")
            cur.execute("SELECT inet_server_addr()::text, pg_is_in_recovery()")
            addr, recovering = cur.fetchone()
        conn.close()
        return {"ok": True, "server": addr, "ms": round((time.time() - t0) * 1000)}
    except Exception as e:
        return {"ok": False, "error": str(e).strip().splitlines()[0][:160], "ms": round((time.time() - t0) * 1000)}


def run_read():
    try:
        conn = psycopg2.connect(DSN.format(port=5001))
        conn.autocommit = True
        with conn.cursor() as cur:
            cur.execute("SELECT count(*) FROM failover_test")
            n = cur.fetchone()[0]
        conn.close()
        return {"ok": True, "rows": n}
    except Exception as e:
        return {"ok": False, "error": str(e).strip().splitlines()[0][:160]}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send_json(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/api/state":
            self.send_json({"nodes": [node_state(n) for n in NODES], "read": run_read()})
        elif self.path in ("/", "/index.html"):
            with open(os.path.join(os.path.dirname(__file__), "index.html"), "rb") as f:
                body = f.read()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_json({"error": "not found"}, 404)

    def do_POST(self):
        if self.path == "/api/write":
            self.send_json(run_write())
        elif self.path.startswith("/api/stop/") or self.path.startswith("/api/start/"):
            action, node = self.path.split("/")[2:4]
            if node not in NODES:
                return self.send_json({"error": "unknown node"}, 400)
            status, _ = docker("POST", f"/containers/{container(node)}/{action}")
            self.send_json({"ok": status in (204, 304), "status": status})
        else:
            self.send_json({"error": "not found"}, 404)


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
