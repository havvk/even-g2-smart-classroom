#!/usr/bin/env python3
"""
Even G2 底部对话转写单项上屏验证工具 (Service 0x0B-20)

针对“启动动画吞包”现象的专门测试：
1. 监听 CHAR_NOTIFY 获取固件 ACK (52 00)
2. 严格等待 4.5 秒让【启动对话】动画完全退隐
3. 保持 seq 与 msg_id 严格一致
4. 提交文字与显存 Sync 帧后，长时间停留在屏幕上供肉眼确认
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


def notification_handler(sender, data: bytes):
    if len(data) >= 8 and data[0] == 0xAA:
        seq = data[2]
        shi, slo = data[6], data[7]
        payload = data[8:-2] if len(data) > 10 else data[8:]
        ack_str = ""
        if b"\x52\x00" in payload:
            ack_str = " -> [✅ ACK 52 00 成功响应!]"
        elif b"\x52" in payload:
            ack_str = f" -> [STATUS: {payload.hex()}]"
        print(f"   📥 眼镜上报: seq=0x{seq:02X} svc=0x{shi:02X}-{slo:02X}{ack_str} | raw={data.hex()[:40]}")


async def main():
    print("=" * 70)
    print("👓 Even G2 对话模式单项上屏测试 (Seq 单调递增与 ACK 闭环)")
    print("=" * 70)
    
    print("🔍 正在扫描附近 Even G2 智能眼镜...")
    devs = await BleakScanner.discover(timeout=5.0)
    g2_devices = [d for d in devs if d.name and "Even G2" in d.name]
    
    if not g2_devices:
        print("❌ 未发现 Even G2 智能眼镜，请确保眼镜已开机！")
        return
    
    for d in g2_devices:
        print(f"   发现设备: {d.name} ({d.address})")
        
    target = g2_devices[0]
    print(f"✅ 连接目标: {target.name} ({target.address})\n")

    seq = 0

    def next_seq():
        nonlocal seq
        seq = (seq + 1) & 0xFF
        return seq

    async with BleakClient(target.address) as client:
        print("🔗 蓝牙已连接，开启 Notification 监听...")
        await client.start_notify(CHAR_NOTIFY, notification_handler)
        
        print("🔑 发送 7 步 Auth 认证报文...")
        for pkt in build_auth_packets():
            # Auth packets use seq 1..7 internally
            next_seq()
            await client.write_gatt_char(CHAR_WRITE, pkt, response=False)
            await asyncio.sleep(0.06)
        print(f"🎉 Auth 完成 (当前 seq={seq})，准备进入对话模式！\n")
        await asyncio.sleep(1.0)

        # 1. 启动对话模式
        s_init = next_seq()
        print(f"👉 [步骤 1] 发送 0x0B-20 启动对话模式 (seq=0x{s_init:02X}, msg_id={s_init})...")
        await client.write_gatt_char(CHAR_WRITE, build_conversate_init(s_init), response=False)
        
        print("\n" + "=" * 60)
        print("👀 【请戴上或观察眼镜镜片】:")
        print("   眼镜此时正在播放【启动对话】系统动画...")
        print("   ⏳ 正在等待 4.5 秒直到动画完全结束并释放显存...")
        print("=" * 60 + "\n")
        await asyncio.sleep(4.5)

        # 2. 动画结束后，发送流式打字文字
        s_t1 = next_seq()
        print(f"👉 [步骤 2] 动画已结束！下发第一行流式文字 (seq=0x{s_t1:02X}): '你好，智能眼镜'")
        pkt_t1 = build_conversate_transcript(s_t1, "你好，智能眼镜", is_final=False)
        await client.write_gatt_char(CHAR_WRITE, pkt_t1, response=False)
        await asyncio.sleep(1.2)

        # 3. 发送定稿断句与显存 Sync
        s_t2 = next_seq()
        print(f"👉 [步骤 3] 下发定稿断句 (seq=0x{s_t2:02X}): '你好，智能眼镜！'")
        pkt_t2 = build_conversate_transcript(s_t2, "你好，智能眼镜！", is_final=True)
        await client.write_gatt_char(CHAR_WRITE, pkt_t2, response=False)
        await asyncio.sleep(0.1)

        s_sync = next_seq()
        print(f"👉 [步骤 4] 下发显存 Sync 锁存帧 (seq=0x{s_sync:02X})...")
        await client.write_gatt_char(CHAR_WRITE, build_conversate_sync(s_sync), response=False)
        await asyncio.sleep(1.0)

        # 4. 发送第二句换行测试
        s_t3 = next_seq()
        print(f"👉 [步骤 5] 下发第二句文字 (seq=0x{s_t3:02X}): '第二行测试：实时转写顺利上屏了吗？'")
        pkt_t3 = build_conversate_transcript(s_t3, "第二行测试：实时转写顺利上屏了吗？", is_final=True)
        await client.write_gatt_char(CHAR_WRITE, pkt_t3, response=False)
        await asyncio.sleep(0.1)
        
        s_sync2 = next_seq()
        await client.write_gatt_char(CHAR_WRITE, build_conversate_sync(s_sync2), response=False)

        print("\n" + "=" * 60)
        print("👀 【请仔细观察镜片底部三行】:")
        print("   1. 是否能看到 '你好，智能眼镜！'？")
        print("   2. 是否能看到 '第二行测试：实时转写顺利上屏了吗？'？")
        print("⏳ 脚本将保持当前屏幕内容 15 秒供您观察，请不要摘下眼镜...")
        print("=" * 60 + "\n")
        
        for remaining in range(15, 0, -1):
            print(f"\r   倒计时剩余 {remaining} 秒保持显示中...", end="", flush=True)
            await asyncio.sleep(1.0)
        print("\n")

        # 5. 安全退出
        s_exit = next_seq()
        print(f"👉 [步骤 6] 保持测试结束，发送优雅退出报文 (seq=0x{s_exit:02X})...")
        await client.write_gatt_char(CHAR_WRITE, build_conversate_exit(s_exit), response=False)
        await asyncio.sleep(0.5)
        
        await client.stop_notify(CHAR_NOTIFY)
        print("✅ 测试结束，显存已释放。")

if __name__ == "__main__":
    asyncio.run(main())
