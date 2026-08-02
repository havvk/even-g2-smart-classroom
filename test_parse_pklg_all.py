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
                
                payload = data[i+8:i+8+plen]
                print(f"Packet: AA {data[i+1]:02x} seq={seq:02x} {shi:02x}-{slo:02x} plen={plen} ({idx}/{tot}) payload={payload.hex()}")
                
                i += 8 + plen
                continue
        i += 1

parse_pklg("tests/bt2.pklg")
