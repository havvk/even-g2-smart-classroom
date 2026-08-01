def encode_varint(value: int) -> bytes:
    if value < 0:
        value += 1 << 64
    out = []
    while value >= 0x80:
        out.append((value & 0x7F) | 0x80)
        value >>= 7
    out.append(value)
    return bytes(out)

print("Python Varint:", encode_varint(1722495818000).hex())
