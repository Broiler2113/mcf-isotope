class_name RelayLink
extends RefCounted

## Internet play through the Isotope relay (tools/relay/isotope_relay.py, 0.11). One TCP
## connection to the relay; the relay forwards messages between the members of a room and
## lists open rooms. Frames: [u32 big-endian length][u8 type][body] — see the server's
## docstring for the types. Polled by NetworkSession every frame; no thread.

## This VPS for now; players can point the game at another server in the Multiplayer page.
const DEFAULT_SERVER := "103.86.177.137:8650"
const PING_EVERY := 20.0
const CONNECT_TIMEOUT := 8.0

signal welcomed(id: int, room: String)
signal failed(reason: String)
signal peer_added(id: int)
signal peer_removed(id: int)
signal data(from: int, payload: PackedByteArray)
signal rooms(list: Array)
signal closed(reason: String)

var my_id := 0
var room := ""
var _tcp := StreamPeerTCP.new()
var _buffer := PackedByteArray()
var _outbox: Array[PackedByteArray] = []
var _since_ping := 0.0
var _waited := 0.0
var _open := false
var _done := false

static func split_address(address: String) -> Array:
	var a := address.strip_edges()
	if a == "": a = DEFAULT_SERVER
	var colon := a.rfind(":")
	if colon > 0 and a.substr(colon + 1).is_valid_int():
		return [a.substr(0, colon), int(a.substr(colon + 1))]
	return [a, int(DEFAULT_SERVER.get_slice(":", 1))]

func connect_to(address: String) -> int:
	var hp := split_address(address)
	return _tcp.connect_to_host(str(hp[0]), int(hp[1]))

func host(info: Dictionary) -> void:
	_send_json("H", info)

func join(code: String, password: String, protocol: int) -> void:
	_send_json("J", {"room": code, "password": password, "protocol": protocol})

func update(info: Dictionary) -> void:
	_send_json("U", info)

func list_rooms() -> void:
	_queue("L", PackedByteArray())

func send_to(target: int, payload: PackedByteArray) -> void:
	var body := PackedByteArray()
	body.resize(4)
	_be32(body, 0, target)
	body.append_array(payload)
	_queue("D", body)

func kick(id: int) -> void:
	var body := PackedByteArray()
	body.resize(4)
	_be32(body, 0, id)
	_queue("K", body)

func close() -> void:
	_done = true
	_tcp.disconnect_from_host()

func is_done() -> bool:
	return _done

func poll(delta: float) -> void:
	if _done: return
	_tcp.poll()
	var status := _tcp.get_status()
	if status == StreamPeerTCP.STATUS_CONNECTING:
		_waited += delta
		if _waited > CONNECT_TIMEOUT:
			_fail("Could not reach the lobby server.")
		return
	if status != StreamPeerTCP.STATUS_CONNECTED:
		_fail("Could not reach the lobby server." if not _open else "Connection to the lobby server was lost.")
		return
	_open = true
	for packet in _outbox:
		_tcp.put_data(packet)
	_outbox.clear()
	_since_ping += delta
	if _since_ping >= PING_EVERY:
		_since_ping = 0.0
		_tcp.put_data(_frame("P", PackedByteArray()))
	var available := _tcp.get_available_bytes()
	if available > 0:
		var got := _tcp.get_partial_data(available)
		if got[0] == OK: _buffer.append_array(got[1])
	while _buffer.size() >= 4:
		var length := _read_be32(_buffer, 0)
		if length < 1 or length > (32 << 20):
			_fail("The lobby server sent something unreadable.")
			return
		if _buffer.size() < 4 + length: break
		var kind := char(_buffer[4])
		var body := _buffer.slice(5, 4 + length)
		_buffer = _buffer.slice(4 + length)
		_handle(kind, body)
		if _done: return

func _handle(kind: String, body: PackedByteArray) -> void:
	match kind:
		"W":
			var w: Dictionary = _json(body)
			my_id = int(w.get("id", 0))
			room = str(w.get("room", ""))
			welcomed.emit(my_id, room)
		"E":
			_fail(str(_json(body).get("error", "The lobby server refused.")))
		"A": peer_added.emit(_read_be32(body, 0))
		"X": peer_removed.emit(_read_be32(body, 0))
		"D": data.emit(_read_be32(body, 0), body.slice(4))
		"R":
			var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
			rooms.emit(parsed if parsed is Array else [])
		"C":
			_done = true
			_tcp.disconnect_from_host()
			closed.emit(str(_json(body).get("reason", "The game was closed.")))
		"O": pass

func _fail(reason: String) -> void:
	if _done: return
	_done = true
	_tcp.disconnect_from_host()
	failed.emit(reason)

func _send_json(kind: String, obj: Dictionary) -> void:
	_queue(kind, JSON.stringify(obj).to_utf8_buffer())

func _queue(kind: String, body: PackedByteArray) -> void:
	var packet := _frame(kind, body)
	if _open and _tcp.get_status() == StreamPeerTCP.STATUS_CONNECTED: _tcp.put_data(packet)
	else: _outbox.append(packet)

static func _frame(kind: String, body: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(5)
	_be32(out, 0, body.size() + 1)
	out[4] = kind.unicode_at(0)
	out.append_array(body)
	return out

static func _be32(buf: PackedByteArray, at: int, v: int) -> void:
	buf[at] = (v >> 24) & 0xFF
	buf[at + 1] = (v >> 16) & 0xFF
	buf[at + 2] = (v >> 8) & 0xFF
	buf[at + 3] = v & 0xFF

static func _read_be32(buf: PackedByteArray, at: int) -> int:
	return (buf[at] << 24) | (buf[at + 1] << 16) | (buf[at + 2] << 8) | buf[at + 3]

static func _json(body: PackedByteArray) -> Dictionary:
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	return parsed if parsed is Dictionary else {}
