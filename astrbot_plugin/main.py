"""AstrBot × Godot 通用通信桥

独立 HTTP + WebSocket server，让 AstrBot AI 角色能与 Godot 引擎实时双向通信。
任何 AstrBot 插件都可以通过这个桥接器将消息转发到 Godot 场景中。

通道:
    WebSocket /ws     — 实时双向推送（主通道）
    GET  /messages    — HTTP 轮询（兜底通道）
    POST /send        — 发送消息到 AstrBot
    POST /send_and_reply — 发送并等待 AI 回复
    GET  /health      — 健康检查
"""

import asyncio
import json
import logging
import time
import uuid
from typing import Any

from aiohttp import web

from astrbot.api.event import AstrMessageEvent, MessageChain, filter
from astrbot.api.star import Context, Star
from astrbot.core.config import AstrBotConfig

logger = logging.getLogger("astrbot")


class AstrBotBridge(Star):
    """AstrBot × Godot 通信桥 — HTTP + WebSocket 双通道"""

    def __init__(self, context: Context, config: AstrBotConfig):
        super().__init__(context)
        self.config = config

        # ── 配置 ──
        self._host: str = config.get("server_host", "0.0.0.0")
        self._port: int = config.get("server_port", 18230)
        self._api_key: str = config.get("api_key", "").strip()
        self._max_queue: int = config.get("max_queue_size", 200)
        self._message_ttl: int = config.get("message_ttl", 3600)
        self._enable_cors: bool = config.get("enable_cors", True)

        # ── 内部状态 ──
        self._messages: list[dict] = []
        self._lock = asyncio.Lock()
        self._ws_clients: set[web.WebSocketResponse] = set()
        self._pending_replies: dict[str, asyncio.Future] = {}
        self._server: web.AppRunner | None = None
        self._server_task: asyncio.Task | None = None

    # ════════════════════════════════════════════════════════════════════
    #  生命周期
    # ════════════════════════════════════════════════════════════════════

    @filter.on_astrbot_loaded()
    async def on_loaded(self):
        """AstrBot 加载完成后启动 server"""
        self._server_task = asyncio.create_task(self._start_server())

    async def terminate(self):
        """插件卸载时优雅关闭"""
        # 关闭所有 WebSocket 连接
        for ws in list(self._ws_clients):
            if not ws.closed:
                await ws.close()
        self._ws_clients.clear()

        if self._server:
            await self._server.stop()
            logger.info("[AstrBot Bridge] 服务已停止")

        for future in self._pending_replies.values():
            if not future.done():
                future.cancel()
        self._pending_replies.clear()

    # ════════════════════════════════════════════════════════════════════
    #  HTTP + WebSocket Server
    # ════════════════════════════════════════════════════════════════════

    async def _start_server(self):
        """启动独立 aiohttp server"""
        app = web.Application()

        # REST 端点
        app.router.add_get("/health", self._handle_health)
        app.router.add_get("/messages", self._handle_get_messages)
        app.router.add_post("/send", self._handle_send)
        app.router.add_post("/send_and_reply", self._handle_send_and_reply)

        # WebSocket 端点
        app.router.add_get("/ws", self._handle_ws)

        if self._enable_cors:
            app.middlewares.append(self._cors_middleware)
        if self._api_key:
            app.middlewares.append(self._auth_middleware)

        self._server = web.AppRunner(app)
        await self._server.setup()
        site = web.TCPSite(self._server, self._host, self._port)
        try:
            await site.start()
            logger.info(
                f"[AstrBot Bridge] 服务启动于 http://{self._host}:{self._port}"
            )
            logger.info(f"[AstrBot Bridge] WebSocket: ws://{self._host}:{self._port}/ws")
            logger.info(
                f"[AstrBot Bridge] API Key: {'已启用' if self._api_key else '未启用'}"
            )
        except OSError as e:
            logger.error(f"[AstrBot Bridge] 启动失败（端口 {self._port} 可能被占用）: {e}")

    # ── 中间件 ──────────────────────────────────────────────────────

    @web.middleware
    async def _cors_middleware(self, request: web.Request, handler):
        if request.method == "OPTIONS":
            response = web.Response()
        else:
            response = await handler(request)
        response.headers["Access-Control-Allow-Origin"] = "*"
        response.headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
        response.headers["Access-Control-Allow-Headers"] = "Content-Type, X-API-Key"
        return response

    @web.middleware
    async def _auth_middleware(self, request: web.Request, handler):
        if request.method == "OPTIONS":
            return await handler(request)
        # WebSocket 通过 query param 传递 key
        if request.path == "/ws":
            key = request.query.get("key", "")
            if key != self._api_key:
                return web.Response(status=401, text="Unauthorized")
            return await handler(request)
        # REST 通过 Header
        provided = request.headers.get("X-API-Key", "")
        if provided != self._api_key:
            return web.json_response(
                {"error": "Unauthorized", "message": "无效的 API Key"}, status=401
            )
        return await handler(request)

    # ════════════════════════════════════════════════════════════════════
    #  WebSocket Handler
    # ════════════════════════════════════════════════════════════════════

    async def _handle_ws(self, request: web.Request) -> web.WebSocketResponse:
        """WebSocket /ws — 实时双向通道

        Server → Client 推送格式:
            {"type": "message", "data": { ... 消息体 ... }}

        Client → Server 发送格式:
            {"action": "send", "umo": "...", "text": "..."}
            {"action": "ping"}
        """
        ws = web.WebSocketResponse()
        await ws.prepare(request)

        self._ws_clients.add(ws)
        logger.info(f"[AstrBot Bridge] WebSocket 客户端已连接 (共 {len(self._ws_clients)})")

        try:
            # 连接时发送欢迎 + 积压消息
            async with self._lock:
                backlog = self._messages[-50:]
            await ws.send_json({"type": "connected", "queue_size": len(backlog)})
            for msg in backlog:
                await ws.send_json({"type": "message", "data": msg})

            # 监听客户端消息
            async for raw in ws:
                if raw.type == web.WSMsgType.TEXT:
                    await self._on_ws_client_message(ws, raw.data)
                elif raw.type in (web.WSMsgType.ERROR, web.WSMsgType.CLOSE):
                    break
        finally:
            self._ws_clients.discard(ws)
            logger.info(
                f"[AstrBot Bridge] WebSocket 客户端已断开 (剩余 {len(self._ws_clients)})"
            )

        return ws

    async def _on_ws_client_message(self, ws: web.WebSocketResponse, raw: str):
        """处理 Godot 通过 WebSocket 发来的指令"""
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            await ws.send_json({"type": "error", "message": "无效 JSON"})
            return

        action = data.get("action", "")

        if action == "ping":
            await ws.send_json({"type": "pong"})

        elif action == "send":
            umo = data.get("umo", "").strip()
            text = data.get("text", "").strip()
            if not umo or not text:
                await ws.send_json({"type": "error", "message": "缺少 umo 或 text"})
                return
            try:
                chain = MessageChain().message(text)
                ok = await self.context.send_message(umo, chain)
                await ws.send_json(
                    {"type": "send_result", "success": ok}
                )
            except Exception as e:
                await ws.send_json({"type": "error", "message": str(e)})

        else:
            await ws.send_json({"type": "error", "message": f"未知 action: {action}"})

    async def _broadcast(self, msg: dict):
        """向所有 WebSocket 客户端推送消息"""
        if not self._ws_clients:
            return
        payload = json.dumps({"type": "message", "data": msg})
        dead: list[web.WebSocketResponse] = []
        for ws in self._ws_clients:
            if ws.closed:
                dead.append(ws)
                continue
            try:
                await ws.send_str(payload)
            except Exception:
                dead.append(ws)
        for ws in dead:
            self._ws_clients.discard(ws)

    # ════════════════════════════════════════════════════════════════════
    #  REST Handlers
    # ════════════════════════════════════════════════════════════════════

    async def _handle_health(self, request: web.Request) -> web.Response:
        return web.json_response({
            "status": "ok",
            "queue_size": len(self._messages),
            "ws_clients": len(self._ws_clients),
            "port": self._port,
        })

    async def _handle_get_messages(self, request: web.Request) -> web.Response:
        count = int(request.query.get("count", 20))
        mode = request.query.get("mode", "peek")

        async with self._lock:
            self._purge_expired()
            if mode == "consume":
                batch = self._messages[:count]
                self._messages = self._messages[count:]
            else:
                batch = self._messages[-count:]

        return web.json_response({
            "messages": batch,
            "queue_size": len(self._messages),
        })

    async def _handle_send(self, request: web.Request) -> web.Response:
        data = await self._read_json(request)
        if isinstance(data, web.Response):
            return data

        umo = data.get("umo", "").strip()
        text = data.get("text", "").strip()
        if not umo or not text:
            return self._err(400, "缺少 umo 或 text 参数")

        try:
            chain = MessageChain().message(text)
            ok = await self.context.send_message(umo, chain)
            if ok:
                return web.json_response({"status": "ok"})
            return self._err(404, "未找到匹配的消息平台")
        except Exception as e:
            logger.error(f"[AstrBot Bridge] 发送失败: {e}")
            return self._err(500, str(e))

    async def _handle_send_and_reply(self, request: web.Request) -> web.Response:
        data = await self._read_json(request)
        if isinstance(data, web.Response):
            return data

        umo = data.get("umo", "").strip()
        text = data.get("text", "").strip()
        timeout = min(float(data.get("timeout", 30)), 120)

        if not umo or not text:
            return self._err(400, "缺少 umo 或 text 参数")

        msg_id = str(uuid.uuid4())
        future: asyncio.Future[str] = asyncio.get_event_loop().create_future()
        self._pending_replies[msg_id] = future

        try:
            chain = MessageChain().message(text)
            ok = await self.context.send_message(umo, chain)
            if not ok:
                self._pending_replies.pop(msg_id, None)
                return self._err(404, "未找到匹配的消息平台")

            reply_text = await asyncio.wait_for(future, timeout=timeout)
            return web.json_response({"status": "ok", "reply": reply_text})

        except asyncio.TimeoutError:
            self._pending_replies.pop(msg_id, None)
            return self._err(504, "等待 AI 回复超时")
        except Exception as e:
            self._pending_replies.pop(msg_id, None)
            logger.error(f"[AstrBot Bridge] send_and_reply 失败: {e}")
            return self._err(500, str(e))

    # ════════════════════════════════════════════════════════════════════
    #  消息拦截
    # ════════════════════════════════════════════════════════════════════

    @filter.event_message_type(filter.EventMessageType.ALL, priority=99)
    async def on_message(self, event: AstrMessageEvent):
        """拦截所有消息 → 存入队列 + WebSocket 实时推送"""
        text = event.message_str.strip()
        if not text:
            return

        now = time.time()
        msg = {
            "id": str(uuid.uuid4()),
            "text": text,
            "sender": event.get_sender_name() or "unknown",
            "sender_id": event.get_sender_id(),
            "umo": event.unified_msg_origin,
            "platform": event.platform_meta.name,
            "timestamp": now,
            "expires_at": now + self._message_ttl if self._message_ttl > 0 else None,
        }

        async with self._lock:
            self._messages.append(msg)
            if len(self._messages) > self._max_queue:
                self._messages = self._messages[-self._max_queue:]

        # 实时推送给所有 WebSocket 客户端
        await self._broadcast(msg)

        # 解决 send_and_reply 的 Future
        self._try_resolve_pending_replies(msg)

    def _try_resolve_pending_replies(self, msg: dict):
        if not self._pending_replies:
            return
        for msg_id, future in list(self._pending_replies.items()):
            if not future.done():
                future.set_result(msg["text"])
                self._pending_replies.pop(msg_id, None)
                break

    # ════════════════════════════════════════════════════════════════════
    #  辅助
    # ════════════════════════════════════════════════════════════════════

    def _purge_expired(self):
        if self._message_ttl <= 0:
            return
        now = time.time()
        self._messages = [
            m for m in self._messages
            if m.get("expires_at") is None or m["expires_at"] > now
        ]

    @staticmethod
    async def _read_json(request: web.Request) -> Any:
        try:
            return await request.json()
        except Exception:
            return web.json_response(
                {"error": "Bad Request", "message": "请求体必须是合法 JSON"},
                status=400,
            )

    @staticmethod
    def _err(status: int, message: str) -> web.Response:
        return web.json_response(
            {"error": "Error", "message": message}, status=status
        )
