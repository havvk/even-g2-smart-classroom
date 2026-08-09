#!/usr/bin/env python3
"""
解析 multiprompts.pklg 中官方 APP 的 Content Page 下发情况。
目标：确认官方 APP 推送 2 次文本时，每次下发了多少页 (Page 0 ~ Page N)。

pklg 格式：每条记录以 4-byte 长度 + 4-byte 时间戳 + 1-byte 类型 开头，
然后是变长的 HCI/ATT 数据。我们在数据流中搜索 G2 协议帧 (AA 21/12 ...)。
"""
import struct
import sys
from collections import defaultdict

def find_g2_frames(raw_data):
    """在整个二进制数据中搜索所有 G2 协议帧 (以 AA 开头)"""
    frames = []
    i = 0
    while i < len(raw_data) - 10:
        # G2 帧以 AA 开头
        if raw_data[i] == 0xAA:
            frame_type = raw_data[i+1]
            # 0x21 = Phone->Glass Command, 0x12 = Glass->Phone Response
            if frame_type in (0x21, 0x12, 0x22, 0x11):
                seq = raw_data[i+2]
                plen = raw_data[i+3]
                
                # 合理性检查：长度不能太大
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
                        'direction': 'TX' if frame_type == 0x21 else 'RX',
                        'raw': raw_data[i:i+8+plen]
                    })
                    i += 8 + plen
                    continue
        i += 1
    return frames


