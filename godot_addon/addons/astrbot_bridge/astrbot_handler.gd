## 可继承的消息处理 Node
##
## 将此节点添加到场景中，设置 umo 绑定到指定会话，
## 然后重写 _on_message() 处理收到的消息。
##
## 用法:
##   extends AstrBotHandler
##
##   func _on_message(text: String, sender: String, data: Dictionary) -> void:
##       print("%s 说: %s" % [sender, text])
##       if text == "跳舞":
##           $AnimationPlayer.play("dance")
##           send_message("小玲开始跳舞啦~")
##
class_name AstrBotHandler
extends Node

## 绑定的消息会话 ID（如 QQ 群/私聊的 unified_msg_origin）
## 留空则接收所有会话的消息
@export var umo: String = ""

## 是否只接收本会话消息（false 则接收所有消息）
@export var filter_by_umo: bool = false

## 连接状态
var is_connected: bool:
	get:
		if AstrBotBridge and AstrBotBridge.is_server_connected():
			return true
		return false


func _ready() -> void:
	if not Engine.is_editor_hint():
		AstrBotBridge.message_received.connect(_on_bridge_message)
		AstrBotBridge.connection_changed.connect(_on_connection_changed)


## 发送文本消息到绑定的会话
func send_message(text: String) -> void:
	if umo.is_empty():
		push_warning("[AstrBotHandler] umo 未设置，无法发送消息")
		return
	AstrBotBridge.send_text(umo, text)


## 发送到指定会话
func send_message_to(target_umo: String, text: String) -> void:
	AstrBotBridge.send_text(target_umo, text)


## 发送并等待 AI 回复
func send_and_wait(text: String, callback: Callable, timeout: float = 30.0) -> void:
	if umo.is_empty():
		push_warning("[AstrBotHandler] umo 未设置，无法发送消息")
		return
	AstrBotBridge.send_and_wait(umo, text, callback, timeout)


# ════════════════════════════════════════════════════════════════════
#  虚方法 — 子类重写
# ════════════════════════════════════════════════════════════════════

## 收到消息时调用。子类重写此方法处理消息。
##   text   — 消息文本
##   sender — 发送者名称
##   data   — 完整消息 Dictionary（含 sender_id, umo, platform, timestamp 等）
func _on_message(_text: String, _sender: String, _data: Dictionary) -> void:
	pass


## 连接状态变化时调用
func _on_connection_changed(_connected: bool) -> void:
	pass


# ════════════════════════════════════════════════════════════════════
#  内部
# ════════════════════════════════════════════════════════════════════

func _on_bridge_message(data: Dictionary) -> void:
	# UMO 过滤
	if filter_by_umo and not umo.is_empty():
		if data.get("umo", "") != umo:
			return

	var text: String = data.get("text", "")
	var sender: String = data.get("sender", "unknown")
	_on_message(text, sender, data)
