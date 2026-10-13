"""Self-test for the bug report server: python3 tools/bugs/test_isotope_bugs.py"""
import base64
import json
import os
import sys
import tempfile
import threading
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(__file__))
import isotope_bugs as bugs  # noqa: E402
from http.server import ThreadingHTTPServer  # noqa: E402

PNG = bugs.PNG_MAGIC + b"\x00" * 32


def post(port: int, doc) -> tuple[int, dict]:
    body = json.dumps(doc).encode() if not isinstance(doc, bytes) else doc
    req = urllib.request.Request("http://127.0.0.1:%d/report" % port, data=body,
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read())


def main() -> None:
    root = tempfile.mkdtemp()
    store = bugs.Store(root)
    srv = ThreadingHTTPServer(("127.0.0.1", 0), bugs.make_handler(store))
    port = srv.server_address[1]
    threading.Thread(target=srv.serve_forever, daemon=True).start()

    good = {"description": "Tank fell through the floor", "version": "0.12", "os": "Linux",
            "log": "line\n" * 10, "combat_log": "— Round 1 —", "contact": "tester",
            "screenshot": base64.b64encode(PNG).decode(), "replay": json.dumps({"steps": []})}
    code, body = post(port, good)
    assert code == 200 and body["ok"], (code, body)
    folders = [os.path.join(dp) for dp, dn, fn in os.walk(root) if "report.json" in fn]
    assert len(folders) == 1, folders
    files = sorted(os.listdir(folders[0]))
    assert files == ["combat_log.txt", "description.txt", "log.txt", "replay.json", "report.json",
                     "screenshot.png"], files
    meta = json.load(open(os.path.join(folders[0], "report.json")))
    assert meta["id"] == body["id"] and "127.0.0.1" not in json.dumps(meta), meta

    assert post(port, {"description": "  "})[0] == 400, "empty description refused"
    assert post(port, {"description": "x", "screenshot": base64.b64encode(b"GIF89a").decode()})[0] == 400, \
        "a non-PNG screenshot is refused"
    assert post(port, {"description": "x", "replay": "{not json"})[0] == 400, "broken replay refused"
    assert post(port, b"not json")[0] == 400, "garbage refused"
    assert post(port, {"description": "x" * (bugs.MAX_DESCRIPTION + 1)})[0] == 400, "long text refused"

    for _ in range(bugs.PER_ADDRESS - 1):
        assert post(port, {"description": "again"})[0] == 200
    code, body = post(port, {"description": "one too many"})
    assert code == 429 and "hour" in body["error"], (code, body)
    srv.shutdown()
    print("bug report server: all checks hold")


if __name__ == "__main__":
    main()
