class_name LanDiscovery
extends Node

## Автопоиск серверов в локальной сети (item 38), по образцу LAN-списка Minecraft.
## Хост раз в секунду шлёт широковещательный «маячок» с описанием партии; клиент
## слушает их на фиксированном порту и отдаёт находки сигналом. Транспорт отдельный от
## самой игры (ENet живёт в NetworkSession) — это лишь витрина «кто где хостит».
##
## Работает поверх UDP-броадкаста: подписки на маршрутизатор не нужно, всё в пределах
## широковещательного домена (обычная домашняя/офисная сеть, а также VPN-мост, если он
## пропускает broadcast).

const DISCOVERY_PORT := 8643
const MAGIC := "MCF_TACTICS_LOBBY_V1"
## Как часто хост объявляет о себе и как быстро протухает найденный сервер.
const BEACON_INTERVAL := 1.0
const ENTRY_TTL := 3.5

signal servers_changed(servers: Array)  # клиенту: [{ip, name, players, port, ...}]

var _udp: PacketPeerUDP = null
var _mode := ""                       # "host" | "client" | ""
var _accum := 0.0
var _info: Dictionary = {}            # что рассылает хост
var _seen: Dictionary = {}            # ip -> {info, last_seen}

## Хост: начать рассылать маячок с описанием своей партии.
func start_advertising(info: Dictionary) -> void:
	stop()
	_mode = "host"
	_info = info.duplicate()
	_udp = PacketPeerUDP.new()
	_udp.set_broadcast_enabled(true)
	_udp.set_dest_address("255.255.255.255", DISCOVERY_PORT)
	_accum = BEACON_INTERVAL  # первый маячок — сразу
	set_process(true)

## Обновить объявляемые данные (сменили карту, подключился игрок и т. п.).
func update_info(info: Dictionary) -> void:
	_info = info.duplicate()

## Клиент: начать слушать маячки. Находки приходят сигналом servers_changed.
func start_listening() -> void:
	stop()
	_mode = "client"
	_udp = PacketPeerUDP.new()
	# Несколько клиентов на одной машине — редкость; для одного bind достаточно.
	var err := _udp.bind(DISCOVERY_PORT)
	if err != OK:
		push_warning("LanDiscovery: cannot bind %d (err %d)" % [DISCOVERY_PORT, err])
	set_process(true)

func stop() -> void:
	set_process(false)
	_mode = ""
	if _udp != null:
		_udp.close()
		_udp = null
	_seen.clear()

func _process(delta: float) -> void:
	if _mode == "host":
		_accum += delta
		if _accum >= BEACON_INTERVAL:
			_accum = 0.0
			var payload := _info.duplicate()
			payload["magic"] = MAGIC
			_udp.put_packet(JSON.stringify(payload).to_utf8_buffer())
	elif _mode == "client":
		var changed := false
		while _udp != null and _udp.get_available_packet_count() > 0:
			var raw := _udp.get_packet()
			var ip := _udp.get_packet_ip()
			var parsed: Variant = JSON.parse_string(raw.get_string_from_utf8())
			if not (parsed is Dictionary) or parsed.get("magic", "") != MAGIC:
				continue
			var info: Dictionary = parsed
			info["ip"] = ip
			_seen[ip] = {"info": info, "last_seen": Time.get_ticks_msec() / 1000.0}
			changed = true
		# Протухшие серверы вычищаем — хост мог погаснуть.
		var now := Time.get_ticks_msec() / 1000.0
		for ip in _seen.keys():
			if now - float(_seen[ip]["last_seen"]) > ENTRY_TTL:
				_seen.erase(ip)
				changed = true
		if changed:
			servers_changed.emit(current_servers())

func current_servers() -> Array:
	var out: Array = []
	for ip in _seen:
		out.append(_seen[ip]["info"])
	return out
