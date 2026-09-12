#!/usr/bin/env python3
import struct
import sys
from collections import defaultdict, Counter

def analyze(filename):
    with open(filename, "rb") as f:
        raw_data = f.read()
    
    print(f"File: {filename}, Total Bytes: {len(raw_data)}")
    
    # 1. 扫描所有 G2 协议帧 (AA 21 / AA 12 / AA 22 / AA 11)
    frames = []
    i = 0
    while i < len(raw_data) - 8:
        if raw_data[i] == 0xAA and raw_data[i+1] in (0x21, 0x12, 0x22, 0x11):
            frame_type = raw_data[i+1]
            seq = raw_data[i+2]
            plen = raw_data[i+3]
            if plen > 0 and plen < 250 and i + 8 + plen <= len(raw_data):
                pkt_tot = raw_data[i+4]
                pkt_ser = raw_data[i+5]
                svc_hi = raw_data[i+6]
                svc_lo = raw_data[i+7]
                payload = raw_data[i+8:i+8+plen]
                direction = "TX (Phone->Glass)" if frame_type in (0x21, 0x22) else "RX (Glass->Phone)"
                
                frames.append({
                    "offset": i,
                    "frame_type": frame_type,
                    "seq": seq,
                    "plen": plen,
                    "pkt_tot": pkt_tot,
                    "pkt_ser": pkt_ser,
                    "svc": f"0x{svc_hi:02X}-{svc_lo:02X}",
                    "svc_hi": svc_hi,
                    "svc_lo": svc_lo,
                    "direction": direction,
                    "payload": payload,
                    "raw": raw_data[i:i+8+plen]
                })
                i += 8 + plen
                continue
        i += 1
    
    print(f"Total G2 Frames Detected: {len(frames)}")
    
    # 统计服务 ID
    svc_counter = Counter(f['svc'] + f" ({f['direction']})" for f in frames)
    print("\n--- Service Distribution ---")
    for svc, count in svc_counter.most_common():
        print(f"  {svc}: {count}")
        
    print("\n--- Detailed Frame Sequence ---")
    for idx, f in enumerate(frames):
        svc = f['svc']
        p_hex = f['payload'].hex()
        desc = ""
        if svc == "0x06-20":
            desc = f"Teleprompter (len={f['plen']})"
        elif svc == "0x80-00":
            desc = "Flush/Commit/Sync"
        elif svc == "0x04-20":
            desc = "HUD/Display Mount"
        elif svc == "0x01-20":
            desc = "Layout/Event Config"
            
        print(f"#{idx:03d} [{f['direction'][:2]}] Seq:{f['seq']:02X} Svc:{svc} Tot/Ser:{f['pkt_tot']}/{f['pkt_ser']} Len:{f['plen']:3d} | {p_hex} | {desc}")

if __name__ == "__main__":
    analyze("tests/AI提词模式亮度变化.pklg")
