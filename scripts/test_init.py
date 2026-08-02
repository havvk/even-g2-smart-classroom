def encode_varint(value: int) -> bytes:
    result = []
    while value > 0x7F:
        result.append((value & 0x7F) | 0x80)
        value >>= 7
    result.append(value & 0x7F)
    return bytes(result)

def crc16_ccitt(data: bytes) -> int:
    crc = 0xFFFF
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) if crc & 0x8000 else (crc << 1)
            crc &= 0xFFFF
    return crc

def add_crc(packet: bytes) -> bytes:
    crc = crc16_ccitt(packet[8:])
    return packet + bytes([crc & 0xFF, (crc >> 8) & 0xFF])

def build_packets(seq, service_hi, service_lo, payload):
    header = bytes([0xAA, 0x21, seq & 0xFF, (len(payload) + 2) & 0xFF, 0x01, 0x01, service_hi, service_lo])
    return add_crc(header + payload)

seq = 0x08
msg_id = 0x15

display = bytes([
    0x08, 0x00,
    0x10, 0x00,
    0x18, 0x00,
    0x20, 59,
    0x28, 0xC9, 0x04,
    0x30, 0xB7, 0x04,
    0x38, 0xA9, 0x18,
    0x40, 0x00,
    0x48, 0x01,
    0x50, 0x09,
    0x58, 0x00
])
settings = bytes([0x08, 0x01, 0x12, len(display)]) + display
payload = bytes([0x08, 0x01, 0x10]) + encode_varint(msg_id) + bytes([0x1A, len(settings)]) + settings
print("Python Init:")
print(build_packets(seq, 0x06, 0x20, payload).hex())
