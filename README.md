# AstrBot × Godot 通信桥

> 让 AstrBot AI 角色实时接入 Godot 引擎，构建虚拟世界中的智能 NPC。

```
QQ用户 ←→ AstrBot ←[本插件]→ Godot 2D/3D 场景
```

## ✨ 特性

- **WebSocket 实时推送** — 消息到达即推，零延迟
- **HTTP 轮询降级** — WebSocket 断开时自动切换，保证可用
- **双向通信** — Godot 既能收消息也能发消息
- **可配置认证** — 可选 API Key 保护
- **通用设计** — 不绑定任何角色，适用于任何 AstrBot + Godot 项目
- **即插即用** — Godot 端提供 Autoload 单例 + 可继承 Handler Node

## 📁 项目结构

```
astrbot_plugin/          ← 复制到 AstrBot 的 data/plugins/ 目录
├── main.py              # AstrBot 插件核心
├── metadata.yaml        # 插件元数据
├── requirements.txt     # Python 依赖
└── _conf_schema.json    # 配置 Schema

godot_addon/             ← 复制 addons/ 到你的 Godot 项目
└── addons/astrbot_bridge/
    ├── plugin.cfg       # Godot 插件描述
    ├── plugin.gd        # 编辑器入口
    ├── astrbot_bridge.gd    # 核心单例（Autoload）
    ├── astrbot_config.gd    # 配置 Resource
    ├── astrbot_handler.gd   # 可继承的消息处理 Node
    └── astrbot_message.gd   # 消息辅助类
```

## 🚀 快速开始

### 第一步：安装 AstrBot 插件

1. 复制 `astrbot_plugin/` 到 AstrBot 的 `data/plugins/astrbot_bridge/`
2. 重启 AstrBot
3. 在 AstrBot WebUI → 插件管理中找到 **AstrBot × Godot 通信桥**
4. 根据需要修改配置（默认端口 `18230`）

### 第二步：安装 Godot 插件

1. 复制 `godot_addon/addons/astrbot_bridge/` 到你的 Godot 项目的 `addons/` 目录
2. 在 Godot 中：**项目 → 项目设置 → 插件** → 启用 **AstrBot Bridge**
3. 插件会自动注册 `AstrBotBridge` Autoload 单例

### 第三步：在场景中使用

#### 方式一：使用 AstrBotHandler（推荐）

```gdscript
# 小玲.gd — 继承 AstrBotHandler
extends AstrBotHandler

func _ready() -> void:
    super._ready()
    umo = "aiocqhttp:group_123456:friend_789"  # 绑定会话

func _on_message(text: String, sender: String, data: Dictionary) -> void:
    print("%s 说: %s" % [sender, text])

    if "跳舞" in text:
        $AnimationPlayer.play("dance")
        send_message("小玲开始跳舞啦~")
    elif "过来" in text:
        walk_to_player()

func _on_connection_changed(connected: bool) -> void:
    if connected:
        print("与 AstrBot 已连接！")
```

#### 方式二：直接使用单例

```gdscript
func _ready() -> void:
    AstrBotBridge.message_received.connect(_on_msg)

func _on_msg(data: Dictionary) -> void:
    print("收到: ", data.get("text"))

func send_hello() -> void:
    AstrBotBridge.send_text("aiocqhttp:group_123456:friend_789", "你好！")
```

## 🔌 通信协议

### WebSocket 实时通道

连接地址：`ws://127.0.0.1:18230/ws`

#### 服务端推送（Server → Client）

```json
// 新消息
{"type": "message", "data": {
    "id": "uuid",
    "text": "消息内容",
    "sender": "发送者名",
    "sender_id": "发送者ID",
    "umo": "会话标识",
    "platform": "aiocqhttp",
    "timestamp": 1234567890.0
}}

// 连接确认（含积压消息数量）
{"type": "connected", "queue_size": 5}

// 心跳响应
{"type": "pong"}

// 发送结果
{"type": "send_result", "success": true}
```

#### 客户端指令（Client → Server）

```json
// 发送消息
{"action": "send", "umo": "会话ID", "text": "消息内容"}

// 心跳
{"action": "ping"}
```

### REST 兜底通道

| 端点 | 方法 | 说明 |
|------|------|------|
| `/health` | GET | 健康检查 |
| `/messages?count=20&mode=consume` | GET | 获取消息队列 |
| `/send` | POST | 发送消息 `{"umo":"...","text":"..."}` |
| `/send_and_reply` | POST | 发送并等 AI 回复 `{"umo":"...","text":"...","timeout":30}` |

## ⚙️ AstrBot 插件配置

| 字段 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `server_host` | string | `0.0.0.0` | 监听地址 |
| `server_port` | int | `18230` | 监听端口 |
| `api_key` | string | `""` | API 密钥（留空不验证） |
| `max_queue_size` | int | `200` | 消息队列最大容量 |
| `message_ttl` | int | `3600` | 消息过期秒数（0=永不过期） |
| `enable_cors` | bool | `true` | CORS 跨域支持 |

## 🎮 Godot 配置

创建 `AstrBotConfig` Resource 或直接在代码中配置：

```gdscript
# 在编辑器 Inspector 中设置，或代码创建：
var config := AstrBotConfig.new()
config.server_url = "http://127.0.0.1:18230"
config.api_key = ""          # 与 AstrBot 插件一致
config.auto_connect = true
config.reconnect_interval = 3.0
config.poll_interval = 1.0   # HTTP 降级时的轮询间隔
```

## 🏗️ 典型场景

### 虚拟猫娘小屋

```gdscript
extends AstrBotHandler

@onready var cat_girl: AnimatedSprite2D = $CatGirl

func _on_message(text: String, sender: String, _data: Dictionary) -> void:
    if "摸头" in text:
        cat_girl.play("happy")
        send_message("*开心地蹭蹭*")
    elif "吃饭" in text:
        cat_girl.play("eat")
        send_message("*大口大口吃* 好好吃~")
```

### 多人聊天室

```gdscript
extends AstrBotHandler

func _on_message(text: String, sender: String, _data: Dictionary) -> void:
    # 在 3D 场景中显示聊天气泡
    var bubble = bubble_scene.instantiate()
    bubble.text = "%s: %s" % [sender, text]
    $ChatLog.add_child(bubble)
```

## 📝 更新日志

### v1.0.0
- 初始发布
- WebSocket 实时双向通信
- HTTP REST 轮询降级
- Godot Autoload 单例 + AstrBotHandler 可继承 Node
- 可选 API Key 认证
- 可视化配置（AstrBot WebUI）

## 📄 许可证

MIT License — 自由使用、修改、分发。
