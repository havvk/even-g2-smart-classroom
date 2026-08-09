#!/usr/bin/env python3
"""
深度解析 multiprompts.pklg 中官方 APP 的 2 次文本推送全貌。
按时间顺序输出每一包 TX (手机->眼镜) 和 RX (眼镜->手机) 的 Raw Hex 和 Protobuf 解码结构。
"""
import sys

def find_g2_frames_with_meta(raw_data):
    """提取包含文件偏移量的所有 G2 帧"""
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
                        'offset': i,
                        'frame_type': frame_type,
                        'seq': seq,
                        'plen': plen,
                        'pkt_tot': pkt_tot,
                        'pkt_ser': pkt_ser,
                        'svc_hi': svc_hi,
                        'svc_lo': svc_lo,
                        'payload': payload,
                        'direction': 'TX' if frame_type in (0x21, 0x22) else 'RX',
                        'raw': raw_data[i:i+8+plen+2]
                    })
                    i += 8 + plen
                    continue
        i += 1
    return frames

def decode_protobuf(data):
    """Protobuf 字段解析助手"""
    fields = []
    i = 0
    while i < len(data):
        if i >= len(data): break
        tag = data[i]
        wire = tag & 0x07
        fnum = tag >> 3
        i += 1
        
        if wire == 0:  # varint
            val = 0
            shift = 0
            while i < len(data):
                b = data[i]
                val |= (b & 0x7F) << shift
                i += 1
                shift += 7
                if not (b & 0x80): break
            fields.append((fnum, 'varint', val))
        elif wire == 2:  # bytes
            length = 0
            shift = 0
            while i < len(data):
                b = data[i]
                length |= (b & 0x7F) << shift
                i += 1
                shift += 7
                if not (b & 0x80): break
            raw = data[i:i+length]
            fields.append((fnum, 'bytes', raw))
            i += length
        else:
            fields.append((fnum, f'wire_{wire}', data[i:]))
            break
    return fields

def analyze_pklg(filename):
    with open(filename, "rb") as f:
        raw_data = f.read()
    
    frames = find_g2_frames_with_meta(raw_data)
    print("=" * 100)
    print(f"📊 官方抓包 {filename} 全流程分析 (共 {len(frames)} 帧)")
    print("=" * 100)
    
    current_push = 0
    
    for idx, f in enumerate(frames):
        svc = f"{f['svc_hi']:02X}-{f['svc_lo']:02X}"
        dir_icon = "📤 [TX 手机→眼镜]" if f['direction'] == 'TX' else "📥 [RX 眼镜→手机]"
        
        # 判断推送阶段
        if f['direction'] == 'TX' and svc == "06-20":
            payload = f['payload']
            if len(payload) >= 2 and payload[0] == 0x08 and payload[1] == 0x01:
                if b'\x1a\x02\x08\x04' in payload:
                    print(f"\n--- ⏹️ 收到 Exit (state=4) 退出提词 Session ---")
                else:
                    current_push += 1
                    print(f"\n" + "🚀" * 40)
                    print(f"🚀 【官方 APP 第 {current_push} 次文本推送 START】")
                    print("🚀" * 40)
        
        # 详细解码包内容
        desc = ""
        pb_info = ""
        if svc == "06-20":
            pb = decode_protobuf(f['payload'])
            type_val = pb[0][2] if pb and pb[0][0] == 1 else None
            msg_id = pb[1][2] if len(pb) > 1 and pb[1][0] == 2 else None
            
            if type_val == 1:
                if b'\x1a\x02\x08\x04' in f['payload']:
                    desc = "TeleprompterExit (state=4)"
                else:
                    desc = f"TeleprompterInit (type=1, msgId={msg_id})"
                    # 解析内部 Init 参数
                    for fn, ft, fv in pb:
                        if fn == 3 and ft == 'bytes':
                            inner_pb = decode_protobuf(fv)
                            for ifn, ift, ifv in inner_pb:
                                if ifn == 2 and ift == 'bytes':
                                    cfg_pb = decode_protobuf(ifv)
                                    cfg_dict = {cfn: cfv for cfn, cft, cfv in cfg_pb if cft == 'varint'}
                                    pb_info = f"InitConfig -> pages={cfg_dict.get(4)}, lines={cfg_dict.get(5)}, line_h={cfg_dict.get(6)}"
            elif type_val == 3:
                # Content Page
                desc = f"Content Page (type=3, msgId={msg_id})"
                for fn, ft, fv in pb:
                    if fn == 5 and ft == 'bytes':
                        inner_pb = decode_protobuf(fv)
                        pidx = lcnt = None
                        text_str = ""
                        for ifn, ift, ifv in inner_pb:
                            if ifn == 1 and ift == 'varint': pidx = ifv
                            if ifn == 2 and ift == 'varint': lcnt = ifv
                            if ifn == 3 and ift == 'bytes': text_str = ifv.decode('utf-8', errors='ignore')
                        text_preview = text_str.replace('\n', '\\n')[:40]
                        pb_info = f"PageMeta -> page_idx={pidx}, line_count={lcnt}, text='{text_preview}'"
            elif type_val == 165:
                desc = f"ScrollSync (type=165, msgId={msg_id})"
            elif type_val == 255:
                desc = f"TeleprompterComplete (type=255, msgId={msg_id})"
            elif type_val == 4:
                desc = f"TeleprompterState/Exit (type=4)"
            else:
                desc = f"Teleprompter (type={type_val}, msgId={msg_id})"
        elif svc == "80-00":
            desc = "Render Commit (0x80-00)"
        elif svc == "0D-01":
            desc = "Session Status (0x0D-01)"
            if b'\x08\x06' in f['payload']: desc += " [Session Terminated Error 0x06]"
            elif b'\x08\x01' in f['payload']: desc += " [Session ACK/Active]"
        elif svc == "06-00":
            desc = "Teleprompter ACK (0x06-00)"
        elif svc == "06-01":
            desc = "Teleprompter Gesture/Telemetry (0x06-01)"
        else:
            desc = f"Svc {svc}"
        
        sub_info = f"[{f['pkt_ser']}/{f['pkt_tot']}]" if f['pkt_tot'] > 1 else ""
        print(f"  Frame #{idx+1:02d} {dir_icon} Seq={f['seq']:3d} Svc={svc} {sub_info:6s} {desc}")
        if pb_info:
            print(f"            └─ {pb_info}")
        print(f"            └─ Hex: {f['payload'].hex()}")

if __name__ == "__main__":
    analyze_pklg("tests/multiprompts.pklg")
