#!/usr/bin/env python3
"""
Even G2 独立翻译模式 (0x05-20) 顶部视口上屏测试工具
"""

import asyncio
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


# 官方完整的 218 字节 0x05-20 初始化报文负载 (包含全量语言字典与 ZH>EN)
TRANSLATION_INIT_PAYLOAD_HEX = (
    "0801102a1ac901080112055a483e454e18012a140a044155544f120ce887aae58aa8e6a380e6"
    "b58b2a180a025a481212e4b8ade69687efbc88e7ae80e4bd93efbc892a180a0254571212e4b8"
    "ade69687efbc88e7b981e4bd93efbc892a0c0a024a411206e697a5e8afad2a120a024553120c"
    "e8a5bfe78fade78999e8afad2a0c0a0246521206e6b395e8afad2a180a0244451212e5beb7e8"
    "afadefbc88e5beb7e59bbdefbc892a120a024954120ce6848fe5a4a7e588a9e8afad2a0c0a02"
    "4b4f1206e99fa9e8afad32025a483a02454e"
)

def build_translation_init(seq: int) -> bytes:
    payload = bytes.fromhex(TRANSLATION_INIT_PAYLOAD_HEX)
    payload_arr = bytearray(payload)
    # Replace msg_id in position 2 (0x10, msg_id)
    payload_arr[3] = seq & 0x7F
    return build_packet(seq, 0x05, 0x20, bytes(payload_arr))


def build_translation_sync(seq: int) -> bytes:
    # 0x05-20 使用 Field 8 (0x42 0x00) 作为 Flush Sync Marker
    payload = bytes([0x08, 0xFF, 0x01, 0x10]) + encode_varint(seq) + bytes([0x42, 0x00])
    return build_packet(seq, 0x05, 0x20, payload)


def build_translation_sentence(seq: int, orig: str, trans: str, speaker: str = "Even AI") -> bytes:
    orig_b = orig.encode("utf-8")
    trans_b = trans.encode("utf-8")
    speaker_b = b"\xfe\xff" + speaker.encode("utf-16be")
    
    sub = bytearray()
    sub += bytes([0x0A, len(orig_b)]) + orig_b
    sub += bytes([0x12, len(trans_b)]) + trans_b
    sub += bytes([0x18, 0x00, 0x20, 0x00])
    sub += bytes([0x2A, len(speaker_b)]) + speaker_b
    
    payload = bytes([0x08, 0x02, 0x10]) + encode_varint(seq) + bytes([0x22, len(sub)]) + bytes(sub)
    return build_packet(seq, 0x05, 0x20, payload)


def build_translation_exit(seq: int) -> bytes:
    payload = bytes([0x08, 0x01, 0x10]) + encode_varint(seq) + bytes([0x1A, 0x04, 0x08, 0x02, 0x20, 0x00])
    return build_packet(seq, 0x05, 0x20, payload)


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
    print("=" * 70)
    print("👓 Even G2 独立翻译模式 (0x05-20) 顶部视口上屏测试")
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

        # 1. 启动 0x05-20 翻译模式
        s_init = next_seq()
        print(f"👉 [步骤 1] 发送 0x05-20 翻译模式启动报文 (seq={s_init})...")
        await client.write_gatt_char(CHAR_WRITE, build_translation_init(s_init), response=False)
        
        print("⏳ 等待 3.0 秒开场动画结束...")
        await asyncio.sleep(3.0)

        # 2. 发送开场后的 Flush Sync 锁存
        s_sync1 = next_seq()
        print(f"👉 [步骤 2] 发送开场 Commit Sync 锁存 (seq={s_sync1})...")
        await client.write_gatt_char(CHAR_WRITE, build_translation_sync(s_sync1), response=False)
        await asyncio.sleep(0.8)

        # 3. 下发第一句双语卡片
        s_sent = next_seq()
        orig_text = "💡 建议探讨核心架构与一期验收"
        trans_text = "Suggest discussing architecture & phase 1"
        print(f"👉 [步骤 3] 下发顶部双语卡片 (seq={s_sent}):")
        print(f"   原文: '{orig_text}'")
        print(f"   译文: '{trans_text}'")
        print("   标签: 'Even AI'")
        pkt_sent = build_translation_sentence(s_sent, orig_text, trans_text, speaker="Even AI")
        await client.write_gatt_char(CHAR_WRITE, pkt_sent, response=False)
        await asyncio.sleep(0.2)

        # 4. 发送内容 Commit Sync
        s_sync2 = next_seq()
        await client.write_gatt_char(CHAR_WRITE, build_translation_sync(s_sync2), response=False)

        print("\n" + "=" * 60)
        print("👀 【请仔细观察镜片顶部/上半部分】:")
        print("   1. 是否在屏幕顶部看到了双语文字与 Even AI 标签？")
        print("   2. 它的排版位置与字号大概是怎样的？")
        print("⏳ 保持常显 10 秒供您观察...")
        print("=" * 60)

        for rem in range(10, 0, -1):
            print(f"\r   剩余观察时间: {rem} 秒...", end="", flush=True)
            await asyncio.sleep(1.0)
        print("\n")

        # 5. 退出
        s_exit = next_seq()
        print(f"👉 [步骤 5] 发送退出注销报文 (seq={s_exit})...")
        await client.write_gatt_char(CHAR_WRITE, build_translation_exit(s_exit), response=False)
        print("⏳ 等待 2.5 秒固件处理退出（会弹出【翻译已保存】）并退回待机...")
        await asyncio.sleep(2.5)
        await client.stop_notify(CHAR_NOTIFY)
        print("✅ 测试结束，已退回待机桌面。")

if __name__ == "__main__":
    asyncio.run(main())
