class_name NetworkSession
extends Node

## P2P-транспорт по ENet (M7, §11): хост/клиент по IP:порту. Чистый ретранслятор
## словарей-сообщений между двумя пирами — вся игровая логика в NetGame/резолвере.
## Хост слушает порт; клиент подключается. При установлении связи — peer_ready.
##
## Играют по локальной сети или через VPN вроде Radmin (#92): для ENet это обычный
## IP, поэтому отдельной поддержки не нужно — клиент вводит адрес хоста в лобби.

signal peer_ready(is_host: bool)  # связь установлена, можно начинать партию
signal message(msg: Dictionary)    # пришло сообщение от второй стороны
signal disconnected()

const DEFAULT_PORT := 8642
## Постоянное имя узла в дереве. RPC доставляется по ПУТИ узла, поэтому сессия
## живёт прямо под /root с одинаковым именем у обеих сторон (#54): так путь
## совпадает и не зависит от того, какая сцена сейчас загружена.
const NODE_NAME := "NetSession"

var _peer: ENetMultiplayerPeer = null
var _is_host: bool = false
## Сообщения, пришедшие до того, как бой подписался (#54). Между нажатием Host/Join
## в меню и готовностью сцены боя проходит кадр-другой, и без буфера первый пакет
## хоста (порядок инициативы) просто терялся бы.
var _inbox: Array[Dictionary] = []
var _listening: bool = false
## Подключённые гости в порядке подключения (только у хоста). По этому порядку
## лобби раздаёт слоты, поэтому список именно упорядоченный, а не множество.
var peers: Array[int] = []

func start_host(port: int = DEFAULT_PORT) -> int:
	if not is_inside_tree():
		# Вне дерева `multiplayer` == null, и пир молча повис бы «в никуда».
		push_error("NetworkSession: add the node to the tree before hosting")
		return ERR_UNCONFIGURED
	_peer = ENetMultiplayerPeer.new()
	# Партия рассчитана на 26 игроков (§7 «Лобби»), значит хост принимает 25 гостей.
	# Раньше здесь стояла жёсткая единица — «ровно один клиент», — и третий игрок
	# упирался не в правила, а в транспорт.
	var err := _peer.create_server(port, MCF.MAX_PLAYERS - 1)
	if err != OK:
		return err
	_is_host = true
	multiplayer.multiplayer_peer = _peer
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	return OK

func start_client(ip: String, port: int = DEFAULT_PORT) -> int:
	if not is_inside_tree():
		push_error("NetworkSession: add the node to the tree before joining")
		return ERR_UNCONFIGURED
	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_client(ip, port)
	if err != OK:
		return err
	_is_host = false
	multiplayer.multiplayer_peer = _peer
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_peer_disconnected)
	return OK

func is_active() -> bool:
	return _peer != null

func is_host() -> bool:
	return _is_host

## Сцена боя подписалась на message: отдаём накопленное и дальше шлём напрямую (#54).
func attach() -> void:
	_listening = true
	var pending := _inbox.duplicate()
	_inbox.clear()
	for m in pending:
		message.emit(m)

## Сцена уходит — снова копим сообщения в буфер (#93). Без этого пакет, пришедший
## между экраном расстановки и боем, эмитился бы в пустоту и терялся.
func detach() -> void:
	_listening = false

func close() -> void:
	if _peer != null:
		_peer.close()
		_peer = null
	multiplayer.multiplayer_peer = null

# --- Транспорт сообщений ---
func send(msg: Dictionary) -> void:
	if _peer != null:
		_relay.rpc(msg)

@rpc("any_peer", "call_remote", "reliable")
func _relay(msg: Dictionary) -> void:
	if _listening:
		message.emit(msg)
	else:
		_inbox.append(msg)

# --- События соединения ---
func _on_peer_connected(id: int) -> void:
	if not peers.has(id):
		peers.append(id)
	peer_ready.emit(true)  # хост: клиент подключился

func _on_connected_to_server() -> void:
	peer_ready.emit(false)  # клиент: подключились к хосту

func _on_connection_failed() -> void:
	close()
	disconnected.emit()

func _on_peer_disconnected(id: int = 0) -> void:
	peers.erase(id)
	disconnected.emit()
