#!/usr/bin/env python3
"""
逐包对比官方 bt.pklg (9页冷启动) 与我方 session.log 在按需下发时的所有 TX 帧。
出具 1:1 差异报告。
"""
import re
import sys

def find_g2_frames(raw_data):
    frames = []
    i = 0
    while i < len(raw_data) - 10:
        if raw_data[i] == 0xAA:
            ftype = raw_data[i+1]
            if ftype in (0x21, 0x12, 0x22, 0x11):
                seq = raw_data[i+2]
                plen = raw_data[i+3]
                if plen > 0 and plen < 250 and i + 8 + plen <= len(raw_data):
                    pkt_tot = raw_data[i+4]
                    pkt_ser = raw_data[i+5]
                    svc_hi = raw_data[i+6]
                    svc_lo = raw_data[i+7]
                    payload = raw_data[i+8:i+8+plen]
                    frames.append({
                        'seq': seq,
                        'plen': plen,
                        'tot': pkt_tot,
                        'ser': pkt_ser,
                        'svc': f"{svc_hi:02X}-{svc_lo:02X}",
                        'payload': payload,
                        'direction': 'TX' if ftype in (0x21, 0x22) else 'RX',
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
        if f['tot'] > 1 and f['ser'] == 1:
            combined = bytearray(f['payload'])
            j = i + 1
            while j < len(tx_frames) and tx_frames[j]['seq'] == f['seq'] and tx_frames[j]['ser'] > 1:
                combined.extend(tx_frames[j]['payload'])
                j += 1
            result.append({**f, 'payload': bytes(combined)})
            i = j
        else:
            result.append({**f})
            i += 1
    return result

def parse_session_log_tx(log_path):
    with open(log_path, 'r') as f:
        content = f.read()
    
    tx_pattern = re.compile(r'\[手机下发指令 \(Tx\)\] (.+?) \| HEX: \[([A-F0-9 ]+)\]')
    frames = []
    for match in tx_pattern.finditer(content):
        desc = match.group(1)
        hex_str = match.group(2).replace(' ', '')
        raw = bytes.fromhex(hex_str)
        if len(raw) >= 8 and raw[0] == 0xAA and raw[1] in (0x21, 0x22):
            svc_hi = raw[6]
            svc_lo = raw[7]
            tot = raw[4]
            ser = raw[5]
            payload = raw[8:]
            frames.append({
                'desc': desc,
                'tot': tot,
                'ser': ser,
                'svc': f"{svc_hi:02X}-{svc_lo:02X}",
                'payload': payload
            })
    return frames

def run_diff():
    print("=" * 100)
    print("🔬 官方 bt.pklg (9页冷启动) vs 我方 session.log 发送序列 1:1 对比")
    print("=" * 100)
    
    # 官方 bt.pklg
    with open("tests/bt.pklg", "rb") as f:
        bt_data = f.read()
    official_tx = reassemble_tx(find_g2_frames(bt_data))
    
    # 我方按需下发的记录 (从 session.log 提取最新一次按需推屏)
    log_tx = parse_session_log_tx("session.log")
    
    # 提取按需推屏部分 (含 "V2 按需推屏" 或包数较少的部分)
    our_v2_push = []
    for f in log_tx:
        if "V2" in f['desc'] or "按需" in f['desc']:
            our_v2_push.append(f)
    
    print(f"\n官方 bt.pklg TX 总帧数 (重组后): {len(official_tx)}")
    print("\n--- 官方 bt.pklg 重组后 TX 帧列表 ---")
    for idx, f in enumerate(official_tx):
        svc = f['svc']
        p = f['payload']
        print(f"  #{idx+1:02d} Svc={svc} Len={len(p):3d} | Hex: {p.hex()[:50]}")
    
    print("\n" + "=" * 100)
    print("🔍 核心差异对比分析:")
    print("=" * 100)
    
    official_services = [f['svc'] for f in official_tx]
    print(f"\n1. 官方 TX Service 列表 ({len(official_services)}个):")
    print("   " + " -> ".join(official_services[:20]))
    print("   " + " -> ".join(official_services[20:]))

if __name__ == "__main__":
    run_diff()
