#!/usr/bin/env python3
"""
逐字节对比官方 APP (multiprompts.pklg) vs 我方代码 (session.log) 的发送序列。
排除文本内容，聚焦协议结构差异：Init 参数、Page 元数据、Commit、ScrollSync 等。
"""
import re
import sys

def find_g2_frames(raw_data):
    """在二进制数据中搜索所有 G2 协议帧"""
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
                        'direction': 'TX' if frame_type == 0x21 else 'RX',
                        'raw': raw_data[i:i+8+plen+2]  # +2 for CRC
                    })
                    i += 8 + plen
                    continue
        i += 1
    return frames


def decode_varint(data, offset):
    """解码 Protobuf varint，返回 (value, bytes_consumed)"""
    result = 0
    shift = 0
    consumed = 0
    while offset < len(data):
        b = data[offset]
        result |= (b & 0x7F) << shift
        shift += 7
        offset += 1
        consumed += 1
        if not (b & 0x80):
            break
    return result, consumed


def decode_protobuf_fields(data):
    """简单解码 Protobuf 字段，返回 [(field_number, wire_type, value/raw)] 列表"""
    fields = []
    i = 0
    while i < len(data):
        if i >= len(data):
            break
        tag_byte = data[i]
        wire_type = tag_byte & 0x07
        field_num = tag_byte >> 3
        
        # 处理多字节 tag
        if tag_byte & 0x80:
            tag_val, consumed = decode_varint(data, i)
            wire_type = tag_val & 0x07
            field_num = tag_val >> 3
            i += consumed
        else:
            i += 1
        
        if wire_type == 0:  # Varint
            val, consumed = decode_varint(data, i)
            fields.append((field_num, 'varint', val))
            i += consumed
        elif wire_type == 2:  # Length-delimited
            length, consumed = decode_varint(data, i)
            i += consumed
            if i + length <= len(data):
                raw = data[i:i+length]
                fields.append((field_num, 'bytes', raw))
                i += length
            else:
                fields.append((field_num, 'bytes', data[i:]))
                break
        elif wire_type == 5:  # 32-bit fixed
            if i + 4 <= len(data):
                fields.append((field_num, 'fixed32', data[i:i+4]))
                i += 4
            else:
                break
        elif wire_type == 1:  # 64-bit fixed
            if i + 8 <= len(data):
                fields.append((field_num, 'fixed64', data[i:i+8]))
                i += 8
            else:
                break
        else:
            # 未知 wire type，停止
            fields.append((field_num, f'wire{wire_type}', data[i:]))
            break
    return fields


def reassemble_multipacket(frames):
    """重组多包帧"""
    result = []
    i = 0
    while i < len(frames):
        f = frames[i]
        if f['pkt_tot'] > 1 and f['pkt_ser'] == 1:
            # 收集所有子包
            combined_payload = bytearray(f['payload'])
            j = i + 1
            while j < len(frames) and frames[j]['seq'] == f['seq'] and frames[j]['pkt_ser'] > 1:
                combined_payload.extend(frames[j]['payload'])
                j += 1
            result.append({
                **f,
                'payload': bytes(combined_payload),
                'plen': len(combined_payload),
                'pkt_tot': 1,
                'pkt_ser': 1,
                'reassembled': True,
                'original_parts': j - i
            })
            i = j
        else:
            result.append({**f, 'reassembled': False, 'original_parts': 1})
            i += 1
    return result


def analyze_teleprompter_init(payload):
    """深度解析 TeleprompterInit (type=1) 的所有字段"""
    fields = decode_protobuf_fields(payload)
    result = {}
    for fnum, ftype, fval in fields:
        if ftype == 'varint':
            result[f'field_{fnum}'] = fval
        elif ftype == 'bytes':
            # 递归解析嵌套消息
            sub_fields = decode_protobuf_fields(fval)
            sub_result = {}
            for sfnum, sftype, sfval in sub_fields:
                if sftype == 'varint':
                    sub_result[f'field_{sfnum}'] = sfval
                elif sftype == 'bytes':
                    sub_sub = decode_protobuf_fields(sfval)
                    sub_result[f'field_{sfnum}'] = [(sf, st, sv if st != 'bytes' else sv.hex()) for sf, st, sv in sub_sub]
            result[f'field_{fnum}'] = sub_result
    return result


def analyze_content_page(payload):
    """深度解析 Content Page (type=3) 的元数据字段"""
    fields = decode_protobuf_fields(payload)
    result = {}
    for fnum, ftype, fval in fields:
        if ftype == 'varint':
            result[f'field_{fnum}'] = fval
        elif ftype == 'bytes':
            if fnum == 5:  # Tag 5 (0x2A) = PageContent
                sub_fields = decode_protobuf_fields(fval)
                page_meta = {}
                for sfnum, sftype, sfval in sub_fields:
                    if sftype == 'varint':
                        page_meta[f'field_{sfnum}'] = sfval
                    elif sftype == 'bytes':
                        if sfnum == 3:  # field 3 = text_data
                            text = sfval.decode('utf-8', errors='replace')
                            page_meta['text_preview'] = text[:60] + '...' if len(text) > 60 else text
                            page_meta['text_length'] = len(sfval)
                            page_meta['line_count_actual'] = text.count('\n') + 1
                        else:
                            page_meta[f'field_{sfnum}_hex'] = sfval.hex()
                result['page_content'] = page_meta
            else:
                result[f'field_{fnum}'] = fval.hex() if len(fval) < 32 else f'{fval[:16].hex()}...({len(fval)}B)'
    return result


