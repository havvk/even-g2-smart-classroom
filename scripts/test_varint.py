def encode_varint(value: int) -> bytes:
    out = []
    while value >= 0x80:
        out.append((value & 0x7F) | 0x80)
        value >>= 7
    out.append(value)
    return bytes(out)
v = encode_varint(1785501864)
print(f"Python: {v.hex()}")
