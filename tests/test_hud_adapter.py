import unittest

class HUDLayoutAdapterPython:
    """Python 版本的 HUD 排版与切片算法实现 (匹配 Swift HUDLayoutAdapter)"""
    def __init__(self, max_chars_per_line: int = 18):
        self.max_chars_per_line = max_chars_per_line

    def format_script_to_lines(self, script: str) -> list:
        lines = []
        raw_paragraphs = [p.strip() for p in script.replace("！", "。").replace("？", "。").split("。") if p.strip()]
        
        for paragraph in raw_paragraphs:
            current_line = ""
            for char in paragraph:
                current_line += char
                if len(current_line) >= self.max_chars_per_line:
                    lines.append(current_line)
                    current_line = ""
            if current_line:
                lines.append(current_line)
        return lines

    def build_hud_chunk(self, current_page: int, total_pages: int, checkin_text: str, lines: list, active_line_index: int) -> dict:
        header = f"[P{current_page:02d}/{total_pages:02d}] {checkin_text}"
        if not lines:
            return {
                "header_text": header,
                "highlighted_line": "暂无逐字稿提示",
                "next_line_preview": "轻按戒指切换 Slide",
                "footer_status": "‹ 上一页 | 下一页 ›"
            }
        
        valid_idx = min(max(0, active_line_index), len(lines) - 1)
        active_line = lines[valid_idx]
        next_line = lines[valid_idx + 1] if valid_idx + 1 < len(lines) else "--- 本页终点 ---"
        
        return {
            "header_text": header,
            "highlighted_line": active_line,
            "next_line_preview": next_line,
            "footer_status": "‹ 上一页 | 下一页 ›"
        }

class TestHUDLayoutAdapter(unittest.TestCase):
    def setUp(self):
        self.adapter = HUDLayoutAdapterPython(max_chars_per_line=18)

    def test_format_script_to_lines(self):
        script = "同学们好！今天我们来讲解 Even G2 智能眼镜在智慧课堂中的应用与开发方案。智能眼镜通过蓝牙与手机连接。"
        lines = self.adapter.format_script_to_lines(script)
        
        self.assertTrue(len(lines) > 0)
        for line in lines:
            self.assertLessEqual(len(line), 18)

    def test_build_hud_chunk(self):
        lines = ["同学们好", "今天我们来讲解 Even G2", "智能眼镜在智慧课堂中的应用"]
        chunk = self.adapter.build_hud_chunk(
            current_page=1,
            total_pages=24,
            checkin_text="签到 42/45",
            lines=lines,
            active_line_index=0
        )
        
        self.assertEqual(chunk["header_text"], "[P01/24] 签到 42/45")
        self.assertEqual(chunk["highlighted_line"], "同学们好")
        self.assertEqual(chunk["next_line_preview"], "今天我们来讲解 Even G2")

if __name__ == "__main__":
    unittest.main()