def analyze_scroll_sync(payload):
    """解析 ScrollSync / ScrollPosition 帧"""
    fields = decode_protobuf_fields(payload)
    result = {}
    for fnum, ftype, fval in fields:
        if ftype == 'varint':
            result[f'field_{fnum}'] = fval
        elif ftype == 'bytes':
            sub = decode_protobuf_fields(fval)
            result[f'field_{fnum}'] = {f'f{sf}': sv for sf, st, sv in sub if st == 'varint'}
    return result


def format_field_comparison(label, official, ours):
    """格式化对比输出"""
    if official == ours:
        return f"  {label}: {official} ✅ 一致"
    else:
        return f"  {label}: 官方={official}  我方={ours}  ⚠️ 不同!"


# ==================== 解析官方 APP 抓包 ====================
print("=" * 100)
print("Step 1: 解析官方 APP (multiprompts.pklg) Push #1 完整序列")
print("=" * 100)

with open("tests/multiprompts.pklg", "rb") as f:
    pklg_data = f.read()

all_frames = find_g2_frames(pklg_data)
tx_frames = [f for f in all_frames if f['direction'] == 'TX']
tx_reassembled = reassemble_multipacket(tx_frames)

# 提取 Push #1 的帧 (从 TeleprompterInit 到 TeleprompterExit)
official_push1 = []
in_push1 = False
for f in tx_reassembled:
    svc = f"{f['svc_hi']:02X}-{f['svc_lo']:02X}"
    if svc == "06-20":
        fields = decode_protobuf_fields(f['payload'])
        type_val = None
        for fnum, ftype, fval in fields:
            if fnum == 1 and ftype == 'varint':
                type_val = fval
                break
        if type_val == 1:
            # 检查 state=4
            if b'\x1a\x02\x08\x04' in f['payload']:
                official_push1.append(('EXIT', f, svc))
                break
            else:
                in_push1 = True
                official_push1.append(('INIT', f, svc))
                continue
    if in_push1:
        official_push1.append(('PKT', f, svc))

print(f"\n官方 Push #1 共 {len(official_push1)} 包 (重组后):\n")

for i, (ptype, f, svc) in enumerate(official_push1):
    parts_info = f" (原{f['original_parts']}子包重组)" if f.get('reassembled') and f['original_parts'] > 1 else ""
    
    if ptype == 'INIT':
        print(f"  [{i+1}] Svc={svc} INIT{parts_info}")
        init_data = analyze_teleprompter_init(f['payload'])
        print(f"      Protobuf 字段: {init_data}")
        print(f"      Raw payload: {f['payload'].hex()}")
        official_init = init_data
    elif svc == "06-20":
        fields = decode_protobuf_fields(f['payload'])
        type_val = None
        for fnum, ftype, fval in fields:
            if fnum == 1 and ftype == 'varint':
                type_val = fval
                break
        if type_val == 3:
            page_data = analyze_content_page(f['payload'])
            print(f"  [{i+1}] Svc={svc} CONTENT PAGE{parts_info}")
            print(f"      元数据: {page_data}")
            print(f"      Raw payload (前80B): {f['payload'][:80].hex()}")
        elif type_val == 165:
            sync_data = analyze_scroll_sync(f['payload'])
            print(f"  [{i+1}] Svc={svc} SCROLL_SYNC (type=165)")
            print(f"      字段: {sync_data}")
            print(f"      Raw payload: {f['payload'].hex()}")
        elif type_val == 255:
            print(f"  [{i+1}] Svc={svc} TYPE=255 (TeleprompterComplete?)")
            complete_data = decode_protobuf_fields(f['payload'])
            print(f"      Protobuf 字段: {[(fn, ft, fv if ft != 'bytes' else fv.hex()) for fn, ft, fv in complete_data]}")
            print(f"      Raw payload: {f['payload'].hex()}")
        else:
            print(f"  [{i+1}] Svc={svc} type={type_val}")
            print(f"      Raw payload: {f['payload'].hex()}")
    elif svc == "80-00":
        print(f"  [{i+1}] Svc={svc} RENDER COMMIT")
        commit_data = decode_protobuf_fields(f['payload'])
        print(f"      Protobuf 字段: {[(fn, ft, fv if ft != 'bytes' else fv.hex()) for fn, ft, fv in commit_data]}")
        print(f"      Raw payload: {f['payload'].hex()}")
    elif ptype == 'EXIT':
        print(f"  [{i+1}] Svc={svc} EXIT (state=4)")
        print(f"      Raw payload: {f['payload'].hex()}")
    else:
        print(f"  [{i+1}] Svc={svc}{parts_info}")
        print(f"      Raw payload: {f['payload'][:40].hex()}")


