## AstrBot Bridge 核心单例（Autoload）
##
## 提供 WebSocket + HTTP 双通道与 AstrBot 通信。
## - WebSocket 为实时主通道，消息到达即推送。
## - HTTP 轮询为兜底通道，WebSocket 断开时自动降级。
##
## 用法:
##   AstrBotBridge.send_text("会话ID", "你好")
##   AstrBotBridge.send_and_wait("会话ID", "你好", _on_reply)
##
## 信号:
##   message_received(data)    — 收到新消息
##   connection_changed(ok)    — 连接状态变化
##   send_completed(success)   — 发送完成
class_name AstrBotBridgeCore
extends Node

signal message_received(data: Dictionary)
signal connection_changed(connected: bool)
signal send_completed(success: bool)

@export var config: AstrBotConfig

var _ws := WebSocketPeer.new()
var _connected := false
var _was_connected := false
var _use_polling := false
var _poll_timer := 0.0
var _reconnect_timer := 0.0
var _poll_http := HTTPRequest.new()
var _send_http := HTTPRequest.new()
var _waiting_callbacks: Dictionary = {}  # HTTPRequest -> Callable


func _ready() -> void:
	# 如果编辑器里没拖 config，用默认值
	if config == null:
		config = AstrBotConfig.new()
		config.resource_local_to_scene = true

	add_child(_poll_http)
	add_child(_send_http)
	_poll_http.request_completed.connect(_on_poll_completed)
	_send_http.request_completed.connect(_on_send_completed)

	if config.auto_connect:
		call_deferred("connect_to_server")


func connect_to_server() -> void:
	var url := config.get_ws_url()
	print("[AstrBot Bridge] 正在连接 ", url)
	_ws.connect_to_url(url)
	_reconnect_timer = 0.0


func disconnect_from_server() -> void:
	_ws.close()
	_connected = false
	_was_connected = false
	_use_polling = false
	connection_changed.emit(false)


## 发送文本消息到 AstrBot（转发到 QQ 等平台）
func send_text(umo: String, text: String) -> void:
	if umo.is_empty() or text.is_empty():
		push_warning("[AstrBot Bridge] send_text: umo 和 text 不能为空")
		return

	if _connected and not _use_polling:
		# WebSocket 通道
		_ws.send_text(JSON.stringify({
			"action": "send",
			"umo": umo,
			"text": text,
		}))
	else:
		# HTTP 通道
		var body := JSON.stringify(AstrBotMessage.create_text(umo, text))
		var headers := _make_headers()
		var err := _send_http.request(config.get_rest_url("send"), headers, HTTPClient.METHOD_POST, body)
		if err != OK:
			push_error("[AstrBot Bridge] HTTP send 请求失败: ", err)
			send_completed.emit(false)


