#!/usr/bin/env python3
import struct

def parse_protobuf(data):
    pos = 0
    fields = {}
    while pos < len(data):
        if pos >= len(data): break
        # read varint key
        key = 0
        shift = 0
        while pos < len(data):
            b = data[pos]
            pos += 1
            key |= (b & 0x7F) << shift
            if not (b & 0x80):
                break
            shift += 7
        field_num = key >> 3
        wire_type = key & 0x7
        if wire_type == 0: # varint
            val = 0
            shift = 0
            while pos < len(data):
                b = data[pos]
                pos += 1
                val |= (b & 0x7F) << shift
                if not (b & 0x80):
                    break
                shift += 7
            fields[field_num] = val
        elif wire_type == 2: # length delimited
            length = 0
            shift = 0
            while pos < len(data):
                b = data[pos]
                pos += 1
                length |= (b & 0x7F) << shift
                if not (b & 0x80):
                    break
                shift += 7
            sub_data = data[pos:pos+length]
            pos += length
            fields[field_num] = sub_data
        else:
            break
    return fields

def run():
    with open("tests/AI提词模式亮度变化.pklg", "rb") as f:
        raw = f.read()

    # 先收集所有多包
    multi_buffers = {}
    
    # 按照实际顺序解帧
    i = 0
    pages = {}
    events = []
    
    while i < len(raw) - 8:
        if raw[i] == 0xAA and raw[i+1] in (0x21, 0x12):
            ftype = raw[i+1]
            seq = raw[i+2]
            plen = raw[i+3]
            tot = raw[i+4]
            ser = raw[i+5]
            shi = raw[i+6]
            slo = raw[i+7]
            
            if shi == 0x06 and slo == 0x20 and i + 8 + plen <= len(raw):
                payload = raw[i+8:i+8+plen]
                
                if tot > 1:
                    # 多包
                    if seq not in multi_buffers:
                        multi_buffers[seq] = []
                    multi_buffers[seq].append(payload)
                    if len(multi_buffers[seq]) == tot:
                        full_payload = b"".join(multi_buffers[seq])
                        fields = parse_protobuf(full_payload)
                        cmd = fields.get(1)
                        msg_id = fields.get(2, 0)
                        if cmd == 3:
                            page_info = parse_protobuf(fields.get(5, b""))
                            p_num = page_info.get(1)
                            p_text = page_info.get(3, b"").decode('utf-8', errors='ignore')
                            pages[p_num] = p_text
                            events.append(("PAGE", p_num, p_text))
                else:
                    content_payload = payload[:-2]
                    fields = parse_protobuf(content_payload)
                    cmd = fields.get(1)
                    msg_id = fields.get(2, 0)
                    
                    if cmd == 4:
                        sub = parse_protobuf(fields.get(6, b""))
                        events.append(("TYPE4", msg_id, sub))
                    elif cmd == 165:
                        sub = parse_protobuf(fields.get(11, b""))
                        events.append(("TYPE165", msg_id, sub))
                    elif cmd == 255:
                        sub = parse_protobuf(fields.get(13, b""))
                        events.append(("TYPE255", msg_id, sub))
                    elif cmd == 1:
                        events.append(("INIT", msg_id, fields))
                        
                i += 8 + plen
                continue
        i += 1
        
    print(f"=== 已成功还原 {len(pages)} 个讲稿 Page 页面 ===")
    for p_num, text in sorted(pages.items()):
        lines = [line for line in text.split('\n') if line.strip()]
        print(f"\n--- Page {p_num} (共 {len(lines)} 行) ---")
        for line_idx, line in enumerate(lines[:10]):
            print(f"  Line {line_idx:2d} (len={len(line)}): {line}")

    print("\n=== AI 提词变暗/滚动事件时序流 ===")
    for ev in events:
        if ev[0] == "PAGE":
            print(f"\n📄 [载入页面] Page {ev[1]}")
        elif ev[0] == "TYPE165":
            sub = ev[2]
            print(f"  📜 [Type 165 ScrollSync] MsgId:{ev[1]:02X} -> Field1(Page?):{sub.get(1)} Field2(Line?):{sub.get(2)}")
        elif ev[0] == "TYPE255":
            sub = ev[2]
            print(f"  ✨ [Type 255 Commit]     MsgId:{ev[1]:02X} -> Field1:{sub.get(1)} Field2:{sub.get(2)}")
        elif ev[0] == "TYPE4":
            sub = ev[2]
            f1 = sub.get(1)
            f2 = sub.get(2)
            f3 = sub.get(3)
            print(f"  💡 [Type 4 AI-WordDim]   MsgId:{ev[1]:02X} -> Field1:{f1}, Field2(Line):{f2}, Field3(CharOffset):{f3}")

if __name__ == "__main__":
    run()
