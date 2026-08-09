#!/usr/bin/env python3
"""
无盲区提取官方 3 个抓包中所有推送的 Content Page 详细信息。
针对 multiprompts.pklg、bt3.pklg、bt.pklg 中的每一个 Type=3 包输出详细解包数据。
"""
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
                        'frame_type': ftype,
                        'seq': seq,
                        'plen': plen,
                        'pkt_tot': pkt_tot,
                        'pkt_ser': pkt_ser,
                        'svc_hi': svc_hi,
                        'svc_lo': svc_lo,
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
        if f['pkt_tot'] > 1 and f['pkt_ser'] == 1:
            combined = bytearray(f['payload'])
            j = i + 1
            while j < len(tx_frames) and tx_frames[j]['seq'] == f['seq'] and tx_frames[j]['pkt_ser'] > 1:
                combined.extend(tx_frames[j]['payload'])
                j += 1
            result.append({**f, 'payload': bytes(combined)})
            i = j
        else:
            result.append({**f})
            i += 1
    return result

def decode_protobuf(data):
    fields = []
    i = 0
    while i < len(data):
        if i >= len(data): break
        tag = data[i]
        wire = tag & 0x07
        fnum = tag >> 3
        i += 1
        if wire == 0:
            val = 0
            shift = 0
            while i < len(data):
                b = data[i]
                val |= (b & 0x7F) << shift
                i += 1
                shift += 7
                if not (b & 0x80): break
            fields.append((fnum, 'varint', val))
        elif wire == 2:
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
            break
    return fields

def verify_file(filename, file_label):
    print("=" * 100)
    print(f"📊 【{file_label}】 抓包分析: {filename}")
    print("=" * 100)
    
    with open(filename, "rb") as f:
        raw_data = f.read()
    
    frames = find_g2_frames(raw_data)
    tx_frames = reassemble_tx(frames)
    
    push_count = 0
    page_in_current_push = []
    
    for f in tx_frames:
        svc = f"{f['svc_hi']:02X}-{f['svc_lo']:02X}"
        if svc == "06-20":
            pb = decode_protobuf(f['payload'])
            type_val = pb[0][2] if pb and pb[0][0] == 1 else None
            
            if type_val == 1 and b'\x1a\x02\x08\x04' not in f['payload']:
                # TeleprompterInit: 新的推送开始
                if page_in_current_push:
                    # 打印上一轮推送的总结
                    print_push_summary(push_count, page_in_current_push)
                    page_in_current_push = []
                push_count += 1
                print(f"\n--- 🚀 推送 #{push_count} 开始 (收到 TeleprompterInit type=1) ---")
            
            elif type_val == 3:
                # Content Page
                for fn, ft, fv in pb:
                    if fn == 5 and ft == 'bytes':
                        inner_pb = decode_protobuf(fv)
                        pidx = lcnt = None
                        text_str = ""
                        for ifn, ift, ifv in inner_pb:
                            if ifn == 1 and ift == 'varint': pidx = ifv
                            if ifn == 2 and ift == 'varint': lcnt = ifv
                            if ifn == 3 and ift == 'bytes': text_str = ifv.decode('utf-8', errors='ignore')
                        page_in_current_push.append((pidx, lcnt, text_str))
                        print(f"  📄 Content Page: page_index={pidx}, line_count={lcnt}, text_bytes={len(text_str.encode('utf-8'))}B")
                        preview = text_str.replace('\n', '\\n')
                        if len(preview) > 50: preview = preview[:50] + "..."
                        print(f"      文本内容预览: \"{preview}\"")

    if page_in_current_push:
        print_push_summary(push_count, page_in_current_push)

def print_push_summary(push_num, pages):
    print(f"\n📌 【推送 #{push_num} 汇总】:")
    print(f"   - 官方 APP 实际发送的总页数: {len(pages)} 页")
    print(f"   - Page 索引列表: {[p[0] for p in pages]}")
    print(f"   - 是否补满到 14 页: {'❌ 没有补满 (仅 ' + str(len(pages)) + ' 页)' if len(pages) < 14 else '✅ 达到了 14 页'}")

if __name__ == "__main__":
    verify_file("tests/multiprompts.pklg", "multiprompts.pklg (2次连续推送)")
    print("\n\n")
    verify_file("tests/bt3.pklg", "bt3.pklg (11页长文推送)")
    print("\n\n")
    verify_file("tests/bt.pklg", "bt.pklg (4页短文推送)")
