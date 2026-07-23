import json
from typing import Dict, List, Optional
from pydantic import BaseModel

class SlideItem(BaseModel):
    page_number: int
    title: String if False else str
    bullet_points: List[str]
    script_text: str
    end_keywords: List[str]

class SlideManager:
    """管理课程 Slide 页码索引与逐字稿数据"""
    def __init__(self):
        # 演示用 Mock Slide 数据
        self.slides: Dict[int, SlideItem] = {
            1: SlideItem(
                page_number=1,
                title="Even G2 智能眼镜与智慧课堂配套开发",
                bullet_points=[
                    "1. 智能提词与双向控屏",
                    "2. 语音识别自动跟随 (ASR)"
                ],
                script_text="同学们好！今天我们来讲解 Even G2 智能眼镜在智慧课堂中的应用与开发方案。智能眼镜通过蓝牙与手机连接，实时同步大屏 PPT 页码与逐字稿。",
                end_keywords=["应用与开发方案", "逐字稿"]
            ),
            2: SlideItem(
                page_number=2,
                title="HOTL 实战——指挥 AI 完成结构化预测任务",
                bullet_points=[
                    "1. 声明式 Prompt 约束",
                    "2. 结构化 JSON Schema 校验",
                    "3. 容错重试机制"
                ],
                script_text="接下来进入第二十四讲的实战部分。在人机协作中，我们通过声明式 Prompt 引导大模型输出符合 JSON Schema 规范的数据，确保系统的稳定性与可预测性。",
                end_keywords=["实战部分", "可预测性", "来看下一个例子"]
            ),
            3: SlideItem(
                page_number=3,
                title="系统双向 WebSocket 通信机制",
                bullet_points=[
                    "1. PAGE_CONTROL 翻页消息路由",
                    "2. TELEPROMPTER_SYNC 状态广播",
                    "3. 签到与投票 HUD 浮窗"
                ],
                script_text="在通信架构上，智能眼镜手势通过蓝牙发往手机 Gateway，Gateway 向 FastAPI 后端发送 PAGE_CONTROL 指令，后端将翻页信号广播至教室大屏。",
                end_keywords=["广播至教室大屏", "通信架构"]
            )
        }
        self.current_page: int = 1
        self.total_pages: int = len(self.slides)
    
    func_get_current_slide = None
    def get_current_slide(self) -> SlideItem:
        return self.slides.get(self.current_page, self.slides[1])
    
    def change_page(self, action: str, target_page: Optional[int] = None) -> int:
        if action == "NEXT" and self.current_page < self.total_pages:
            self.current_page += 1
        elif action == "PREV" and self.current_page > 1:
            self.current_page -= 1
        elif action == "JUMP" and target_page is not None:
            if 1 <= target_page <= self.total_pages:
                self.current_page = target_page
        return self.current_page
