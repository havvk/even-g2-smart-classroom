#!/usr/bin/env python3
"""
Even G2 Dual Viewport Coexistence Test (0x05-20 Top + 0x0B-20 Bottom)

This script verifies whether the Even G2 firmware allows Service 0x05-20 (Top Translation)
and Service 0x0B-20 (Bottom Transcription) to coexist simultaneously on the MicroLED screen.
"""

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
    # Auth 1..7
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


# =============================================================================
# Protocol Packet Builders
# =============================================================================

CONVERSATE_INIT_PAYLOAD_HEX = (
    "080110011ada010801120a0801100118002001280020002a0d0a034f46461206e585b3e997ad"
    "2a140a044155544f120ce887aae58aa8e6a380e6b58b2a180a025a481212e4b8ade69687efbc88e7ae80e4bd93efbc89"
    "2a180a0254571212e4b8ade69687efbc88e7b981e4bd93efbc892a0c0a024a411206e697a5e8afad2a120a024553120c"
    "e8a5bfe78fade78999e8afad2a0c0a0246521206e6b395e8afad2a180a0244451212e5beb7e8afadefbc88e5beb7e59b"
    "bdefbc892a120a024954120ce6848fe5a4a7e588a9e8afad2a0c0a024b4f1206e99fa9e8afad32034f4646"
)

def build_conversate_init(seq: int, msg_id: int) -> bytes:
    payload = bytes.fromhex(CONVERSATE_INIT_PAYLOAD_HEX)
    # Replace msg_id in position 2 (0x10, msg_id)
    payload_arr = bytearray(payload)
    payload_arr[3] = msg_id & 0x7F
    return build_packet(seq, 0x0B, 0x20, bytes(payload_arr))


def build_conversate_transcript(seq: int, msg_id: int, text: str, is_final: bool) -> bytes:
    text_bytes = text.encode("utf-8")
    # Sub-message for field 8
    sub = bytes([0x0A, len(text_bytes)]) + text_bytes + bytes([0x10, 1 if is_final else 0])
    payload = bytes([0x08, 0x06, 0x10]) + encode_varint(msg_id) + bytes([0x42, len(sub)]) + sub
    return build_packet(seq, 0x0B, 0x20, payload)


def build_conversate_sync(seq: int, msg_id: int) -> bytes:
    payload = bytes([0x08, 0xFF, 0x01, 0x10]) + encode_varint(msg_id) + bytes([0x5A, 0x00])
    return build_packet(seq, 0x0B, 0x20, payload)


def build_conversate_exit(seq: int, msg_id: int) -> bytes:
    payload = bytes([0x08, 0x01, 0x10]) + encode_varint(msg_id) + bytes([0x1A, 0x04, 0x08, 0x02, 0x20, 0x00])
    return build_packet(seq, 0x0B, 0x20, payload)


def build_translation_init(seq: int, msg_id: int, pair: str = "ZH>EN") -> bytes:
    pair_bytes = pair.encode("utf-8")
    sub = bytes([0x08, 0x01, 0x12, len(pair_bytes)]) + pair_bytes + bytes([0x18, 0x01])
    payload = bytes([0x08, 0x01, 0x10]) + encode_varint(msg_id) + bytes([0x1A, len(sub)]) + sub
    return build_packet(seq, 0x05, 0x20, payload)


def build_translation_sentence(seq: int, msg_id: int, orig: str, trans: str, speaker: str = "AI Copilot") -> bytes:
    orig_b = orig.encode("utf-8")
    trans_b = trans.encode("utf-8")
    speaker_b = b"\xfe\xff" + speaker.encode("utf-16be")
    
    sub = bytearray()
    sub += bytes([0x0A, len(orig_b)]) + orig_b
    sub += bytes([0x12, len(trans_b)]) + trans_b
    sub += bytes([0x18, 0x00, 0x20, 0x00])
    sub += bytes([0x2A, len(speaker_b)]) + speaker_b
    
    payload = bytes([0x08, 0x02, 0x10]) + encode_varint(msg_id) + bytes([0x22, len(sub)]) + bytes(sub)
    return build_packet(seq, 0x05, 0x20, payload)


def build_translation_exit(seq: int, msg_id: int) -> bytes:
    payload = bytes([0x08, 0x01, 0x10]) + encode_varint(msg_id) + bytes([0x1A, 0x04, 0x08, 0x02, 0x20, 0x00])
    return build_packet(seq, 0x05, 0x20, payload)


# =============================================================================
# Main Test Routine
# =============================================================================

