import time

def encode_varint(value: int) -> bytes:
    """Encode an integer as a protobuf varint."""
    if value < 0:
        value += 1 << 64
    out = []
    while value >= 0x80:
        out.append((value & 0x7F) | 0x80)
        value >>= 7
    out.append(value)
    return bytes(out)

def add_crc(payload: bytes) -> bytes:
    """Calculate and append Modbus CRC16 to the payload."""
    crc = 0xFFFF
    for b in payload:
        crc ^= b
        for _ in range(8):
            if crc & 1:
                crc = (crc >> 1) ^ 0xA001
            else:
                crc >>= 1
    return payload + bytes([crc & 0xFF, (crc >> 8) & 0xFF])

def build_packets(seq: int, service_hi: int, service_lo: int, payload: bytes) -> list:
    """Split payload into BLE packets with Even G2 L2CAP-like headers."""
    packets = []
    total_len = len(payload) + 2
    offset = 0

    while offset < len(payload):
        chunk_len = min(len(payload) - offset, 240) # assume mtu is large enough
        chunk = payload[offset:offset+chunk_len]

        is_first = (offset == 0)
        is_last = (offset + chunk_len >= len(payload))

        flags = 0
        if is_first: flags |= 0x01
        if is_last:  flags |= 0x02

        header = bytes([0xAA, 0x11, seq, flags, service_hi, service_lo])
        
        if is_first:
            header += bytes([total_len & 0xFF, (total_len >> 8) & 0xFF])

        packets.append(add_crc(header + chunk))
        offset += chunk_len

    return packets

def print_hex(name, packets):
    print(f"{name}:")
    for p in packets:
        print(p.hex())
    print()

msg_id = 8

# Sync trigger
payload = bytes([0x08, 0x0E, 0x10]) + encode_varint(msg_id) + bytes([0x6A, 0x00])
pkts = build_packets(25, 0x80, 0x00, payload)
print_hex("Sync Trigger", pkts)
msg_id += 1

# Route Switch
route_pkt = build_packets(26, 0x09, 0x20,
    bytes.fromhex("080110") + encode_varint(msg_id) +
    bytes.fromhex("1a1a52180a060800100018000a060800100118000a06080010021800"))
print_hex("Route Switch", route_pkt)

