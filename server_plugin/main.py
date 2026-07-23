import json
import asyncio
from typing import Dict, List
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from slide_manager import SlideManager

app = FastAPI(title="Even G2 Smart Classroom Teleprompter Backend")

# 跨域设置
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

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
                
                if msg_type == "PAGE_CONTROL":
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