# ==================== 解析我方 session.log ====================
print("\n\n" + "=" * 100)
print("Step 2: 解析我方代码 (session.log) Push #1 完整序列")
print("=" * 100)

with open("session.log", "r") as f:
    log_content = f.read()

# 提取所有 TX HEX 帧
tx_pattern = re.compile(r'\[手机下发指令 \(Tx\)\] (.+?) \| HEX: \[([A-F0-9 ]+)\]')
our_tx = []
for match in tx_pattern.finditer(log_content):
    desc = match.group(1)
    hex_str = match.group(2).replace(' ', '')
    raw = bytes.fromhex(hex_str)
    our_tx.append((desc, raw))

# 提取 Push #1 (到第一个 state=4 之前)
our_push1 = []
for desc, raw in our_tx:
    if 'state=4' in desc or '退出提词器' in desc:
        break
    our_push1.append((desc, raw))

print(f"\n我方 Push #1 共 {len(our_tx)} 条 TX 记录 (取 Push #1 前 {len(our_push1)} 条):\n")

for i, (desc, raw) in enumerate(our_push1):
    if len(raw) < 8:
        print(f"  [{i+1}] {desc}")
        print(f"      Raw: {raw.hex()}")
        continue
    
    svc_hi = raw[6]
    svc_lo = raw[7]
    svc = f"{svc_hi:02X}-{svc_lo:02X}"
    
    # 重组多包
    pkt_tot = raw[4]
    pkt_ser = raw[5]
    payload = raw[8:]
    
    if pkt_tot > 1:
        print(f"  [{i+1}] Svc={svc} [{pkt_ser}/{pkt_tot}] {desc}")
        if pkt_ser == 1:
            # 找到同 seq 的后续子包（在我方日志中是分开的行）
            pass
        print(f"      Raw payload (前80B): {payload[:80].hex()}")
        continue
    
    if svc == "06-20":
        fields = decode_protobuf_fields(payload)
        type_val = None
        for fnum, ftype, fval in fields:
            if fnum == 1 and ftype == 'varint':
                type_val = fval
                break
        
        if type_val == 1 and b'\x1a\x02\x08\x04' not in payload:
            print(f"  [{i+1}] Svc={svc} INIT  {desc}")
            init_data = analyze_teleprompter_init(payload)
            print(f"      Protobuf 字段: {init_data}")
            print(f"      Raw payload: {payload.hex()}")
        elif type_val == 3:
            page_data = analyze_content_page(payload)
            print(f"  [{i+1}] Svc={svc} CONTENT PAGE  {desc}")
            print(f"      元数据: {page_data}")
            # 只打印前40字节避免太长
            print(f"      Raw payload (前40B): {payload[:40].hex()}")
        elif type_val == 165:
            sync_data = analyze_scroll_sync(payload)
            print(f"  [{i+1}] Svc={svc} SCROLL_SYNC  {desc}")
            print(f"      字段: {sync_data}")
            print(f"      Raw payload: {payload.hex()}")
        else:
            print(f"  [{i+1}] Svc={svc} type={type_val}  {desc}")
            print(f"      Raw payload: {payload[:40].hex()}")
    elif svc == "80-00":
        print(f"  [{i+1}] Svc={svc} RENDER COMMIT  {desc}")
        commit_data = decode_protobuf_fields(payload)
        print(f"      Protobuf 字段: {[(fn, ft, fv if ft != 'bytes' else fv.hex()) for fn, ft, fv in commit_data]}")
        print(f"      Raw payload: {payload.hex()}")
    elif svc == "04-20":
        print(f"  [{i+1}] Svc={svc} HUD MOUNT  {desc}")
        print(f"      Raw payload: {payload.hex()}")
    elif svc == "09-20":
        print(f"  [{i+1}] Svc={svc} TOUCHPAD ROUTER  {desc}")
        print(f"      Raw payload: {payload.hex()}")
    elif svc == "01-20":
        print(f"  [{i+1}] Svc={svc} PIPELINE LAYOUT  {desc}")
        print(f"      Raw payload: {payload.hex()}")
    else:
        print(f"  [{i+1}] Svc={svc}  {desc}")
        print(f"      Raw payload: {payload[:40].hex()}")


# ==================== 关键差异汇总 ====================
print("\n\n" + "=" * 100)
print("Step 3: 🔍 关键差异汇总 (排除文本内容)")
print("=" * 100)

print("""
对比维度:
  1. 发包序列结构 (Init → Pages → HUD → Commit → Sync)
  2. TeleprompterInit 参数 (total_pages, total_lines 等)
  3. Content Page 元数据 (page_index, line_count)
  4. Render Commit 之前/之后的辅助帧
  5. TeleprompterComplete (type=255) 帧
""")
