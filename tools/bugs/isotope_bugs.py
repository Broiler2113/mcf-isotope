#!/usr/bin/env python3
"""MCF Isotope bug reports (release 0.12).

The game's "Report a Bug" window POSTs one JSON document to /report:

    {"description": str, "contact": str, "version": str, "os": str, "scene": str,
     "log": str, "combat_log": str, "screenshot": base64 PNG, "replay": str (JSON)}

Each accepted report becomes a folder under --dir:

    <dir>/<YYYY-MM-DD>/<HHMMSS>-<id>/report.json, description.txt, log.txt,
                                     combat_log.txt, screenshot.png, replay.json

Only the description is required. Limits keep a public endpoint cheap to run: body size,
field sizes, reports per address per hour, reports per day and total disk use. Addresses
are stored only as a salted hash (enough to spot one sender flooding, not to identify
anyone). Standard library only, like the relay next to it.

    python3 isotope_bugs.py --port 8651 --dir /var/lib/isotope-bugs
"""
from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import json
import logging
import os
import secrets
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MAX_BODY = 14 * 1024 * 1024
MAX_DESCRIPTION = 8000
MAX_CONTACT = 200
MAX_SHORT = 120
MAX_LOG = 600_000
MAX_SCREENSHOT = 5 * 1024 * 1024
MAX_REPLAY = 8 * 1024 * 1024
PER_ADDRESS = 6            # reports per address per hour
PER_DAY = 400              # reports per day from everyone
STORE_CAP = 4 * 1024 ** 3  # stop accepting above this much stored
PNG_MAGIC = b"\x89PNG\r\n\x1a\n"

log = logging.getLogger("isotope-bugs")


class Store:
    def __init__(self, root: str):
        self.root = root
        self.lock = threading.Lock()
        self.by_address: dict[str, list[float]] = {}
        self.day = ""
        self.day_count = 0
        self.salt = secrets.token_hex(16)
        self.used = self._measure()

    def _measure(self) -> int:
        total = 0
        for dp, _, files in os.walk(self.root):
            for f in files:
                try:
                    total += os.path.getsize(os.path.join(dp, f))
                except OSError:
                    pass
        return total

    def address_tag(self, address: str) -> str:
        return hashlib.sha256((self.salt + address).encode()).hexdigest()[:16]

    def admit(self, address: str) -> str:
        """'' when the report may be stored, otherwise the reason to refuse it."""
        now = time.time()
        with self.lock:
            today = time.strftime("%Y-%m-%d", time.gmtime(now))
            if today != self.day:
                self.day, self.day_count = today, 0
            recent = [t for t in self.by_address.get(address, []) if now - t < 3600]
            if len(recent) >= PER_ADDRESS:
                return "Too many reports from this address — please try again in an hour."
            if self.day_count >= PER_DAY:
                return "The report box is full for today — please try again tomorrow."
            if self.used >= STORE_CAP:
                return "The report box is full — please try again later."
            recent.append(now)
            self.by_address[address] = recent
            self.day_count += 1
            return ""

    def save(self, report: dict, address: str) -> str:
        now = time.time()
        rid = secrets.token_hex(4)
        folder = os.path.join(self.root, time.strftime("%Y-%m-%d", time.gmtime(now)),
                              time.strftime("%H%M%S", time.gmtime(now)) + "-" + rid)
        os.makedirs(folder, exist_ok=True)
        written = 0

        def put(name: str, data: bytes) -> None:
            nonlocal written
            with open(os.path.join(folder, name), "wb") as f:
                f.write(data)
            written += len(data)

        meta = {k: report[k] for k in ("version", "os", "scene", "contact") if report.get(k)}
        meta.update({"id": rid, "received": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)),
                     "sender": self.address_tag(address)})
        put("description.txt", report["description"].encode())
        for key, name in (("log", "log.txt"), ("combat_log", "combat_log.txt"), ("replay", "replay.json")):
            if report.get(key):
                put(name, report[key].encode())
        if report.get("screenshot_png"):
            put("screenshot.png", report["screenshot_png"])
        meta["files"] = sorted(os.listdir(folder))
        put("report.json", json.dumps(meta, indent=2).encode())
        with self.lock:
            self.used += written
        return rid


