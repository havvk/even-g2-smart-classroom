#!/usr/bin/env python3
import os
import sys

def parse(filepath):
    with open(filepath, "rb") as f:
        data = f.read()

    print(f"Analyzing {filepath}: {len(data)} bytes")
    frames = []
    i = 0
    while i < len(data) - 8:
        if data[i] == 0xAA:
            ftype = data[i+1]
            if ftype in (0x21, 0x12, 0x22, 0x11, 0x01, 0x02):
                seq = data[i+2]
                plen = data[i+3]
                if 0 < plen < 250 and i + 8 + plen <= len(data):
                    tot = data[i+4]
                    ser = data[i+5]
                    shi = data[i+6]
                    slo = data[i+7]
                    payload = data[i+8 : i+8+plen-2]
                    direction = "TX (Phone->G2)" if ftype in (0x21, 0x01) else "RX (G2->Phone)"
                    frames.append({
                        "offset": i,
                        "ftype": ftype,
                        "dir": direction,
                        "seq": seq,
                        "tot": tot,
                        "ser": ser,
                        "shi": shi,
                        "slo": slo,
                        "plen": plen,
                        "payload": payload
                    })
                    i += 8 + plen
                    continue
        i += 1

    print(f"Total G2 Frames found: {len(frames)}")
    print("=" * 100)
    print(f"{'Idx':<4} {'Offset':<9} {'Dir':<15} {'FType':<6} {'Svc':<8} {'Seq':<6} {'Tot/Ser':<8} {'Type':<6} {'Payload Hex / Text'}")
    print("=" * 100)

    for idx, f in enumerate(frames):
        p = f["payload"]
        ptype = p[1] if len(p) > 1 and p[0] == 0x08 else "-"
        
        # 描述文本
        desc = p[:25].hex()
        if (f["shi"], f["slo"]) == (0x0B, 0x20):
            if ptype == 5:
                desc = f"[AI PROMPT] {p[:20].hex()}..."
            elif ptype == 6:
                # 尝试提取 text
                sub = p[3:]
                if len(sub) > 2 and sub[0] == 0x42:
                    txt = sub[4 : 4 + sub[3]].decode("utf-8", errors="ignore") if len(sub) > 4 else ""
                    desc = f"[TRANSCRIPT] '{txt}'"
            elif ptype == 255:
                desc = "[FLUSH SYNC 5A 00]"
            elif ptype == 1:
                desc = f"[SESSION CTRL] action={p[4] if len(p)>4 else '?'}"
        elif (f["shi"], f["slo"]) == (0x0B, 0x00):
            desc = f"[0B-00 ACK] {p.hex()}"
        elif (f["shi"], f["slo"]) == (0x80, 0x00):
            desc = f"[80-00 AUTH/CTRL] {p.hex()}"
        elif (f["shi"], f["slo"]) == (0x80, 0x01):
            desc = f"[80-01 AUTH ACK] {p.hex()}"

        print(f"#{idx+1:03d} 0x{f['offset']:06X} {f['dir']:<15} 0x{f['ftype']:02X}  0x{f['shi']:02X}-{f['slo']:02X} 0x{f['seq']:02X}  {f['tot']}/{f['ser']}    {str(ptype):<6} {desc}")

if __name__ == "__main__":
    parse("tests/对话模式_有AI提示_有展开提示操作.pklg")
