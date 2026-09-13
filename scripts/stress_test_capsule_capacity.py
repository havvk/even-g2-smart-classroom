#!/usr/bin/env python3
"""
Even G2 胶囊卡片栈容量上限 (Capacity Stress Test) 实测工具

测试目标:
- 在单次 0x0B-20 会话中，连续快速推送 N 张 (如 15 张) 带明确序号的 AI 胶囊
- 观察固件的卡片历史栈 (Card Stack) 的容量极限与淘汰机制:
  1. 固件卡片列表最多能容纳多少张卡片？(5张？8张？10张？还是无硬性限制？)
  2. 超过上限后，是 FIFO 自动淘汰最早的卡片 (先进先出)，还是拒绝新增？
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
    # 参数 1: total_cards (默认 20)
    # 参数 2: interval (默认 0.35s)
    # 参数 3: observe_sec (默认 25s)
    # 参数 4: card_type (默认 1)
    total_cards = int(sys.argv[1]) if len(sys.argv) > 1 else 20
    interval = float(sys.argv[2]) if len(sys.argv) > 2 else 0.35
    observe_sec = int(sys.argv[3]) if len(sys.argv) > 3 else 25
    card_type = int(sys.argv[4]) if len(sys.argv) > 4 else 1

    print("=" * 70)
    print(f"🔥 Even G2 胶囊卡片测试: 下发 {total_cards} 张 (card_type={card_type})")
    print(f"⚡ 注入速率: 每张间隔 {interval}s | 观察期: {observe_sec}s")
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
        trans1 = f"【100次极限压测】正在连续注入 {total_cards} 张胶囊..."
        await client.write_gatt_char(CHAR_WRITE, build_conversate_transcript(s_t1, trans1, is_final=True), response=False)
        await client.write_gatt_char(CHAR_WRITE, build_conversate_sync(next_seq()), response=False)
        await asyncio.sleep(0.5)

        # 4. 高速连续注入 100 张卡片
        print(f"\n🚀 开始连续注入 {total_cards} 张胶囊卡片 (间隔 {interval} 秒)...")
        t_start = time.time()
        for i in range(1, total_cards + 1):
            s_ai = next_seq()
            title = f"提示 #{i:03d}/{total_cards:03d}: 极限压测"
            detail = f"这是第 {i} 张胶囊的展开详情，用于验证固件 100 张卡片栈容量与 FIFO 淘汰极限。"
            
            pkt = build_conversate_ai_prompt(s_ai, title=title, detail=detail, card_type=card_type)
            await client.write_gatt_char(CHAR_WRITE, pkt, response=False)
            
            s_sync = next_seq()
            await client.write_gatt_char(CHAR_WRITE, build_conversate_sync(s_sync), response=False)
            
            if i % 10 == 0 or i == total_cards:
                print(f"   ⚡ 已注入 [{i:03d}/{total_cards:03d}] (seq={s_ai})...")
            await asyncio.sleep(interval)

        t_cost = time.time() - t_start
        print(f"\n🎉 全部 {total_cards} 张卡片注入完毕！耗时: {t_cost:.1f} 秒！")
        print("=" * 65)
        print("👀 【请现在立刻进行 100 张卡片极限翻阅实测】:")
        print("   1. 单击右镜腿 (Tap Touchpad) 呼出卡片抽屉列表；")
        print("   2. 前后滑动镜腿，查看卡片列表最多能翻出多少张卡片？")
        print("   3. 检查最顶部是第几号？（是否为 #100？）")
        print("   4. 持续向下滑到底，最早的一张保留的是第几号？（能翻到 #001 吗？还是例如 #051 到 #100？）")
        print(f"⏳ 保持会话常开 {observe_sec} 秒供您从容滑动与翻阅...")
        print("=" * 65)

        for rem in range(observe_sec, 0, -1):
            if rem % 5 == 0 or rem <= 5:
                print(f"\r   ⏳ 观察与翻阅倒计时: {rem:02d} 秒...", end="", flush=True)
            await asyncio.sleep(1.0)
        print("\n")

        # 5. 安全优雅退出
        s_exit = next_seq()
        print(f"👉 发送退出指令 (seq={s_exit})...")
        await client.write_gatt_char(CHAR_WRITE, build_conversate_exit(s_exit), response=False)
        print("⏳ 等待 2.0 秒注销会话...")
        await asyncio.sleep(2.0)
        await client.stop_notify(CHAR_NOTIFY)
        print("✅ 终极压测结束，显存已安全释放。")

if __name__ == "__main__":
    asyncio.run(main())
