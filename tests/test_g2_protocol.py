#!/usr/bin/env python3
"""
Even G2 Smart Glass Protocol Unit Tests
基于 docs/g2_reverse_engineering.md 逆向规范编写的全量协议与算法单元测试
"""

import unittest
import math

# =============================================================================
# Core Protocol Implementations for Verification
# =============================================================================

def crc16_ccitt(data: bytes, init: int = 0xFFFF) -> int:
    crc = init
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) if crc & 0x8000 else (crc << 1)
            crc &= 0xFFFF
    return crc

def add_crc(packet: bytes) -> bytes:
    crc = crc16_ccitt(packet[8:])
    return packet + bytes([crc & 0xFF, (crc >> 8) & 0xFF])

def encode_varint(value: int) -> bytes:
    result = []
    while value > 0x7F:
        result.append((value & 0x7F) | 0x80)
        value >>= 7
    result.append(value & 0x7F)
    return bytes(result)

def build_packets(seq: int, service_hi: int, service_lo: int, payload: bytes, max_chunk_size: int = 232) -> list:
    if len(payload) <= max_chunk_size:
        header = bytes([0xAA, 0x21, seq & 0xFF, (len(payload) + 2) & 0xFF, 0x01, 0x01, service_hi, service_lo])
        return [add_crc(header + payload)]

    crc = crc16_ccitt(payload)
    payload_with_crc = payload + bytes([crc & 0xFF, (crc >> 8) & 0xFF])

    packets = []
    total_chunks = math.ceil(len(payload_with_crc) / max_chunk_size)
    for i in range(total_chunks):
        start = i * max_chunk_size
        end = min(start + max_chunk_size, len(payload_with_crc))
        chunk = payload_with_crc[start:end]
        header = bytes([
            0xAA, 0x21,
            seq & 0xFF,
            len(chunk) & 0xFF,
            total_chunks & 0xFF,
            (i + 1) & 0xFF,
            service_hi, service_lo
        ])
        packets.append(header + chunk)

    return packets

def parse_position_notification(raw_frame: bytes) -> dict:
    """Parse G2 -> Phone Notification frame for Service 0x0601 Type 165"""
    if len(raw_frame) < 10 or raw_frame[0] != 0xAA or raw_frame[1] != 0x12:
        return None
    
    svc_hi = raw_frame[6]
    svc_lo = raw_frame[7]
    if svc_hi != 0x06 or svc_lo != 0x01:
        return None

    payload = raw_frame[8:-2] # Exclude Header (8B) and Trailing CRC (2B)
    
    # Parse Protobuf: Tag 1 = 165 (0xA5 0x01), Tag 2 = msg_id, Tag 11 = event_data
    if len(payload) >= 9 and payload[0] == 0x08 and payload[1] == 0xA5 and payload[2] == 0x01:
        # Tag 11 (0x5A) -> Len -> Tag 2 (0x10) -> current_line
        current_line = payload[8] if len(payload) > 8 else 0
        return {
            "event_type": 165,
            "current_line": current_line,
            "page_id": current_line // 10,
            "raw_line": current_line % 10
        }
    return None

def format_text_to_pages(text: str, max_line_width: int = 56, lines_per_page: int = 10) -> list:
    text = text.replace("\\n", "\n")
    wrapped_lines = []
    for paragraph in text.split("\n"):
        if not paragraph.strip():
            wrapped_lines.append("")
            continue
        current_line = ""
        current_width = 0
        for char in paragraph:
            w = 2 if ord(char) > 0x7F else 1
            if current_width + w > max_line_width:
                wrapped_lines.append(current_line)
                current_line = char
                current_width = w
            else:
                current_line += char
                current_width += w
        if current_line:
            wrapped_lines.append(current_line)

    if not wrapped_lines:
        wrapped_lines = [text]

    pages = []
    for i in range(0, len(wrapped_lines), lines_per_page):
        page_chunk = wrapped_lines[i : i + lines_per_page]
        while len(page_chunk) < lines_per_page:
            page_chunk.append("")
        pages.append("\n".join(page_chunk))

    while len(pages) < 14:
        empty_chunk = [""] * lines_per_page
        pages.append("\n".join(empty_chunk))

    return pages


# =============================================================================
# Unit Test Cases
# =============================================================================

class TestG2Protocol(unittest.TestCase):
    
    def test_single_packet_header_TC_BLE_001(self):
        packets = build_packets(seq=0x08, service_hi=0x06, service_lo=0x20, payload=bytes([0x08, 0x01]))
        self.assertEqual(len(packets), 1)
        pkt = packets[0]
        
        self.assertEqual(pkt[0], 0xAA)
        self.assertEqual(pkt[1], 0x21)
        self.assertEqual(pkt[2], 0x08)
        self.assertEqual(pkt[3], 0x04) # 2B payload + 2B CRC
        self.assertEqual(pkt[4], 0x01)
        self.assertEqual(pkt[5], 0x01)
        self.assertEqual(pkt[6], 0x06)
        self.assertEqual(pkt[7], 0x20)

    def test_crc16_addition_TC_BLE_002(self):
        payload = bytes([0x08, 0x01, 0x10, 0x14])
        packets = build_packets(seq=0x01, service_hi=0x80, service_lo=0x00, payload=payload)
        pkt = packets[0]
        
        crc_actual = pkt[-2] | (pkt[-1] << 8)
        crc_expected = crc16_ccitt(payload)
        self.assertEqual(crc_actual, crc_expected)

    def test_teleprompter_init_parameters_TC_CFG_001(self):
        display = bytes([
            0x08, 0x00, 0x10, 0x00, 0x18, 0x00,
            0x20, 59,
            0x28, 0xC9, 0x04,
            0x30, 0xB7, 0x04,
            0x38, 0xA9, 0x18,
            0x40, 0x00, 0x48, 0x01, 0x50, 0x09, 0x58, 0x00
        ])
        settings = bytes([0x08, 0x01, 0x12, len(display)]) + display
        payload = bytes([0x08, 0x01, 0x10, 0x14, 0x1A, len(settings)]) + settings
        packets = build_packets(seq=0x09, service_hi=0x06, service_lo=0x20, payload=payload)
        
        hex_data = packets[0].hex()
        self.assertIn("203b", hex_data, "display_width 必须设置为 59")
        self.assertIn("30b704", hex_data, "line_height 必须设置为 567")
        self.assertIn("38a918", hex_data, "viewport_height 必须设置为 3113")
        self.assertIn("5009", hex_data, "render_mode 必须设置为 9")

    def test_14_pages_buffer_completion_TC_TXT_003(self):
        short_text = "同学们好，今天我们来讨论 G2 眼镜。"
        pages = format_text_to_pages(short_text)
        
        self.assertGreaterEqual(len(pages), 14, "短文本必须自动扩展补满 14 页缓冲")
        for i, page in enumerate(pages):
            lines = page.split("\n")
            self.assertEqual(len(lines), 10, f"第 {i} 页必须刚好拥有 10 个行位")

    def test_position_notification_decoding_TC_NOTIFY_002(self):
        # 抓包实测数据: Service 0x0601 Notification for Line 3
        raw_frame = bytes.fromhex("aa12470b0101060108a501105e5a02100364d7")
        parsed = parse_position_notification(raw_frame)
        
        self.assertIsNotNone(parsed)
        self.assertEqual(parsed["event_type"], 165)
        self.assertEqual(parsed["current_line"], 3)
        self.assertEqual(parsed["page_id"], 0)
        self.assertEqual(parsed["raw_line"], 3)


if __name__ == "__main__":
    unittest.main()
