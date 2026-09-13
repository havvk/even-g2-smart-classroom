#!/usr/bin/env python3
"""
Even G2 强制注销/退出对话模式工具
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


def build_conversate_exit(seq: int) -> bytes:
    payload = bytes([0x08, 0x01, 0x10]) + encode_varint(seq) + bytes([0x1A, 0x04, 0x08, 0x02, 0x20, 0x00])
    return build_packet(seq, 0x0B, 0x20, payload)


def notification_handler(sender, data: bytes):
    if len(data) >= 8 and data[0] == 0xAA:
        seq = data[2]
        shi, slo = data[6], data[7]
        print(f"   📥 眼镜上报: seq=0x{seq:02X} svc=0x{shi:02X}-{slo:02X} | raw={data.hex()[:30]}")


async def main():
    print("🔍 扫描眼镜...")
    devs = await BleakScanner.discover(timeout=4.0)
    g2_devices = [d for d in devs if d.name and "Even G2" in d.name]
    if not g2_devices:
        print("未发现眼镜")
        return
    
    target = g2_devices[0]
    print(f"✅ 连接: {target.name} ({target.address})")

    async with BleakClient(target.address) as client:
        await client.start_notify(CHAR_NOTIFY, notification_handler)
        print("🔑 Auth 握手...")
        for pkt in build_auth_packets():
            await client.write_gatt_char(CHAR_WRITE, pkt, response=False)
            await asyncio.sleep(0.06)
        
        await asyncio.sleep(0.5)
        print("🛑 下发强制注销退出报文 (0x0B-20 Type 1 Action 2)...")
        exit_pkt = build_conversate_exit(8)
        await client.write_gatt_char(CHAR_WRITE, exit_pkt, response=False)
        
        print("⏳ 等待 2.5 秒确保固件完成注销并监听响应...")
        await asyncio.sleep(2.5)
        await client.stop_notify(CHAR_NOTIFY)
        print("✅ 注销命令下发完成，已安全断开连接。")

if __name__ == "__main__":
    asyncio.run(main())