def validate(doc: object) -> tuple[dict, str]:
    """The report with its screenshot decoded, or an error message."""
    if not isinstance(doc, dict):
        return {}, "The report must be a JSON object."
    out: dict = {}
    desc = doc.get("description")
    if not isinstance(desc, str) or not desc.strip():
        return {}, "Please describe what happened."
    if len(desc) > MAX_DESCRIPTION:
        return {}, "The description is too long."
    out["description"] = desc.strip()
    for key, limit in (("contact", MAX_CONTACT), ("version", MAX_SHORT), ("os", MAX_SHORT),
                       ("scene", MAX_SHORT), ("log", MAX_LOG), ("combat_log", MAX_LOG),
                       ("replay", MAX_REPLAY)):
        value = doc.get(key, "")
        if value in (None, ""):
            continue
        if not isinstance(value, str):
            return {}, "Field %s must be text." % key
        if len(value) > limit:
            return {}, "Field %s is too large." % key
        out[key] = value
    shot = doc.get("screenshot")
    if shot:
        if not isinstance(shot, str):
            return {}, "The screenshot must be base64 text."
        try:
            png = base64.b64decode(shot, validate=True)
        except (binascii.Error, ValueError):
            return {}, "The screenshot is not valid base64."
        if len(png) > MAX_SCREENSHOT or not png.startswith(PNG_MAGIC):
            return {}, "The screenshot must be a PNG under 5 MB."
        out["screenshot_png"] = png
    if "replay" in out:
        try:
            json.loads(out["replay"])
        except ValueError:
            return {}, "The replay is not valid JSON."
    return out, ""


def make_handler(store: Store):
    class Handler(BaseHTTPRequestHandler):
        server_version = "IsotopeBugs/1.0"
        timeout = 30   # a slow or stalled sender does not hold a thread forever

        def _reply(self, code: int, body: dict) -> None:
            data = json.dumps(body).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, fmt: str, *args) -> None:   # one line per report instead
            pass

        def do_GET(self) -> None:
            if self.path == "/health":
                self._reply(200, {"ok": True})
            else:
                self._reply(404, {"ok": False, "error": "Not found."})

        def do_POST(self) -> None:
            if self.path != "/report":
                self._reply(404, {"ok": False, "error": "Not found."})
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                length = -1
            if length <= 0 or length > MAX_BODY:
                self._reply(413, {"ok": False, "error": "The report is too large or empty."})
                return
            raw = self.rfile.read(length)
            try:
                doc = json.loads(raw.decode("utf-8"))
            except (UnicodeDecodeError, ValueError):
                self._reply(400, {"ok": False, "error": "The report is not valid JSON."})
                return
            report, error = validate(doc)
            if error:
                self._reply(400, {"ok": False, "error": error})
                return
            address = self.client_address[0]
            refusal = store.admit(address)
            if refusal:
                self._reply(429, {"ok": False, "error": refusal})
                return
            try:
                rid = store.save(report, address)
            except OSError as exc:
                log.error("could not store a report: %s", exc)
                self._reply(503, {"ok": False, "error": "The server could not store the report."})
                return
            log.info("report %s (%s, %d bytes) from %s", rid, report.get("version", "?"), length,
                     store.address_tag(address))
            self._reply(200, {"ok": True, "id": rid})

    return Handler


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=8651)
    ap.add_argument("--dir", default=os.environ.get("STATE_DIRECTORY", "/var/lib/isotope-bugs"))
    args = ap.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
    os.makedirs(args.dir, exist_ok=True)
    store = Store(args.dir)
    server = ThreadingHTTPServer((args.host, args.port), make_handler(store))
    server.daemon_threads = True
    log.info("bug reports on %s:%d, stored in %s (%d MB used)", args.host, args.port, args.dir,
             store.used // (1024 * 1024))
    server.serve_forever()


if __name__ == "__main__":
    main()
