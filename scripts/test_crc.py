import time
import math

def encode_varint(value: int) -> bytes:
    if value < 0:
        value += 1 << 64
    out = []
    while value >= 0x80:
        out.append((value & 0x7F) | 0x80)
        value >>= 7
    out.append(value)
    return bytes(out)

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

pkt1 = bytes([
    0xAA, 0x21, 0x01, 0x0C, 0x01, 0x01, 0x80, 0x00,
    0x08, 0x04, 0x10, 0x0C, 0x1A, 0x04, 0x08, 0x01, 0x10, 0x04
])
res1 = add_crc(pkt1)
print(f"Python Auth1: {res1.hex()}")