## 发送消息并注册回调等待 AI 回复
func send_and_wait(umo: String, text: String, callback: Callable, timeout: float = 30.0) -> void:
	if umo.is_empty() or text.is_empty():
		push_warning("[AstrBot Bridge] send_and_wait: umo 和 text 不能为空")
		return

	var body := JSON.stringify(AstrBotMessage.create_text_with_timeout(umo, text, timeout))
	var headers := _make_headers()
	var http := HTTPRequest.new()
	add_child(http)
	http.timeout = timeout + 5.0
	http.request_completed.connect(func(result, code, _h, b):
		_on_wait_reply_completed(http, callback, result, code, b)
	)
	_waiting_callbacks[http] = callback
	var err := http.request(config.get_rest_url("send_and_reply"), headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		push_error("[AstrBot Bridge] send_and_wait 请求失败: ", err)
		http.queue_free()
		callback.call(false, "")


## 是否已连接（WebSocket 或 HTTP 任一通道可用）
func is_server_connected() -> bool:
	return _connected or _use_polling


func get_connection_mode() -> String:
	if _connected and not _use_polling:
		return "websocket"
	elif _use_polling:
		return "http_polling"
	return "disconnected"


# ════════════════════════════════════════════════════════════════════
#  主循环
# ════════════════════════════════════════════════════════════════════

func _process(delta: float) -> void:
	_ws.poll()

	# 检查 WebSocket 状态变化
	var state := _ws.get_ready_state()

	if state == WebSocketPeer.STATE_OPEN:
		if not _connected:
			_connected = true
			_was_connected = true
			_use_polling = false
			print("[AstrBot Bridge] WebSocket 已连接")
			connection_changed.emit(true)
		# 读取服务端推送
		while _ws.get_available_packet_count() > 0:
			var packet := _ws.get_packet()
			_handle_ws_packet(packet.get_string_from_utf8())

	elif state == WebSocketPeer.STATE_CLOSING:
		pass  # 等待关闭完成

	elif state == WebSocketPeer.STATE_CLOSED:
		if _was_connected:
			var code := _ws.get_close_code()
			var reason := _ws.get_close_reason()
			print("[AstrBot Bridge] WebSocket 已断开: %d %s" % [code, reason])
			_connected = false
			_was_connected = false
			connection_changed.emit(false)
			# 尝试降级到 HTTP 轮询
			_start_polling_fallback()
		# 自动重连
		_reconnect_timer += delta
		if _reconnect_timer >= config.reconnect_interval:
			_reconnect_timer = 0.0
			print("[AstrBot Bridge] 尝试重连...")
			_ws.connect_to_url(config.get_ws_url())

	# HTTP 轮询降级
	if _use_polling:
		_poll_timer += delta
		if _poll_timer >= config.poll_interval:
			_poll_timer = 0.0
			_do_poll()


# ════════════════════════════════════════════════════════════════════
#  WebSocket 处理
# ════════════════════════════════════════════════════════════════════

func _handle_ws_packet(raw: String) -> void:
	if raw.is_empty():
		return
	var json := JSON.new()
	var err := json.parse(raw)
	if err != OK:
		push_warning("[AstrBot Bridge] 无法解析 WS 数据: ", raw.left(100))
		return

	var data: Dictionary = json.data
	var msg_type: String = data.get("type", "")

	match msg_type:
		"connected":
			print("[AstrBot Bridge] 服务端确认连接，积压消息: ", data.get("queue_size", 0))
		"message":
			var msg: Dictionary = data.get("data", {})
			message_received.emit(msg)
		"pong":
			pass
		"error":
			push_warning("[AstrBot Bridge] 服务端错误: ", data.get("message", ""))
		"send_result":
			send_completed.emit(data.get("success", false))
		_:
			push_warning("[AstrBot Bridge] 未知消息类型: ", msg_type)


# ════════════════════════════════════════════════════════════════════
#  HTTP 轮询降级
# ════════════════════════════════════════════════════════════════════

func _start_polling_fallback() -> void:
	_use_polling = true
	_poll_timer = 0.0
	print("[AstrBot Bridge] 降级到 HTTP 轮询模式")
	if not _connected:
		_connected = true
		connection_changed.emit(true)


func _do_poll() -> void:
	var url := config.get_rest_url("messages?mode=consume&count=20")
	var headers := _make_headers()
	# 避免上一个请求还没完成
	if _poll_http.get_http_client_status() == HTTPClient.STATUS_DISCONNECTED:
		_poll_http.request(url, headers)


func _on_poll_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		return
	var json := JSON.new()
	if json.parse(body.get_string_from_utf8()) != OK:
		return
	var messages: Array = json.data.get("messages", [])
	for msg in messages:
		message_received.emit(msg)


func _on_send_completed(result: int, code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	send_completed.emit(result == HTTPRequest.RESULT_SUCCESS and code == 200)


func _on_wait_reply_completed(http: HTTPRequest, callback: Callable, result: int, code: int, body: PackedByteArray) -> void:
	_waiting_callbacks.erase(http)
	http.queue_free()

	if result != HTTPRequest.RESULT_SUCCESS:
		callback.call(false, "")
		return

	var json := JSON.new()
	if json.parse(body.get_string_from_utf8()) != OK:
		callback.call(false, "")
		return

	var success: bool = json.data.get("status", "") == "ok"
	var reply: String = json.data.get("reply", "")
	callback.call(success, reply)


# ════════════════════════════════════════════════════════════════════
#  辅助
# ════════════════════════════════════════════════════════════════════

func _make_headers() -> PackedStringArray:
	var headers := PackedStringArray(["Content-Type: application/json"])
	if not config.api_key.is_empty():
		headers.append("X-API-Key: " + config.api_key)
	return headers
