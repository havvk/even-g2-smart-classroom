#!/usr/bin/env python3
"""
Even G2 对话模式 (0x0B-20) 原生 AI 文本胶囊多行文本容纳能力实测工具

测试目标:
- 测试向 Type 5 (AIPromptPayload) 的 title 字段注入含换行符 '\n' 的多行文本
- 观察 MicroLED 光学引擎上的呈现现象:
  1. 胶囊外框是否自适应垂直拉高，完整包裹两行文字？
  2. 第二行文字是否正常换行渲染？还是被忽略/转换为空格/截断？
"""

import asyncio
import time
import sys
from bleak import BleakClient, BleakScanner

UUID_BASE = "00002760-08c2-11e1-9073-0e8ac72e{:04x}"
CHAR_WRITE = UUID_BASE.format(0x5401)
CHAR_NOTIFY = UUID_BASE.format(0x5402)


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


def build_packet(seq: int, service_hi: int, service_lo: int, payload: bytes) -> bytes:
    plen = len(payload) + 2
    header = bytes([0xAA, 0x21, seq & 0xFF, plen & 0xFF, 0x01, 0x01, service_hi, service_lo])
    return add_crc(header + payload)


def build_auth_packets() -> list:
    timestamp = int(time.time())
    ts_varint = encode_varint(timestamp)
    txid = bytes([0xE8, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01])
    packets = []
    packets.append(add_crc(bytes([0xAA, 0x21, 0x01, 0x0C, 0x01, 0x01, 0x80, 0x00, 0x08, 0x04, 0x10, 0x0C, 0x1A, 0x04, 0x08, 0x01, 0x10, 0x04])))
    packets.append(add_crc(bytes([0xAA, 0x21, 0x02, 0x0A, 0x01, 0x01, 0x80, 0x20, 0x08, 0x05, 0x10, 0x0E, 0x22, 0x02, 0x08, 0x02])))
    payload = bytes([0x08, 0x80, 0x01, 0x10, 0x0F, 0x82, 0x08, 0x11, 0x08]) + ts_varint + bytes([0x10]) + txid
    packets.append(add_crc(bytes([0xAA, 0x21, 0x03, len(payload) + 2, 0x01, 0x01, 0x80, 0x20]) + payload))
    packets.append(add_crc(bytes([0xAA, 0x21, 0x04, 0x0C, 0x01, 0x01, 0x80, 0x00, 0x08, 0x04, 0x10, 0x10, 0x1A, 0x04, 0x08, 0x01, 0x10, 0x04])))
    packets.append(add_crc(bytes([0xAA, 0x21, 0x05, 0x0C, 0x01, 0x01, 0x80, 0x00, 0x08, 0x04, 0x10, 0x11, 0x1A, 0x04, 0x08, 0x01, 0x10, 0x04])))
    packets.append(add_crc(bytes([0xAA, 0x21, 0x06, 0x0A, 0x01, 0x01, 0x80, 0x20, 0x08, 0x05, 0x10, 0x12, 0x22, 0x02, 0x08, 0x01])))
    payload = bytes([0x08, 0x80, 0x01, 0x10, 0x13, 0x82, 0x08, 0x11, 0x08]) + ts_varint + bytes([0x10]) + txid
    packets.append(add_crc(bytes([0xAA, 0x21, 0x07, len(payload) + 2, 0x01, 0x01, 0x80, 0x20]) + payload))
    return packets


CONVERSATE_INIT_PAYLOAD_HEX = (
    "080110011ada010801120a0801100118002001280020002a0d0a034f46461206e585b3e997ad"
    "2a140a044155544f120ce887aae58aa8e6a380e6b58b2a180a025a481212e4b8ade69687efbc88e7ae80e4bd93efbc89"
    "2a180a0254571212e4b8ade69687efbc88e7b981e4bd93efbc892a0c0a024a411206e697a5e8afad2a120a024553120c"
    "e8a5bfe78fade78999e8afad2a0c0a0246521206e6b395e8afad2a180a0244451212e5beb7e8afadefbc88e5beb7e59b"
    "bdefbc892a120a024954120ce6848fe5a4a7e588a9e8afad2a0c0a024b4f1206e99fa9e8afad32034f4646"
)

def build_conversate_init(seq: int) -> bytes:
    payload = bytes.fromhex(CONVERSATE_INIT_PAYLOAD_HEX)
    payload_arr = bytearray(payload)
    payload_arr[3] = seq & 0x7F
    return build_packet(seq, 0x0B, 0x20, bytes(payload_arr))


def build_conversate_transcript(seq: int, text: str, is_final: bool) -> bytes:
    text_bytes = text.encode("utf-8")
    sub = bytes([0x0A, len(text_bytes)]) + text_bytes + bytes([0x10, 1 if is_final else 0])
    payload = bytes([0x08, 0x06, 0x10]) + encode_varint(seq) + bytes([0x42, len(sub)]) + sub
    return build_packet(seq, 0x0B, 0x20, payload)


def build_conversate_sync(seq: int) -> bytes:
    payload = bytes([0x08, 0xFF, 0x01, 0x10]) + encode_varint(seq) + bytes([0x5A, 0x00])
    return build_packet(seq, 0x0B, 0x20, payload)


