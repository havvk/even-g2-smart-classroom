#!/usr/bin/env python3
"""
专门分析 multiprompts.pklg 中 Push #1 与 Push #2 转换过渡区 (Frame 20 ~ 35) 的所有底帧与眼镜反馈。
"""
import sys

def parse_gap(filename):
    with open(filename, "rb") as f:
        raw_data = f.read()
    
    # 提取所有 G2 协议帧 (TX 和 RX)
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
                        'offset': i,
                        'direction': 'Phone -> Glass (TX)' if ftype in (0x21, 0x22) else 'Glass -> Phone (RX)',
                        'seq': seq,
                        'plen': plen,
                        'tot': pkt_tot,
                        'ser': pkt_ser,
                        'svc': f"{svc_hi:02X}-{svc_lo:02X}",
                        'payload': payload,
                        'raw': raw_data[i:i+8+plen+2]
                    })
                    i += 8 + plen
                    continue
        i += 1
    
    print("=" * 100)
    print("🔍 multiprompts.pklg 中 Push #1 与 Push #2 之间的所有交互 (Frame 20 ~ 35 逐帧拆解):")
    print("=" * 100)
    
    for idx, f in enumerate(frames[19:36]):
        real_idx = idx + 20
        svc = f['svc']
        p_hex = f['payload'].hex()
        
        desc = ""
        if svc == "06-20":
            if b'\x1a\x02\x08\x04' in f['payload']:
                desc = "🛑 TeleprompterExit (state=4) 手机请求主动中断/退出 Session!"
            elif f['payload'][:2] == b'\x08\x01':
                desc = "🟢 TeleprompterInit (type=1) 手机启动新 Session!"
            elif f['payload'][:2] == b'\x08\x03':
                desc = "📄 Content Page (type=3)"
            elif f['payload'][:2] == b'\x08\xff':
                desc = "🏁 TeleprompterComplete (type=255)"
            elif b'\xa5\x01' in f['payload']:
                desc = "🔄 ScrollSync (type=165)"
            else:
                desc = "Service 06-20"
        elif svc == "0D-01":
            if b'\x08\x01\x1a\x00' in f['payload']:
                desc = "✅ Glass ACK/Confirm Status (0x0D-01): 眼镜确认 Session 已销毁/回到 Ready 状态!"
            elif b'\x08\x01\x1a\x02\x08\x06' in f['payload']:
                desc = "⚠️ Error 0x06 (Session Terminated)"
            else:
                desc = "Session Status (0x0D-01)"
        elif svc == "06-00":
            desc = "✅ ACK (0x06-00)"
        elif svc == "80-00":
            desc = "⚡ Render Commit (0x80-00)"
        else:
            desc = f"Service {svc}"
        
        print(f"Frame #{real_idx:02d} | {f['direction']:22s} | Seq={f['seq']:3d} | Svc={svc} | {desc}")
        print(f"          └─ Raw Hex: {f['raw'].hex()}")
        print("-" * 100)

parse_gap("tests/multiprompts.pklg")
