#!/usr/bin/env python3
"""MCF Isotope internet relay and lobby list.

The host player's game stays the authority, exactly as on a LAN: this server only forwards
the same messages between the members of a room, numbers them (host = 1, guests 2, 3, ...),
and lists the open rooms for the in-game Lobbies tab. Nobody needs port forwarding; every
player connects out to this server.

Wire format, both directions: [u32 big-endian length][u8 type][body]; length counts the
type byte and the body.

client -> server
  H  host   JSON {name, map, players, max_players, status, version, protocol, password}
  J  join   JSON {room, password, protocol}
  U  update JSON listing fields (host only)
  D  data   [u32 target id, 0 = everyone else in the room][payload]
  K  kick   [u32 id] (host only)
  L  list   (empty) -> R
  P  ping   (empty) -> O
server -> client
  W  welcome JSON {id, room}
  E  error   JSON {error}
  A  peer joined [u32 id]   (to the host)
  X  peer left   [u32 id]   (to the host)
  D  data   [u32 from id][payload]
  R  rooms  JSON [{room, name, map, players, max_players, status, version, protocol, locked}]
  O  pong
  C  closed JSON {reason}   (the host left or kicked you)

Only the standard library. Run: python3 isotope_relay.py [--port 8650] [--self-test]
"""
import argparse
import asyncio
import hashlib
import json
import logging
import secrets
import struct
import time

MAX_FRAME = 32 << 20          # a full Colossal state resync fits comfortably
MAX_CONN_PER_IP = 24
MAX_ROOMS_PER_IP = 4
MAX_MEMBERS = 40              # players + spectators
IDLE_TIMEOUT = 120.0          # clients ping every 20 s
CODE_CHARS = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
LISTING_FIELDS = {"name": 40, "map": 60, "status": 20, "version": 16}

log = logging.getLogger("isotope-relay")


def frame(kind: str, body: bytes = b"") -> bytes:
    return struct.pack(">IB", len(body) + 1, ord(kind)) + body


def jframe(kind: str, obj) -> bytes:
    return frame(kind, json.dumps(obj, separators=(",", ":")).encode())


def clean_listing(info: dict) -> dict:
    out = {}
    for key, limit in LISTING_FIELDS.items():
        if key in info:
            out[key] = str(info[key])[:limit]
    for key in ("players", "max_players", "protocol"):
        if key in info:
            try:
                out[key] = max(0, min(int(info[key]), 999))
            except (TypeError, ValueError):
                pass
    return out


class Member:
    def __init__(self, server, reader, writer):
        self.server = server
        self.reader = reader
        self.writer = writer
        self.ip = (writer.get_extra_info("peername") or ("?", 0))[0]
        self.room = None
        self.id = 0
        self.since = time.time()
        self.frames = 0
        self.bytes_in = 0
        self.last = ""

    def send(self, data: bytes) -> None:
        if not self.writer.is_closing():
            self.writer.write(data)

    def close(self) -> None:
        if not self.writer.is_closing():
            self.writer.close()


class Room:
    def __init__(self, code, host, info, password):
        self.code = code
        self.host = host
        self.info = info
        self.password = hashlib.sha256(password.encode()).hexdigest() if password else ""
        self.members = {1: host}
        self.next_id = 2
        self.created = time.time()

    def listing(self) -> dict:
        d = dict(self.info)
        d["room"] = self.code
        d["locked"] = bool(self.password)
        d.setdefault("players", len(self.members))
        return d


