#!/usr/bin/env python3
"""
Even G2 对话模式主动软件展开 (Active Expand) 真机测试工具

测试目标:
- 在下发 Type 5 (AI Prompt 胶囊) 后，由手机主动下发 0x0B-20 Type 3 报文
- 验证是否能够绕过物理镜腿单击，实现远程全自动撑开多行详情卡片！
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
    sub += bytes([0x08, card_type & 0x7F])
    if title_b:
        sub += bytes([0x12]) + encode_varint(len(title_b)) + title_b
    if detail_b:
        sub += bytes([0x1A]) + encode_varint(len(detail_b)) + detail_b
    sub += bytes([0x20, 0x00])
    
    payload = bytes([0x08, 0x05, 0x10]) + encode_varint(seq) + bytes([0x3A]) + encode_varint(len(sub)) + bytes(sub)
    return build_packet(seq, 0x0B, 0x20, payload)


def build_conversate_active_expand(seq: int, variant: int = 1) -> bytes:
    """
    构造主动展开控制报文 (Service 0x0B-20, Type = 3)
    variant 1: 镜像带参展开指令 (携带 Tag 12: 62 03 20 9a 2d)
    variant 2: 精简 Type 3 展开指令 (Tag 1 = 3, Tag 2 = msg_id)
    """
    payload = bytearray()
    payload += bytes([0x08, 0x03])            # Tag 1: type = 3 (Expand Card)
    payload += bytes([0x10]) + encode_varint(seq) # Tag 2: msg_id = seq
    
    if variant == 1:
        # 携带真实抓包里的 Tag 12 载荷: 62 03 20 9a 2d
        payload += bytes([0x62, 0x03, 0x20, 0x9A, 0x2D])
    
    return build_packet(seq, 0x0B, 0x20, bytes(payload))


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
        elif (shi, slo) == (0x0B, 0x01):
            ack_str = f" -> [🌟 0x0B-01 展开事件回执! hex={payload.hex()}]"
        print(f"   📥 眼镜响应: seq=0x{seq:02X} svc=0x{shi:02X}-{slo:02X}{ack_str}")


async def main():
    variant = int(sys.argv[1]) if len(sys.argv) > 1 else 1

    multiline_title = "建议一：探讨系统核心架构\n建议二：测定显存冷却时延"
    multiline_detail = "第一行展开详情：系统架构完整打通。\n第二行展开详情：显存与时序完全掌握。"

    print("=" * 70)
    print(f"🔮 Even G2 主动发包软件控制展开实测 (Variant: {variant})")
    print(f"📝 标题: {multiline_title}")
    print(f"📄 详情: {multiline_detail}")
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

        # 3. 底部基准行
        s_t1 = next_seq()
        trans1 = "【基准转写】测试主动发包 Type 3 控制胶囊展开..."
        await client.write_gatt_char(CHAR_WRITE, build_conversate_transcript(s_t1, trans1, is_final=True), response=False)
        await client.write_gatt_char(CHAR_WRITE, build_conversate_sync(next_seq()), response=False)
        await asyncio.sleep(0.8)

        # 4. 下发折叠态胶囊
        s_ai = next_seq()
        print(f"\n🌟 [步骤 2] 下发折叠胶囊 (seq={s_ai})...")
        pkt = build_conversate_ai_prompt(s_ai, title=multiline_title, detail=multiline_detail, card_type=4)
        await client.write_gatt_char(CHAR_WRITE, pkt, response=False)
        await client.write_gatt_char(CHAR_WRITE, build_conversate_sync(next_seq()), response=False)

        print("⏳ 保持折叠态 2.0 秒，请观察此时是单行带省略号...")
        await asyncio.sleep(2.0)

        # 5. 核心高光动作：主动发送 Type 3 展开控制报文！
        s_expand = next_seq()
        print(f"\n🚀 [步骤 3: 核心动作] 主动下发 Type 3 展开报文 (seq={s_expand}, variant={variant})...")
        expand_pkt = build_conversate_active_expand(s_expand, variant=variant)
        await client.write_gatt_char(CHAR_WRITE, expand_pkt, response=False)
        
        # 显存 Sync 脉冲
        await client.write_gatt_char(CHAR_WRITE, build_conversate_sync(next_seq()), response=False)

        print("\n" + "=" * 65)
        print("👀 【请在接下来的 15 秒内观察镜片 (全程请勿触碰眼镜腿!)】:")
        print("   现象 A: 刚才单行的胶囊是否【自动垂直撑开】显示了多行详情？！")
        print("   现象 B: 还是胶囊没有变化，依然保持原来的折叠单行态？")
        print("=" * 65)

        for rem in range(15, 0, -1):
            print(f"\r   ⏳ 观察倒计时: {rem} 秒...", end="", flush=True)
            await asyncio.sleep(1.0)
        print("\n")

        # 6. 安全优雅退出
        s_exit = next_seq()
        print(f"👉 发送退出指令 (seq={s_exit})...")
        await client.write_gatt_char(CHAR_WRITE, build_conversate_exit(s_exit), response=False)
        await asyncio.sleep(2.0)
        await client.stop_notify(CHAR_NOTIFY)
        print("✅ 测试结束，显存已释放。")

if __name__ == "__main__":
    asyncio.run(main())
