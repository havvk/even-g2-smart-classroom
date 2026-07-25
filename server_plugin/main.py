import json
import asyncio
from typing import Dict, List
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from slide_manager import SlideManager

app = FastAPI(title="Even G2 Smart Classroom Teleprompter Backend")

# ASGI 代理路径纠偏中间件 (彻底消除 HTTP 代理 Absolute URI 导致的 403 路由匹配失败)
class FixProxyWebSocketMiddleware:
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope.get("type") == "websocket":
            path = scope.get("path", "")
            if "ws/session/" in path:
                session_id = path.split("ws/session/")[-1]
                # 剔除可能多余的 query 参数或尾巴
                session_id = session_id.split("?")[0].split("/")[0]
                clean_path = f"/ws/session/{session_id}"
                scope["path"] = clean_path
                scope["raw_path"] = clean_path.encode('ascii')
        await self.app(scope, receive, send)

app.add_middleware(FixProxyWebSocketMiddleware)

# 跨域设置
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

import socket

# 自动获取本机局域网 IP
def get_lan_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "127.0.0.1"

# 局域网 UDP 自动服务发现广播信标 (Port 8001)
async def udp_beacon_task():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    
    while True:
        try:
            lan_ip = get_lan_ip()
            beacon_data = json.dumps({
                "service": "SMART_CLASSROOM_SERVER",
                "port": 8000,
                "default_session": "sess_demo",
                "ws_url": f"ws://{lan_ip}:8000/ws/session/sess_demo"
            }, ensure_ascii=False).encode('utf-8')
            sock.sendto(beacon_data, ('<broadcast>', 8001))
        except Exception:
            pass
        await asyncio.sleep(2)

@app.on_event("startup")
async def startup_event():
    asyncio.create_task(udp_beacon_task())

# 简单 WebSocket 连接池管理
class ConnectionManager:
    def __init__(self):
        self.active_connections: Dict[str, List[WebSocket]] = {}

    async def connect(self, session_id: str, websocket: WebSocket):
        await websocket.accept()
        if session_id not in self.active_connections:
            self.active_connections[session_id] = []
        self.active_connections[session_id].append(websocket)

    def disconnect(self, session_id: str, websocket: WebSocket):
        if session_id in self.active_connections:
            if websocket in self.active_connections[session_id]:
                self.active_connections[session_id].remove(websocket)

    async def broadcast(self, session_id: str, message: dict):
        if session_id in self.active_connections:
            # 关键：避免参数倒置 (message, session_id) -> json payload
            payload_str = json.dumps(message, ensure_ascii=False)
            for connection in self.active_connections[session_id]:
                try:
                    await connection.send_text(payload_str)
                except Exception:
                    pass

manager = ConnectionManager()
slide_mgr = SlideManager()

def build_teleprompter_sync_payload(session_id: str) -> dict:
    slide = slide_mgr.get_current_slide()
    return {
        "type": "TELEPROMPTER_SYNC",
        "session_id": session_id,
        "current_page": slide.page_number,
        "total_pages": slide_mgr.total_pages,
        "slide_title": slide.title,
        "bullet_points": slide.bullet_points,
        "script_text": slide.script_text,
        "end_keywords": slide.end_keywords,
        "classroom_status": {
            "phase": "LECTURE",
            "checkin_count": 42,
            "total_count": 45
        }
    }

from pydantic import BaseModel

class G2LogPayload(BaseModel):
    direction: str = "Rx"
    hex_bytes: str = ""
    description: str = ""

@app.post("/api/g2/log")
async def report_g2_log(payload: G2LogPayload):
    symbol = "📥 [G2 -> iPad Rx]" if payload.direction == "Rx" else "📤 [iPad -> G2 Tx]"
    print(f"\033[93m👓 [G2 蓝牙实时日志] {symbol} | {payload.description} | HEX: [{payload.hex_bytes}]\033[0m")
    return {"status": "ok"}

@app.get("/")
async def root():
    return {"status": "online", "system": "Even G2 Smart Classroom Backend"}

@app.get("/api/session/{session_id}/info")
async def get_session_info(session_id: str):
    return build_teleprompter_sync_payload(session_id)

@app.websocket("/ws/session/{session_id}")
async def websocket_endpoint(websocket: WebSocket, session_id: str):
    await manager.connect(session_id, websocket)
    # 建立连接时立即下发当前 Slide 逐字稿
    initial_sync = build_teleprompter_sync_payload(session_id)
    await websocket.send_text(json.dumps(initial_sync, ensure_ascii=False))
    
    try:
        while True:
            data_str = await websocket.receive_text()
            try:
                data = json.loads(data_str)
                msg_type = data.get("type")
                
                if msg_type == "G2_TELEMETRY_LOG":
                    direction = data.get("direction", "Rx")
                    hex_bytes = data.get("hex_bytes", "")
                    desc = data.get("description", "")
                    if direction == "Rx":
                        print(f"\033[92m📥 [G2 -> iPad Rx] {desc} | HEX: [{hex_bytes}]\033[0m")
                    elif direction == "Tx":
                        print(f"\033[96m📤 [iPad -> G2 Tx] {desc} | HEX: [{hex_bytes}]\033[0m")
                    else:
                        print(f"\033[93mℹ️ [G2 BLE 系统日志] {desc}\033[0m")
                elif msg_type == "PAGE_CONTROL":
                    action = data.get("action", "NEXT")
                    target_page = data.get("target_page")
                    # 执行翻页
                    slide_mgr.change_page(action, target_page)
                    # 广播更新后的逐字稿与页码给所有端 (大屏 + 智能眼镜)
                    sync_payload = build_teleprompter_sync_payload(session_id)
                    await manager.broadcast(session_id, sync_payload)
            except json.JSONDecodeError:
                pass
    except WebSocketDisconnect:
        manager.disconnect(session_id, websocket)