class Relay:
    def __init__(self):
        self.rooms: dict[str, Room] = {}
        self.conns_per_ip: dict[str, int] = {}

    async def handle(self, reader, writer):
        m = Member(self, reader, writer)
        self.conns_per_ip[m.ip] = self.conns_per_ip.get(m.ip, 0) + 1
        reason = "closed by the server"
        try:
            if self.conns_per_ip[m.ip] > MAX_CONN_PER_IP:
                m.send(jframe("E", {"error": "Too many connections from your address."}))
                return
            while True:
                head = await asyncio.wait_for(reader.readexactly(4), IDLE_TIMEOUT)
                (length,) = struct.unpack(">I", head)
                if length < 1 or length > MAX_FRAME:
                    reason = "bad frame length %d" % length
                    return
                data = await asyncio.wait_for(reader.readexactly(length), IDLE_TIMEOUT)
                m.frames += 1
                m.bytes_in += 4 + length
                m.last = chr(data[0])
                if not self.dispatch(m, m.last, data[1:]):
                    reason = "refused frame %r" % m.last
                    return
                await writer.drain()
        except asyncio.IncompleteReadError:
            reason = "the player closed the connection"
        except asyncio.TimeoutError:
            reason = "silent for %d s" % IDLE_TIMEOUT
        except (ConnectionError, OSError) as e:
            reason = "%s: %s" % (type(e).__name__, e)
        finally:
            if m.room is not None:
                log.info("room %s: player %d (%s) left after %d s, %d frames, %d bytes, last %r: %s",
                         m.room.code, m.id, m.ip, time.time() - m.since, m.frames, m.bytes_in, m.last, reason)
            self.leave(m)
            self.conns_per_ip[m.ip] -= 1
            if self.conns_per_ip[m.ip] <= 0:
                del self.conns_per_ip[m.ip]
            m.close()

    def dispatch(self, m: Member, kind: str, body: bytes) -> bool:
        if kind == "P":
            m.send(frame("O"))
        elif kind == "L":
            rooms = sorted(self.rooms.values(), key=lambda r: r.created)
            m.send(jframe("R", [r.listing() for r in rooms]))
        elif kind == "H":
            if m.room is not None:
                return False
            info = json.loads(body.decode() or "{}")
            if sum(1 for r in self.rooms.values() if r.host.ip == m.ip) >= MAX_ROOMS_PER_IP:
                m.send(jframe("E", {"error": "Too many games hosted from your address."}))
                return True
            code = "".join(secrets.choice(CODE_CHARS) for _ in range(6))
            while code in self.rooms:
                code = "".join(secrets.choice(CODE_CHARS) for _ in range(6))
            room = Room(code, m, clean_listing(info), str(info.get("password", ""))[:64])
            self.rooms[code] = room
            m.room, m.id = room, 1
            m.send(jframe("W", {"id": 1, "room": code}))
            log.info("room %s opened by %s (%s, %s)", code, m.ip, room.info.get("name", ""), room.info.get("version", "?"))
        elif kind == "J":
            if m.room is not None:
                return False
            req = json.loads(body.decode() or "{}")
            room = self.rooms.get(str(req.get("room", "")).upper())
            if room is None:
                m.send(jframe("E", {"error": "That game no longer exists."}))
            elif room.password and hashlib.sha256(str(req.get("password", "")).encode()).hexdigest() != room.password:
                m.send(jframe("E", {"error": "Wrong password."}))
            elif "protocol" in room.info and int(req.get("protocol", -1)) != room.info["protocol"]:
                m.send(jframe("E", {"error": "That game runs a different version of MCF Isotope (%s)." % room.info.get("version", "?")}))
            elif len(room.members) >= MAX_MEMBERS:
                m.send(jframe("E", {"error": "That game is full."}))
            else:
                m.room, m.id = room, room.next_id
                room.next_id += 1
                room.members[m.id] = m
                log.info("room %s: player %d joined from %s", room.code, m.id, m.ip)
                m.send(jframe("W", {"id": m.id, "room": room.code}))
                room.host.send(frame("A", struct.pack(">I", m.id)))
        elif kind == "U":
            if m.room is None or m.id != 1:
                return False
            m.room.info.update(clean_listing(json.loads(body.decode() or "{}")))
        elif kind == "D":
            if m.room is None or len(body) < 4:
                return False
            (target,) = struct.unpack(">I", body[:4])
            out = frame("D", struct.pack(">I", m.id) + body[4:])
            if target == 0:
                for mid, other in m.room.members.items():
                    if mid != m.id:
                        other.send(out)
            elif target in m.room.members and target != m.id:
                m.room.members[target].send(out)
        elif kind == "K":
            if m.room is None or m.id != 1 or len(body) != 4:
                return False
            (victim,) = struct.unpack(">I", body)
            other = m.room.members.get(victim)
            if other is not None and victim != 1:
                log.info("room %s: host kicked player %d", m.room.code, victim)
                other.send(jframe("C", {"reason": "The host removed you from the game."}))
                other.close()
        else:
            return False
        return True

    def leave(self, m: Member) -> None:
        room = m.room
        if room is None:
            return
        m.room = None
        room.members.pop(m.id, None)
        if m.id == 1:
            self.rooms.pop(room.code, None)
            for other in list(room.members.values()):
                other.send(jframe("C", {"reason": "The host left the game."}))
                other.room = None
                other.close()
            log.info("room %s closed", room.code)
        else:
            room.host.send(frame("X", struct.pack(">I", m.id)))


