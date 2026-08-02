def crc16_ccitt_py(data: bytes) -> int:
    crc = 0xFFFF
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) if crc & 0x8000 else (crc << 1)
            crc &= 0xFFFF
    return crc

payload = bytes.fromhex("080110151a1d08011219080010001800203b28c90430b70438a9184000480150095800")
print("Python payload:", payload.hex())
print(f"Python CRC: {crc16_ccitt_py(payload):04x}")
