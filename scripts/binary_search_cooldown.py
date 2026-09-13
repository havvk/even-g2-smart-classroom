#!/usr/bin/env python3
"""
Even G2 启动对话显存冷却时间二分法测定工具

用法示例:
    .venv/bin/python3 scripts/binary_search_cooldown.py --cooldown 2.5
"""

import argparse
import asyncio
import sys
import time
from bleak import BleakClient, BleakScanner

# BLE UUIDs
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


async def run_probe(cooldown: float):
    print("=" * 70)
    print(f"🎯 二分法显存冷却测定: 目标等待时间 = {cooldown:.2f} 秒")
    print("=" * 70)
    
    print("🔍 正在扫描附近 Even G2 智能眼镜...")
    devs = await BleakScanner.discover(timeout=5.0)
    g2_devices = [d for d in devs if d.name and "Even G2" in d.name]
    
    if not g2_devices:
        print("❌ 未发现 Even G2 智能眼镜，请确保眼镜已开机！")
        return False
        
    target = g2_devices[0]
    print(f"✅ 连接目标: {target.name} ({target.address})\n")

    seq = 0

    def next_seq():
        nonlocal seq
        seq = (seq + 1) & 0xFF
        return seq

    async with BleakClient(target.address) as client:
        print("🔑 发送 7 步 Auth 认证报文...")
        for pkt in build_auth_packets():
            next_seq()
            await client.write_gatt_char(CHAR_WRITE, pkt, response=False)
            await asyncio.sleep(0.06)
        print(f"🎉 Auth 完成 (seq={seq})")
        await asyncio.sleep(0.5)

        # 1. 发送启动对话报文
        s_init = next_seq()
        t_start = time.time()
        print(f"👉 [启动] 发送 0x0B-20 启动对话模式 (seq={s_init})...")
        await client.write_gatt_char(CHAR_WRITE, build_conversate_init(s_init), response=False)
        
        # 2. 严格等待测试的 cooldown 时间
        print(f"⏳ 正在严格精确等待冷却时间: {cooldown:.2f} 秒...")
        await asyncio.sleep(cooldown)
        actual_cooldown = time.time() - t_start

        # 3. 立即下发测试文字
        text_stream = f"【冷却 {cooldown:.2f}s】实时打字中"
        text_final = f"【冷却 {cooldown:.2f}s】测试文字顺利显示！"
        
        s_t1 = next_seq()
        print(f"👉 [下发] t+{actual_cooldown:.2f}s 流式文字 (seq={s_t1}): '{text_stream}'")
        await client.write_gatt_char(CHAR_WRITE, build_conversate_transcript(s_t1, text_stream, is_final=False), response=False)
        await asyncio.sleep(0.8)

        s_t2 = next_seq()
        print(f"👉 [下发] 定稿标点 (seq={s_t2}): '{text_final}'")
        await client.write_gatt_char(CHAR_WRITE, build_conversate_transcript(s_t2, text_final, is_final=True), response=False)
        await asyncio.sleep(0.1)

        s_sync = next_seq()
        print(f"👉 [提交] 显存 Sync (seq={s_sync})")
        await client.write_gatt_char(CHAR_WRITE, build_conversate_sync(s_sync), response=False)

        print("\n" + "=" * 60)
        print(f"👀 【请观察镜片】: 此时屏幕是否出现了 '{text_final}'？")
        print("⏳ 屏幕将保持 8 秒供您肉眼确认...")
        print("=" * 60)
        
        for rem in range(8, 0, -1):
            print(f"\r   剩余观察时间: {rem} 秒...", end="", flush=True)
            await asyncio.sleep(1.0)
        print("\n")

        # 4. 安全退出
        s_exit = next_seq()
        print(f"👉 [退出] 发送退出指令 (seq={s_exit})...")
        await client.write_gatt_char(CHAR_WRITE, build_conversate_exit(s_exit), response=False)
        print("⏳ 等待 2.0 秒确保固件注销会话并安全退回待机...")
        await asyncio.sleep(2.0)
        print("✅ 本轮测试完毕，眼镜已完全退回待机。\n")
        return True


def main():
    parser = argparse.ArgumentParser(description="Even G2 显存冷却时间测定工具")
    parser.add_argument("--cooldown", type=float, default=2.5, help="等待冷却秒数 (默认 2.5s)")
    args = parser.parse_args()

    asyncio.run(run_probe(args.cooldown))


if __name__ == "__main__":
    main()
