#!/usr/bin/env python3
"""
Even G2 胶囊卡片“强制展开”控制参数探测工具

探测目标:
- 测试 AIPromptPayload 的 Tag 4 (status):
  - 默认 status=0 为紧凑折叠态 (末尾带省略号，需单击镜腿展开)
  - 测试 status=1 是否触发固件强制以展开态渲染全部文本！
- 支持切换 card_type (1, 2, 3, 4, 5) 观察是否有原生全屏/展开卡片模式。
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


def build_conversate_ai_prompt(seq: int, title: str, detail: str = "", card_type: int = 4, status: int = 1) -> bytes:
    title_b = title.encode("utf-8")
    detail_b = detail.encode("utf-8")
    
    sub = bytearray()
    # Tag 1: card_type
    sub += bytes([0x08, card_type & 0x7F])
    # Tag 2: title
    if title_b:
        sub += bytes([0x12]) + encode_varint(len(title_b)) + title_b
    if detail_b:
        sub += bytes([0x1A]) + encode_varint(len(detail_b)) + detail_b
    # Tag 4: status (测试 1 是否代表展开态)
    sub += bytes([0x20, status & 0x7F])
    
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
    # 参数 1: card_type (默认 4)
    # 参数 2: status (默认 0)
    # 参数 3: mode ("normal", "empty_title", "card_3", "card_5")
    card_type = int(sys.argv[1]) if len(sys.argv) > 1 else 4
    status_val = int(sys.argv[2]) if len(sys.argv) > 2 else 0
    mode = sys.argv[3] if len(sys.argv) > 3 else "normal"

    if mode == "empty_title":
        multiline_title = ""
        multiline_detail = "这是纯Detail内容：第一行架构探讨，第二行时延测定。"
    else:
        multiline_title = "建议一：探讨系统核心架构"
        multiline_detail = "第一行展开详情：系统架构完整打通。\n第二行展开详情：显存与时序完全掌握。"

    print("=" * 70)
    print("🧪 Even G2 胶囊卡片【强制展开】参数探测实测")
    print(f"⚙️ 测试模式: {mode} | card_type={card_type} | status={status_val}")
    print(f"📝 标题: {repr(multiline_title)}")
    print(f"📄 详情: {repr(multiline_detail)}")
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
        trans1 = f"【基准行】探测参数: card_type={card_type}, status={status_val}"
        print(f"👉 [步骤 2] 下发底部基准转写: '{trans1}'")
        await client.write_gatt_char(CHAR_WRITE, build_conversate_transcript(s_t1, trans1, is_final=True), response=False)
        s_sync1 = next_seq()
        await client.write_gatt_char(CHAR_WRITE, build_conversate_sync(s_sync1), response=False)
        await asyncio.sleep(1.0)

        # 4. 下发测试胶囊
        s_ai = next_seq()
        print(f"\n🌟 [步骤 3: 探测下发] 注入测试胶囊 (seq={s_ai}):")
        ai_pkt = build_conversate_ai_prompt(s_ai, title=multiline_title, detail=multiline_detail, card_type=card_type, status=status_val)
        await client.write_gatt_char(CHAR_WRITE, ai_pkt, response=False)
        
        s_sync2 = next_seq()
        await client.write_gatt_char(CHAR_WRITE, build_conversate_sync(s_sync2), response=False)

        print("\n" + "=" * 65)
        print(f"👀 【请仔细观察镜片 (测试 status={status_val}, card_type={card_type})】:")
        print("   问题 1: 上方胶囊是否直接处于【展开态】（无需单击镜腿即可看到全部内容）？")
        print("   问题 2: 还是依然是【折叠态带省略号】，仍然需要手动单击才能展开？")
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