async def serve(port: int) -> None:
    relay = Relay()
    server = await asyncio.start_server(relay.handle, "0.0.0.0", port)
    log.info("listening on %s", ", ".join(str(s.getsockname()) for s in server.sockets))
    async with server:
        await server.serve_forever()


async def self_test() -> None:
    """Host, two guests, data both ways, listing, password, kick, host leaving."""
    relay = Relay()
    server = await asyncio.start_server(relay.handle, "127.0.0.1", 0)
    port = server.sockets[0].getsockname()[1]

    async def conn():
        return await asyncio.open_connection("127.0.0.1", port)

    async def read(r):
        (n,) = struct.unpack(">I", await r.readexactly(4))
        d = await r.readexactly(n)
        return chr(d[0]), d[1:]

    hr, hw = await conn()
    hw.write(jframe("H", {"name": "Test", "map": "Arena", "protocol": 7, "version": "0.11", "password": "pw"}))
    k, b = await read(hr)
    assert k == "W" and json.loads(b)["id"] == 1
    code = json.loads(b)["room"]
    lr, lw = await conn()
    lw.write(frame("L"))
    k, b = await read(lr)
    rooms = json.loads(b)
    assert k == "R" and rooms[0]["room"] == code and rooms[0]["locked"] and "password" not in rooms[0]
    br, bw = await conn()
    bw.write(jframe("J", {"room": code, "password": "nope", "protocol": 7}))
    assert (await read(br))[0] == "E"
    bw.write(jframe("J", {"room": code, "password": "pw", "protocol": 6}))
    k, b = await read(br)
    assert k == "E" and "version" in json.loads(b)["error"]
    gr, gw = await conn()
    gw.write(jframe("J", {"room": code, "password": "pw", "protocol": 7}))
    k, b = await read(gr)
    assert k == "W" and json.loads(b)["id"] == 2
    k, b = await read(hr)
    assert k == "A" and struct.unpack(">I", b)[0] == 2
    g3r, g3w = await conn()
    g3w.write(jframe("J", {"room": code.lower(), "password": "pw", "protocol": 7}))
    assert json.loads((await read(g3r))[1])["id"] == 3
    await read(hr)
    gw.write(frame("D", struct.pack(">I", 0) + b"hello"))
    for r in (hr, g3r):
        k, b = await read(r)
        assert k == "D" and struct.unpack(">I", b[:4])[0] == 2 and b[4:] == b"hello"
    hw.write(frame("D", struct.pack(">I", 3) + b"only3"))
    k, b = await read(g3r)
    assert b[4:] == b"only3"
    hw.write(frame("K", struct.pack(">I", 3)))
    k, b = await read(g3r)
    assert k == "C"
    k, b = await read(hr)
    assert k == "X" and struct.unpack(">I", b)[0] == 3
    hw.close()
    k, b = await read(gr)
    assert k == "C" and "host" in json.loads(b)["reason"]
    lw.write(frame("L"))
    assert json.loads((await read(lr))[1]) == []
    server.close()
    print("relay self-test: host, join, password, version check, routing, kick, close all hold")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", type=int, default=8650)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
    asyncio.run(self_test() if args.self_test else serve(args.port))


if __name__ == "__main__":
    main()