def analyze_content_pages(frames):
    """分析 Content Page (Service 0x06-20, Type=3) 的下发情况"""
    
    print("=" * 90)
    print("官方 APP multiprompts.pklg 全帧分析")
    print("=" * 90)
    
    # 先打印所有 TX 帧（Phone -> Glass）的概要
    tx_frames = [f for f in frames if f['direction'] == 'TX']
    rx_frames = [f for f in frames if f['direction'] == 'RX']
    
    print(f"\n总帧数: {len(frames)} (TX: {len(tx_frames)}, RX: {len(rx_frames)})")
    
    # 重组多包帧
    # 对于多包 (pkt_tot > 1)，需要将同一 seq 的子包合并
    # 但对于 Content Page 分析，我们主要关注单包和多包首包中的 page_index
    
    print("\n" + "=" * 90)
    print("所有 TX 帧 (Phone → Glass) 列表:")
    print("=" * 90)
    
    push_sessions = []  # 每次推送的 page 列表
    current_pages = []
    session_start = False
    
    for idx, f in enumerate(tx_frames):
        svc = f"{f['svc_hi']:02X}-{f['svc_lo']:02X}"
        payload_hex = f['payload'].hex()
        
        # 解析 Protobuf type 字段
        type_val = None
        if len(f['payload']) >= 2 and f['payload'][0] == 0x08:
            # Protobuf field 1 (type) varint
            if f['payload'][1] < 0x80:
                type_val = f['payload'][1]
            elif len(f['payload']) >= 3:
                type_val = (f['payload'][1] & 0x7F) | (f['payload'][2] << 7)
        
        # 描述
        desc = ""
        page_idx = None
        
        if svc == "06-20":
            if type_val == 1:
                # 检查是否有 state=4 (退出)
                if b'\x1a\x02\x08\x04' in f['payload']:
                    desc = "⏹️  TeleprompterExit (state=4)"
                    # 标记当前 session 结束
                    if current_pages:
                        push_sessions.append(current_pages[:])
                        current_pages = []
                else:
                    desc = "🟢 TeleprompterInit (type=1)"
                    session_start = True
            elif type_val == 3:
                # Content Page - 提取 page_index
                # Protobuf: 2A [len] 08 [page_idx] 10 [line_count] 1A [data_len] [text...]
                p = f['payload']
                # 找 Tag 5 (0x2A) 内的 field 1 (0x08) = page_index
                tag_pos = p.find(b'\x2a')
                if tag_pos >= 0:
                    # 跳过 tag + length varint
                    inner_start = tag_pos + 1
                    # 读 length varint
                    vlen = p[inner_start]
                    if vlen >= 0x80 and inner_start + 1 < len(p):
                        inner_start += 2  # 2-byte varint length
                        # 实际 length = (vlen & 0x7F) | (p[inner_start-1] << 7)
                    else:
                        inner_start += 1
                    
                    # 现在在 inner 中找 field 1 (0x08 = page_index)
                    if inner_start < len(p) and p[inner_start] == 0x08:
                        page_idx = p[inner_start + 1]
                        if page_idx >= 0x80 and inner_start + 2 < len(p):
                            page_idx = (page_idx & 0x7F) | (p[inner_start + 2] << 7)
                
                if page_idx is not None:
                    # 检查页面内容是否为空（全是 \n）
                    text_start = f['payload'].find(b'\x1a', tag_pos + 2 if tag_pos >= 0 else 0)
                    is_empty = False
                    if text_start >= 0:
                        text_data = f['payload'][text_start+2:]  # 跳过 1A [len]
                        # 如果文本只包含 \n (0x0A)，则为空页
                        is_empty = all(b == 0x0A for b in text_data if b != 0x00) and len(text_data) < 20
                    
                    content_label = "📄 (空白补满页)" if is_empty else "📝 (有内容)"
                    desc = f"📦 Content Page {page_idx} {content_label}"
                    current_pages.append(page_idx)
                else:
                    desc = "📦 Content Page (page_idx 解析失败)"
            elif type_val == 5:
                desc = "🔄 ScrollSync (type=5)"
            elif type_val == 165:
                desc = "🖱️  ScrollPosition (type=165)"
            else:
                desc = f"❓ type={type_val}"
        elif svc == "80-00":
            desc = "⚡ Render Commit (0x80-00)"
        elif svc == "04-20":
            desc = "🖥️  HUD Mount (0x04-20)"
        elif svc == "09-20":
            desc = "🎮 Touchpad Router (0x09-20)"
        elif svc == "01-20":
            desc = "📐 Pipeline Layout (0x01-20)"
        elif svc == "30-20":
            desc = "⚙️  System Mode (0x30-20)"
        elif svc == "07-20":
            desc = "🌐 Dashboard Setup (0x07-20)"
        elif svc == "03-20":
            desc = "📏 Screen Geometry (0x03-20)"
        elif svc == "0C-20":
            desc = "🔌 Task Manager (0x0C-20)"
        elif svc == "0D-20":
            desc = "🔍 Input Device / Probe (0x0D-20)"
        elif svc == "1F-20":
            desc = "👆 Touchpad Interrupt (0x1F-20)"
        elif svc == "10-20":
            desc = "📱 App Mount (0x10-20)"
        else:
            desc = f"Svc {svc}"
        
        multi = f" [{f['pkt_ser']}/{f['pkt_tot']}]" if f['pkt_tot'] > 1 else ""
        print(f"  #{idx+1:3d} Seq={f['seq']:3d} Svc={svc} Len={f['plen']:3d}{multi}  {desc}")
    
    # 处理最后一个 session
    if current_pages:
        push_sessions.append(current_pages[:])
    
    # 也检查 RX 中的 Session Terminated
    print("\n" + "=" * 90)
    print("关键 RX 帧 (Glass → Phone):")
    print("=" * 90)
    for idx, f in enumerate(rx_frames):
        svc = f"{f['svc_hi']:02X}-{f['svc_lo']:02X}"
        if svc in ("0D-01", "0D-00", "06-00", "06-01"):
            desc = ""
            if svc == "0D-01":
                desc = "🛑 Session Terminated"
            elif svc == "0D-00":
                desc = "✅ Probe ACK"
            elif svc == "06-00":
                desc = "✅ ACK"
            elif svc == "06-01":
                desc = "📺 Telemetry/Gesture"
            print(f"  #{idx+1:3d} Seq={f['seq']:3d} Svc={svc} Len={f['plen']:3d}  {desc}  | {f['raw'].hex()}")
    
    # 汇总每次推送
    print("\n" + "=" * 90)
    print("📊 每次推送的 Content Page 汇总:")
    print("=" * 90)
    for i, pages in enumerate(push_sessions):
        print(f"\n  Push #{i+1}: 共下发 {len(pages)} 页")
        print(f"    Page 索引: {pages}")
        print(f"    范围: Page {min(pages)} ~ Page {max(pages)}")
        is_14 = len(pages) >= 14
        print(f"    是否补满 14 页: {'✅ 是' if is_14 else '❌ 否 (仅 ' + str(len(pages)) + ' 页)'}")


if __name__ == "__main__":
    filename = sys.argv[1] if len(sys.argv) > 1 else "tests/multiprompts.pklg"
    
    with open(filename, "rb") as f:
        raw_data = f.read()
    
    print(f"文件: {filename} ({len(raw_data)} bytes)")
    
    frames = find_g2_frames(raw_data)
    analyze_content_pages(frames)