def build_conversate_ai_prompt(seq: int, title: str, detail: str = "", card_type: int = 4) -> bytes:
    title_b = title.encode("utf-8")
    detail_b = detail.encode("utf-8")
    
    sub = bytearray()
    # Tag 1: card_type
    sub += bytes([0x08, card_type & 0x7F])
    # Tag 2: title (包含换行符)
    sub += bytes([0x12]) + encode_varint(len(title_b)) + title_b
    if detail_b:
        sub += bytes([0x1A]) + encode_varint(len(detail_b)) + detail_b
    # Tag 4: status = 0
    sub += bytes([0x20, 0x00])
    
    payload = bytes([0x08, 0x05, 0x10]) + encode_varint(seq) + bytes([0x3A]) + encode_varint(len(sub)) + bytes(sub)
    return build_packet(seq, 0x0B, 0x20, payload)


def build_conversate_exit(seq: int) -> bytes:
    payload = bytes([0x08, 0x01, 0x10]) + encode_varint(seq) + bytes([0x1A, 0x04, 0x08, 0x02, 0x20, 0x00])
    return build_packet(seq, 0x0B, 0x20, payload)


def notification_handler(sender, data: bytes):
    if len(data) >= 8 and data[0] == 0xAA:
        seq = data[2]
        shi, slo = data[6], data[7]
        payload = data[8:-2] if len(data) > 10 else data[8:]
        ack_str = ""
        if b"\x52\x00" in payload:
            ack_str = " -> [✅ ACK 52 00 成功响应!]"
        print(f"   📥 眼镜响应: seq=0x{seq:02X} svc=0x{shi:02X}-{slo:02X}{ack_str}")


async def main():
    # 测试用多行文本 (包含显式换行符 \n)
    multiline_title = "建议一：探讨系统核心架构\n建议二：测定显存冷却时延"
    multiline_detail = "这是多行文本胶囊测试：第一行探讨架构，第二行探讨时延。"

    print("=" * 70)
    print("🧪 Even G2 文本胶囊多行文本容纳能力实测")
    print(f"📝 测试 Payload 文本:")
    print(f"   Line 1: 建议一：探讨系统核心架构")
    print(f"   Line 2: 建议二：测定显存冷却时延")
    print(f"   包含换行符: {repr(multiline_title)}")
    print("=" * 70)

    target_addr = "924B5A41-1C98-3280-A4FB-6F7AE55E6E27"
    devs = await BleakScanner.discover(timeout=5.0)
    g2_devices = [d for d in devs if d.name and "Even G2" in d.name]
    if g2_devices:
        target = g2_devices[0]
        print(f"✅ 找到设备: {target.name} ({target.address})\n")
        target_addr = target.address

    seq = 0
    def next_seq():
        nonlocal seq
        seq = (seq + 1) & 0xFF
        return seq

    async with BleakClient(target_addr) as client:
        await client.start_notify(CHAR_NOTIFY, notification_handler)
        
        print("🔑 发送 7 步 Auth 认证...")
        for pkt in build_auth_packets():
            next_seq()
            await client.write_gatt_char(CHAR_WRITE, pkt, response=False)
            await asyncio.sleep(0.06)
        print(f"🎉 Auth 完成 (seq={seq})")
        await asyncio.sleep(0.5)

        # 1. 启动对话模式
        s_init = next_seq()
        print(f"👉 [步骤 1] 启动 0x0B-20 对话模式 (seq={s_init})...")
        await client.write_gatt_char(CHAR_WRITE, build_conversate_init(s_init), response=False)
        
        # 2. 避让 2.25s 动画
        print("⏳ 避让 2.25 秒开场动画...")
        await asyncio.sleep(2.25)

        # 3. 底部下发基准转写
        s_t1 = next_seq()
        trans1 = "【底部基准】正在测试上方文本胶囊多行渲染..."
        print(f"👉 [步骤 2] 下发底部基准转写: '{trans1}'")
        await client.write_gatt_char(CHAR_WRITE, build_conversate_transcript(s_t1, trans1, is_final=True), response=False)
        s_sync1 = next_seq()
        await client.write_gatt_char(CHAR_WRITE, build_conversate_sync(s_sync1), response=False)
        await asyncio.sleep(1.0)

        # 4. 下发多行文本胶囊！
        s_ai = next_seq()
        print(f"\n🌟 [步骤 3: 关键操作] 注入多行文本胶囊 (seq={s_ai}):")
        ai_pkt = build_conversate_ai_prompt(s_ai, title=multiline_title, detail=multiline_detail, card_type=4)
        await client.write_gatt_char(CHAR_WRITE, ai_pkt, response=False)
        
        s_sync2 = next_seq()
        await client.write_gatt_char(CHAR_WRITE, build_conversate_sync(s_sync2), response=False)

        print("\n" + "=" * 65)
        print("👀 【请在接下来的 15 秒内仔细观察镜片上方胶囊】:")
        print("   问题 A: 胶囊卡片的外框是否被撑高，内部完整显示了 2 行文字？")
        print("   问题 B: 还是胶囊只显示了第一行，或者把换行符变成了空格？")
        print("   问题 C: 文字有没有被边框裁剪截断？")
        print("=" * 65)

        for rem in range(15, 0, -1):
            print(f"\r   ⏳ 观察倒计时: {rem} 秒...", end="", flush=True)
            await asyncio.sleep(1.0)
        print("\n")

        # 5. 安全优雅退出
        s_exit = next_seq()
        print(f"👉 [步骤 4] 发送退出指令 (seq={s_exit})...")
        await client.write_gatt_char(CHAR_WRITE, build_conversate_exit(s_exit), response=False)
        print("⏳ 等待 2.0 秒注销会话...")
        await asyncio.sleep(2.0)
        await client.stop_notify(CHAR_NOTIFY)
        print("✅ 测试结束，显存已释放。")

if __name__ == "__main__":
    asyncio.run(main())
