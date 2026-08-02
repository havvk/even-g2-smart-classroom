import struct
import sys

def parse_pklg(filename):
    with open(filename, "rb") as f:
        data = f.read()

    i = 0
    while i < len(data) - 8:
        if data[i] == 0xAA and data[i+1] in (0x11, 0x21, 0x22):
            if data[i+1] == 0x21 or data[i+1] == 0x22:
                seq = data[i+2]
                plen = data[i+3]
                tot = data[i+4]
                idx = data[i+5]
                shi = data[i+6]
                slo = data[i+7]
                
                # Check if it's 0x06 0x20 (Teleprompter Service)
                if shi == 0x06 and slo == 0x20:
                    payload = data[i+8:i+8+plen]
                    print(f"Packet: seq={seq} plen={plen} ({tot}/{idx}) 06-20 payload={payload.hex()}")
                elif shi == 0x09 and slo == 0x20:
                    payload = data[i+8:i+8+plen]
                    print(f"Packet: seq={seq} plen={plen} ({tot}/{idx}) 09-20 payload={payload.hex()}")
                
                i += 8 + plen
                continue
        i += 1

parse_pklg("tests/bt2.pklg")
