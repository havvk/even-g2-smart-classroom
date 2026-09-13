#!/usr/bin/env python3
"""
Even G2 对话模式 (0x0B-20) 上半区 AI 提示协议探测工具

用法示例:
    .venv/bin/python3 scripts/probe_conversate_upper_prompt.py --type 2
    .venv/bin/python3 scripts/probe_conversate_upper_prompt.py --type 3
    .venv/bin/python3 scripts/probe_conversate_upper_prompt.py --type 4
"""

import argparse
import asyncio
import sys
import time
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


def build_conversate_exit(seq: int) -> bytes:
    payload = bytes([0x08, 0x01, 0x10]) + encode_varint(seq) + bytes([0x1A, 0x04, 0x08, 0x02, 0x20, 0x00])
    return build_packet(seq, 0x0B, 0x20, payload)


def build_probe_packet(seq: int, ptype: int, title: str, content: str = "", label: str = "Even AI") -> bytes:
    """
    构造指定 Type 的候选 AI 提示报文:
    field_number = ptype + 2
    Tag = (field_number << 3) | 2
    """
    field_num = ptype + 2
    wire_tag = (field_num << 3) | 2
    
    title_b = title.encode("utf-8")
    content_b = content.encode("utf-8")
    label_b = b"\xfe\xff" + label.encode("utf-16be") if label else b""
    
    # 构建子消息
    sub = bytearray()
    # Tag 1: Title / Prompt text
    sub += bytes([0x0A, len(title_b)]) + title_b
    if content:
        # Tag 2: Subtitle / detail
        sub += bytes([0x12, len(content_b)]) + content_b
    if label:
        # Tag 5: Label (e.g. Even AI)
        sub += bytes([0x2A, len(label_b)]) + label_b
        
    payload = bytes([0x08, ptype, 0x10]) + encode_varint(seq) + bytes([wire_tag, len(sub)]) + bytes(sub)
    return build_packet(seq, 0x0B, 0x20, payload)


received_acks = []

def notification_handler(sender, data: bytes):
    if len(data) >= 8 and data[0] == 0xAA:
        seq = data[2]
        shi, slo = data[6], data[7]
        payload = data[8:-2] if len(data) > 10 else data[8:]
        ack_str = ""
        if b"\x52\x00" in payload:
            ack_str = " -> [✅ ACK 52 00 成功响应!]"
        elif b"\x52" in payload:
            ack_str = f" -> [⚠️ STATUS/ERR: {payload.hex()}]"
        print(f"   📥 眼镜响应: seq=0x{seq:02X} svc=0x{shi:02X}-{slo:02X}{ack_str} | raw={data.hex()[:40]}")
        received_acks.append((seq, shi, slo, payload.hex()))


async def run_probe(ptype: int):
    print("=" * 70)
    print(f"🔬 探测 0x0B-20 上半区 AI 提示: 测试 Type = {ptype}")
    print("=" * 70)
    
    print("🔍 扫描 Even G2 智能眼镜...")
    devs = await BleakScanner.discover(timeout=4.0)
    g2_devices = [d for d in devs if d.name and "Even G2" in d.name]
    if not g2_devices:
        print("❌ 未发现 Even G2 智能眼镜！")
        return
        
    target = g2_devices[0]
    print(f"✅ 连接目标: {target.name} ({target.address})\n")

    seq = 0

    def next_seq():
        nonlocal seq
        seq = (seq + 1) & 0xFF
        return seq

    async with BleakClient(target.address) as client:
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
        print(f"👉 [启动] 发送 0x0B-20 会话启动 (seq={s_init})...")
        await client.write_gatt_char(CHAR_WRITE, build_conversate_init(s_init), response=False)
        
        # 2. 等待二分法测定的最佳冷却时间 (2.25s)
        print("⏳ 等待 2.25 秒开场动画释放显存...")
        await asyncio.sleep(2.25)

        # 3. 下发底部对话基准行（确保对话模式处于正常活跃状态）
        s_t1 = next_seq()
        base_text = "【底部基准】对话转写正常进行中..."
        print(f"👉 [底部基准] 下发转写 (seq={s_t1}): '{base_text}'")
        await client.write_gatt_char(CHAR_WRITE, build_conversate_transcript(s_t1, base_text, is_final=True), response=False)
        s_sync1 = next_seq()
        await client.write_gatt_char(CHAR_WRITE, build_conversate_sync(s_sync1), response=False)
        await asyncio.sleep(1.0)

        # 4. 下发探测候选 Type 的上半区提示报文
        s_probe = next_seq()
        title_text = f"💡 AI提示[Type {ptype}]: 探讨架构"
        content_text = "建议询问交付成果与一期排期"
        print(f"\n🚀 [核心探测] 下发 0x0B-20 Type {ptype} (seq={s_probe}):")
        print(f"   标题: '{title_text}'")
        print(f"   详情: '{content_text}'")
        
        probe_pkt = build_probe_packet(s_probe, ptype, title_text, content_text, label="Even AI")
        print(f"   报文 Hex: {probe_pkt.hex()[:50]}... (长度 {len(probe_pkt)}B)")
        await client.write_gatt_char(CHAR_WRITE, probe_pkt, response=False)
        
        # 下发 Sync 锁存
        s_sync2 = next_seq()
        await client.write_gatt_char(CHAR_WRITE, build_conversate_sync(s_sync2), response=False)

        print("\n" + "=" * 60)
        print("👀 【请仔细观察镜片上半部分】:")
        print(f"   1. 上半区是否出现了类似 '{title_text}' 的卡片或文字？")
        print("   2. 底部基准行是否依然完好存在？")
        print("⏳ 保持屏幕显示 10 秒供您确认...")
        print("=" * 60)
        
        for rem in range(10, 0, -1):
            print(f"\r   剩余观察时间: {rem} 秒...", end="", flush=True)
            await asyncio.sleep(1.0)
        print("\n")

        # 5. 安全优雅退出
        s_exit = next_seq()
        print(f"👉 [退出] 发送退出指令 (seq={s_exit})...")
        await client.write_gatt_char(CHAR_WRITE, build_conversate_exit(s_exit), response=False)
        await asyncio.sleep(2.0)
        await client.stop_notify(CHAR_NOTIFY)
        print("✅ 探测完毕，已安全退回待机桌面。\n")


def main():
    parser = argparse.ArgumentParser(description="Even G2 上半区 AI 提示协议探测工具")
    parser.add_argument("--type", type=int, default=2, help="探测的 0x0B-20 消息 Type (默认 2)")
    args = parser.parse_args()

    asyncio.run(run_probe(args.type))


if __name__ == "__main__":
    main()
