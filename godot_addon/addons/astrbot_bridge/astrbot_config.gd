## AstrBot Bridge 配置资源
##
## 在 Godot 编辑器中创建此 Resource，设置服务器地址和 API Key。
## 然后拖入 AstrBotBridge 单例的 config 属性中。
class_name AstrBotConfig
extends Resource

@export var server_url: String = "http://127.0.0.1:18230"
@export var api_key: String = ""
@export var auto_connect: bool = true
@export var reconnect_interval: float = 3.0
@export var poll_interval: float = 1.0
@export var max_backlog_on_connect: int = 50


func get_ws_url() -> String:
	var url := server_url.replace("http://", "ws://").replace("https://", "wss://")
	if not url.ends_with("/"):
		url += "/"
	url += "ws"
	if not api_key.is_empty():
		url += "?key=" + api_key
	return url


func get_rest_url(endpoint: String) -> String:
	var base := server_url
	if not base.ends_with("/"):
		base += "/"
	return base + endpoint
