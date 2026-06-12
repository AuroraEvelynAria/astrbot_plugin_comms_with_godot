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

## 延迟连接 autoload 信号（避免解析时找不到 autoload）
var _bridge: Node = null


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	# 运行时查找 autoload 单例
	_bridge = get_node_or_null("/root/AstrBotBridge")
	if _bridge == null:
		push_warning("[AstrBotHandler] 未找到 AstrBotBridge autoload，请确认插件已启用")
		return
	if _bridge.has_signal("message_received"):
		_bridge.message_received.connect(_on_bridge_message)
	if _bridge.has_signal("connection_changed"):
		_bridge.connection_changed.connect(_on_connection_changed)


## 连接状态
var is_connected: bool:
	get:
		if _bridge and _bridge.has_method("is_server_connected"):
			return _bridge.is_server_connected()
		return false


## 发送文本消息到绑定的会话
func send_message(text: String) -> void:
	if umo.is_empty():
		push_warning("[AstrBotHandler] umo 未设置，无法发送消息")
		return
	if _bridge:
		_bridge.send_text(umo, text)


## 发送到指定会话
func send_message_to(target_umo: String, text: String) -> void:
	if _bridge:
		_bridge.send_text(target_umo, text)


## 发送并等待 AI 回复
func send_and_wait(text: String, callback: Callable, timeout: float = 30.0) -> void:
	if umo.is_empty():
		push_warning("[AstrBotHandler] umo 未设置，无法发送消息")
		return
	if _bridge:
		_bridge.send_and_wait(umo, text, callback, timeout)


# ════════════════════════════════════════════════════════════════════
#  虚方法 — 子类重写
# ════════════════════════════════════════════════════════════════════

## 收到消息时调用。子类重写此方法处理消息。
func _on_message(_text: String, _sender: String, _data: Dictionary) -> void:
	pass


## 连接状态变化时调用
func _on_connection_changed(_connected: bool) -> void:
	pass


# ════════════════════════════════════════════════════════════════════
#  内部
# ════════════════════════════════════════════════════════════════════

func _on_bridge_message(data: Dictionary) -> void:
	if filter_by_umo and not umo.is_empty():
		if data.get("umo", "") != umo:
			return
	var text: String = data.get("text", "")
	var sender: String = data.get("sender", "unknown")
	_on_message(text, sender, data)
