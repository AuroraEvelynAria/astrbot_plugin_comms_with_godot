## 消息辅助类
##
## 用于构建发送给 AstrBot 的消息，以及解析收到的消息。
class_name AstrBotMessage
extends RefCounted

## 构建发送消息的 Dictionary
static func create_text(umo: String, text: String) -> Dictionary:
	return {
		"umo": umo,
		"text": text,
	}


## 构建带超时的 send_and_reply 消息
static func create_text_with_timeout(umo: String, text: String, timeout: float = 30.0) -> Dictionary:
	return {
		"umo": umo,
		"text": text,
		"timeout": timeout,
	}


## 从 WebSocket 推送中提取消息
## payload 格式: {"type": "message", "data": { ... }}
static func parse_ws_message(payload: Dictionary) -> Dictionary:
	if payload.get("type") == "message":
		return payload.get("data", {})
	return payload


## 从 REST 响应中提取消息数组
static func parse_rest_messages(body: Dictionary) -> Array:
	return body.get("messages", [])