async def main():
    print("=" * 70)
    print("👓 Even G2 双视口共存验证工具 (0x05-20 顶部 + 0x0B-20 底部)")
    print("=" * 70)
    
    print("🔍 正在扫描附近 Even G2 智能眼镜...")
    devices = await BleakScanner.discover(timeout=5.0)
    g2_devices = [d for d in devices if d.name and "Even G2" in d.name]
    
    if not g2_devices:
        print("❌ 未发现 Even G2 智能眼镜，请确保眼镜已开机且处于可连接状态！")
        return
    
    # Prefer right eye for display rendering
    target = next((d for d in g2_devices if "_R_" in d.name), g2_devices[0])
    print(f"✅ 锁定目标眼镜: {target.name} ({target.address})")

    seq = 1
    msg_id = 10

    def next_seq():
        nonlocal seq
        s = seq
        seq = (seq + 1) & 0xFF
        return s

    def next_msg():
        nonlocal msg_id
        m = msg_id
        msg_id += 1
        return m

    async with BleakClient(target.address) as client:
        print("🔗 蓝牙已连接，开始执行 7 步 Auth 握手...")
        for pkt in build_auth_packets():
            await client.write_gatt_char(CHAR_WRITE, pkt, response=False)
            await asyncio.sleep(0.06)
        print("🎉 Auth 握手完成，进入测试阶段！\n")
        
        await asyncio.sleep(1.0)
        
        # -------------------------------------------------------------
        # 阶段 1: 启动 0x0B-20 对话模式，推流底部文字
        # -------------------------------------------------------------
        print("👉 [阶段 1] 启动 0x0B-20 对话模式，激活底部视口...")
        init_pkt = build_conversate_init(next_seq(), next_msg())
        await client.write_gatt_char(CHAR_WRITE, init_pkt, response=False)
        await asyncio.sleep(0.5)
        
        print("   -> 向底部下发流式文字: '【底部】实时对话正在进行...'")
        t1 = build_conversate_transcript(next_seq(), next_msg(), "【底部】实时对话正在进行...", is_final=False)
        await client.write_gatt_char(CHAR_WRITE, t1, response=False)
        await asyncio.sleep(0.8)
        
        print("   -> 触发定稿断句: '【底部】实时对话正在进行。'")
        t2 = build_conversate_transcript(next_seq(), next_msg(), "【底部】实时对话正在进行。", is_final=True)
        await client.write_gatt_char(CHAR_WRITE, t2, response=False)
        await asyncio.sleep(0.1)
        
        s1 = build_conversate_sync(next_seq(), next_msg())
        await client.write_gatt_char(CHAR_WRITE, s1, response=False)
        
        print("\n👀 【请观察镜片】: 此时底部 3 行应该出现了刚才的文字。")
        print("⏳ 保持 3 秒让您确认...\n")
        await asyncio.sleep(3.0)
        
        # -------------------------------------------------------------
        # 阶段 2: 保持 0x0B-20，突然向 0x05-20 下发顶部双语卡片
        # -------------------------------------------------------------
        print("👉 [阶段 2] 关键测试：在底部文字存在时，向 0x05-20 下发顶部双语提示！")
        tr_init = build_translation_init(next_seq(), next_msg(), "ZH>EN")
        await client.write_gatt_char(CHAR_WRITE, tr_init, response=False)
        await asyncio.sleep(0.3)
        
        print("   -> 下发顶部卡片: 原文='💡 AI提示: 对方询问交付周期' 译文='Copilot: 建议提及已过一期验收'")
        tr_sent = build_translation_sentence(
            next_seq(), next_msg(),
            orig="💡 AI提示: 对方询问交付周期",
            trans="Copilot: 建议提及已过一期验收",
            speaker="AI Copilot"
        )
        await client.write_gatt_char(CHAR_WRITE, tr_sent, response=False)
        
        print("\n👀 【核心观察点来了】:")
        print("   1. 顶部是否出现了刚才的提示与译文？")
        print("   2. 此时底部的 '【底部】实时对话正在进行。' 是否仍然存在？还是被清空了？")
        print("⏳ 保持 5 秒供您仔细观察镜片变化...\n")
        await asyncio.sleep(5.0)
        
        # -------------------------------------------------------------
        # 阶段 3: 再次向底部 0x0B-20 追加文字
        # -------------------------------------------------------------
        print("👉 [阶段 3] 验证底部转写能否继续追加更新...")
        t3 = build_conversate_transcript(next_seq(), next_msg(), "【底部追加】第二句也顺利上屏了吗？", is_final=True)
        await client.write_gatt_char(CHAR_WRITE, t3, response=False)
        await client.write_gatt_char(CHAR_WRITE, build_conversate_sync(next_seq(), next_msg()), response=False)
        
        print("\n👀 【观察追加效果】: 顶部和底部是否同时都有内容？")
        print("⏳ 保持 5 秒...\n")
        await asyncio.sleep(5.0)
        
        # -------------------------------------------------------------
        # 阶段 4: 优雅安全注销
        # -------------------------------------------------------------
        print("👉 [阶段 4] 测试完毕，下发优雅退出注销报文...")
        await client.write_gatt_char(CHAR_WRITE, build_translation_exit(next_seq(), next_msg()), response=False)
        await asyncio.sleep(0.2)
        await client.write_gatt_char(CHAR_WRITE, build_conversate_exit(next_seq(), next_msg()), response=False)
        await asyncio.sleep(0.2)
        print("✅ 显存已注销，眼镜恢复待机！测试结束。")

if __name__ == "__main__":
    asyncio.run(main())
