#!/usr/bin/env python3
"""
完整还原 bt3.pklg (官方 11 页冷启动) 和 bt.pklg (官方 4 页冷启动) 的每一个 TX 帧序列。
精准对比官方冷启动时的完整协议链路。
"""
import sys

def find_g2_frames(raw_data):
    frames = []
    i = 0
    while i < len(raw_data) - 10:
        if raw_data[i] == 0xAA:
            frame_type = raw_data[i+1]
            if frame_type in (0x21, 0x12, 0x22, 0x11):
                seq = raw_data[i+2]
                plen = raw_data[i+3]
                if plen > 0 and plen < 250 and i + 8 + plen <= len(raw_data):
                    pkt_tot = raw_data[i+4]
                    pkt_ser = raw_data[i+5]
                    svc_hi = raw_data[i+6]
                    svc_lo = raw_data[i+7]
                    payload = raw_data[i+8:i+8+plen]
                    frames.append({
                        'frame_type': frame_type,
                        'seq': seq,
                        'plen': plen,
                        'pkt_tot': pkt_tot,
                        'pkt_ser': pkt_ser,
                        'svc_hi': svc_hi,
                        'svc_lo': svc_lo,
                        'payload': payload,
                        'direction': 'TX' if frame_type == 0x21 else 'RX',
                        'raw': raw_data[i:i+8+plen+2]
                    })
                    i += 8 + plen
                    continue
        i += 1
    return frames

def reassemble_tx(frames):
    tx_frames = [f for f in frames if f['direction'] == 'TX']
    result = []
    i = 0
    while i < len(tx_frames):
        f = tx_frames[i]
        if f['pkt_tot'] > 1 and f['pkt_ser'] == 1:
            combined = bytearray(f['payload'])
            j = i + 1
            while j < len(tx_frames) and tx_frames[j]['seq'] == f['seq'] and tx_frames[j]['pkt_ser'] > 1:
                combined.extend(tx_frames[j]['payload'])
                j += 1
            result.append({**f, 'payload': bytes(combined), 'reassembled': True, 'parts': j - i})
            i = j
        else:
            result.append({**f, 'reassembled': False, 'parts': 1})
            i += 1
    return result

def dump_file(filename, label):
    print("=" * 90)
    print(f"📄 {label} ({filename}) 官方 TX 全序列")
    print("=" * 90)
    with open(filename, "rb") as f:
        data = f.read()
    frames = find_g2_frames(data)
    tx_list = reassemble_tx(frames)
    
    for idx, f in enumerate(tx_list):
        svc = f"{f['svc_hi']:02X}-{f['svc_lo']:02X}"
        payload_hex = f['payload'].hex()
        
        # 简单判定 Protobuf type
        type_val = f['payload'][1] if len(f['payload']) >= 2 and f['payload'][0] == 0x08 else None
        
        desc = ""
        if svc == "80-20": desc = "Auth (0x80-20)"
        elif svc == "80-00": desc = "Render Commit (0x80-00)"
        elif svc == "07-20": desc = "Setup: Viewport (0x07-20)"
        elif svc == "03-20": desc = "Setup: Canvas (0x03-20)"
        elif svc == "0C-20": desc = "Setup: Display Channel (0x0C-20)"
        elif svc == "0D-20": desc = "Setup: Status Sync (0x0D-20)"
        elif svc == "09-20": desc = "Setup/Router: Touchpad (0x09-20)"
        elif svc == "1F-20": desc = "Setup: Focus State (0x1F-20)"
        elif svc == "01-20": desc = "Layout/Focus (0x01-20)"
        elif svc == "04-20": desc = "HUD Mount (0x04-20)"
        elif svc == "06-20":
            if type_val == 1: desc = "TeleprompterInit (type=1)"
            elif type_val == 3: desc = "Content Page (type=3)"
            elif type_val == 165: desc = "ScrollSync (type=165)"
            elif type_val == 255: desc = "TeleprompterComplete (type=255)"
            elif type_val == 4: desc = "TeleprompterExit (state=4)"
            else: desc = f"Teleprompter (type={type_val})"
        else: desc = f"Svc {svc}"
        
        parts_str = f" [原{f['parts']}子包]" if f['reassembled'] else ""
        print(f"  #{idx+1:02d} Seq={f['seq']:3d} Svc={svc} Len={len(f['payload']):3d}{parts_str:10s} {desc:32s} | Hex: {payload_hex[:40]}...")

dump_file("tests/bt3.pklg", "bt3.pklg (官方 11 页冷启动)")
print("\n")
dump_file("tests/bt.pklg", "bt.pklg (官方 4 页冷启动)")
