#!/usr/bin/env python3
import struct

with open("tests/对话模式_有AI提示_有展开提示操作.pklg", "rb") as f:
    data = f.read()

# 重点解构 #051 到 #077
# 我们逐个解码这些帧的 Protobuf
frames = []
i = 0
while i < len(data) - 8:
    if data[i] == 0xAA:
        ftype = data[i+1]
        if ftype in (0x21, 0x12, 0x22, 0x11):
            seq = data[i+2]
            plen = data[i+3]
            if 0 < plen < 250 and i + 8 + plen <= len(data):
                tot = data[i+4]
                ser = data[i+5]
                shi = data[i+6]
                slo = data[i+7]
                payload = data[i+8 : i+8+plen-2]
                direction = "TX (Phone->G2)" if ftype == 0x21 else "RX (G2->Phone)"
                if (shi, slo) in [(0x0B, 0x20), (0x0B, 0x01), (0x0B, 0x00), (0x0D, 0x01)]:
                    frames.append({
                        "offset": i,
                        "ftype": ftype,
                        "dir": direction,
                        "seq": seq,
                        "shi": shi,
                        "slo": slo,
                        "payload": payload
                    })
                i += 8 + plen
                continue
    i += 1

print(f"Total 0x0B frames: {len(frames)}")

def decode_proto(p):
    res = []
    idx = 0
    while idx < len(p):
        sb = p[idx]
        idx += 1
        tag = sb >> 3
        wire = sb & 0x07
        if wire == 0:
            v = 0
            shift = 0
            while True:
                b = p[idx]
                idx += 1
                v |= (b & 0x7F) << shift
                if not (b & 0x80): break
                shift += 7
            res.append(f"Tag {tag} (int) = {v}")
        elif wire == 2:
            l = 0
            shift = 0
            while True:
                b = p[idx]
                idx += 1
                l |= (b & 0x7F) << shift
                if not (b & 0x80): break
                shift += 7
            content = p[idx : idx + l]
            idx += l
            try:
                txt = content.decode("utf-8")
                res.append(f"Tag {tag} (str[{l}]) = {txt}")
            except:
                res.append(f"Tag {tag} (bytes[{l}]) = {content.hex()}")
        else:
            res.append(f"Tag {tag} (wire {wire})")
    return ", ".join(res)

for f in frames:
    shi, slo = f["shi"], f["slo"]
    svc = f"0x{shi:02X}-{slo:02X}"
    seq = f"0x{f['seq']:02X}"
    p = f["payload"]
    proto_info = decode_proto(p)
    print(f"[{f['dir']}] {svc} seq={seq} (len={len(p)}): {proto_info}")
