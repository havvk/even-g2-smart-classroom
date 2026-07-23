import unittest
import asyncio
import json
import sys
import os

# 将 server_plugin 路径加入 PYTHONPATH
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from slide_manager import SlideManager, SlideItem
from fastapi.testclient import TestClient
from main import app, build_teleprompter_sync_payload

class TestSlideManager(unittest.TestCase):
    """测试 Slide 翻页与逐字稿索引逻辑"""
    
    def setUp(self):
        self.mgr = SlideManager()

    def test_initial_state(self):
        self.assertEqual(self.mgr.current_page, 1)
        self.assertEqual(self.mgr.total_pages, 3)
        slide = self.mgr.get_current_slide()
        self.assertIn("Even G2", slide.title)
        self.assertTrue(len(slide.bullet_points) > 0)

    def test_page_next_and_prev(self):
        # 翻到下一页
        page = self.mgr.change_page("NEXT")
        self.assertEqual(page, 2)
        slide = self.mgr.get_current_slide()
        self.assertIn("HOTL 实战", slide.title)

        # 再次翻到下一页 (已达第 3 页)
        page = self.mgr.change_page("NEXT")
        self.assertEqual(page, 3)

        # 超过上限测试 (应该保持在 3 页)
        page = self.mgr.change_page("NEXT")
        self.assertEqual(page, 3)

        # 翻回上一页
        page = self.mgr.change_page("PREV")
        self.assertEqual(page, 2)

    def test_page_jump(self):
        page = self.mgr.change_page("JUMP", target_page=3)
        self.assertEqual(page, 3)

        # 跳转非法页码 (应该保持当前页)
        page = self.mgr.change_page("JUMP", target_page=99)
        self.assertEqual(page, 3)


class TestWebSocketProtocol(unittest.TestCase):
    """测试 WebSocket 翻页指令与多模态 trigger_source 响应"""
    
    def setUp(self):
        self.client = TestClient(app)

    def test_rest_health_check(self):
        response = self.client.get("/")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["status"], "online")

    def test_rest_session_info(self):
        response = self.client.get("/api/session/test_sess/info")
        self.assertEqual(response.status_code, 200)
        data = response.json()
        self.assertEqual(data["type"], "TELEPROMPTER_SYNC")
        self.assertEqual(data["current_page"], 1)

    def test_websocket_page_control_flow(self):
        """模拟 WebSocket 双向翻页与多模态手势触发"""
        with self.client.websocket_connect("/ws/session/sess_test_ws") as websocket:
            # 1. 握手阶段：自动下发初始 Page 1 逐字稿
            init_data = websocket.receive_json()
            self.assertEqual(init_data["type"], "TELEPROMPTER_SYNC")
            self.assertEqual(init_data["current_page"], 1)

            # 2. 发送 Apple Watch 捏手指翻页指令 (WATCH_DOUBLE_TAP)
            cmd_watch = {
                "type": "PAGE_CONTROL",
                "session_id": "sess_test_ws",
                "action": "NEXT",
                "trigger_source": "WATCH_DOUBLE_TAP",
                "timestamp": 1784783900
            }
            websocket.send_json(cmd_watch)

            # 3. 验证广播推送的更新逐字稿 (跳至 Page 2)
            resp_watch = websocket.receive_json()
            self.assertEqual(resp_watch["type"], "TELEPROMPTER_SYNC")
            self.assertEqual(resp_watch["current_page"], 2)
            self.assertIn("HOTL 实战", resp_watch["slide_title"])

            # 4. 发送 Apple Watch 手腕甩动翻页指令 (WATCH_WRIST_FLICK)
            cmd_flick = {
                "type": "PAGE_CONTROL",
                "session_id": "sess_test_ws",
                "action": "NEXT",
                "trigger_source": "WATCH_WRIST_FLICK",
                "timestamp": 1784783910
            }
            websocket.send_json(cmd_flick)

            resp_flick = websocket.receive_json()
            self.assertEqual(resp_flick["current_page"], 3)


if __name__ == "__main__":
    unittest.main()
