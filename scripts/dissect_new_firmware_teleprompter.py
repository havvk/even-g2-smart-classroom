#!/usr/bin/env python3
import sys
import os

def parse_protobuf(data):
    pos = 0
    fields = {}
    while pos < len(data):
        if pos >= len(data): break
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
        elif wire_type == 5: # 32-bit
            pos += 4
        elif wire_type == 1: # 64-bit
            pos += 8
        else:
            break
    return fields

def analyze(file_path):
    print(f"==================================================")
    print(f"正在深度分析: {file_path}")
    print(f"==================================================")
    
    with open(file_path, "rb") as f:
        raw = f.read()

    print(f"文件总大小: {len(raw)} 字节")
    
    multi_buffers = {}
    packets = []
    
    i = 0
    while i < len(raw) - 8:
        if raw[i] == 0xAA and raw[i+1] in (0x21, 0x12):
            ftype = raw[i+1] # 0x21=Tx(Phone->Glasses), 0x12=Rx(Glasses->Phone)
            seq = raw[i+2]
            plen = raw[i+3]
            tot = raw[i+4]
            ser = raw[i+5]
            shi = raw[i+6]
            slo = raw[i+7]
            
            direction = "TX [Phone -> Glass]" if ftype == 0x21 else "RX [Glass -> Phone]"
            svc_name = f"0x{shi:02X}-{slo:02X}"
            
            if i + 8 + plen <= len(raw):
                payload = raw[i+8:i+8+plen]
                
                if tot > 1:
                    key = (ftype, seq, shi, slo)
                    if key not in multi_buffers:
                        multi_buffers[key] = []
                    multi_buffers[key].append(payload)
                    if len(multi_buffers[key]) == tot:
                        full_payload = b"".join(multi_buffers[key])
                        packets.append({
                            'dir': direction,
                            'seq': seq,
                            'svc': (shi, slo),
                            'is_multi': True,
                            'tot': tot,
                            'payload': full_payload
                        })
                else:
                    # 单包带 2 字节 CRC
                    content = payload[:-2] if len(payload) >= 2 else payload
                    packets.append({
                        'dir': direction,
                        'seq': seq,
                        'svc': (shi, slo),
                        'is_multi': False,
                        'tot': 1,
                        'payload': content
                    })
                i += 8 + plen
                continue
        i += 1

    print(f"成功识别并重组出 {len(packets)} 个应用层数据包\n")
    
    # 统计服务分布
    svc_counts = {}
    for p in packets:
        s = f"{p['dir']} Svc 0x{p['svc'][0]:02X}-{p['svc'][1]:02X}"
        svc_counts[s] = svc_counts.get(s, 0) + 1
        
    print("--- 服务信令包分布统计 ---")
    for s, c in sorted(svc_counts.items(), key=lambda x: -x[1]):
        print(f"  {s}: {c} 包")
    print("----------------------------\n")
    
    # 逐包关键解析
    page_count = 0
    for idx, p in enumerate(packets):
        shi, slo = p['svc']
        payload = p['payload']
        direction = p['dir']
        seq = p['seq']
        
        # 1. Teleprompter Svc 0x06-20
        if (shi, slo) == (0x06, 0x20):
            fields = parse_protobuf(payload)
            cmd = fields.get(1)
            msg_id = fields.get(2, 0)
            
            if cmd == 1:
                # Teleprompter Init
                print(f"\n🌟 [Pkt #{idx+1:03d}] {direction} >>> Teleprompter INIT (Cmd=1, MsgId={msg_id})")
                settings_data = fields.get(3, b"")
                settings_fields = parse_protobuf(settings_data)
                display_data = settings_fields.get(2, b"")
                display_fields = parse_protobuf(display_data)
                
                print("  Protobuf Fields in TeleprompterInit.display:")
                for k, v in sorted(display_fields.items()):
                    desc = ""
                    if k == 1: desc = "render_engine"
                    elif k == 4: desc = "display_width"
                    elif k == 5: desc = "content_height"
                    elif k == 6: desc = "line_height"
                    elif k == 7: desc = "viewport_height"
                    elif k == 8: desc = "font_size"
                    elif k == 9: desc = "scroll_mode"
                    elif k == 10: desc = "render_mode"
                    elif k == 11: desc = "ext_flag"
                    print(f"    Field {k:2d} ({desc:15s}) = {v} (0x{v:02X})")
                print(f"  原始 display hex: {display_data.hex()}")
                
            elif cmd == 3:
                # Content Page
                page_data = fields.get(5, b"")
                pfields = parse_protobuf(page_data)
                p_num = pfields.get(1)
                p_lines = pfields.get(2)
                p_text = pfields.get(3, b"").decode('utf-8', errors='ignore')
                page_count += 1
                line_list = p_text.split('\n')
                print(f"\n📄 [Pkt #{idx+1:03d}] {direction} >>> Content Page {p_num} (MsgId={msg_id})")
                print(f"    声明行数 (Field 2): {p_lines}")
                print(f"    实际文本换行数: {len(line_list)} 行, 字节数: {len(p_text.encode('utf-8'))}")
                for l_idx, l in enumerate(line_list[:10]):
                    print(f"      [Line {l_idx}] (字符数 {len(l)}): {l}")
                if len(line_list) > 10:
                    print(f"      ... (还有 {len(line_list)-10} 行)")
                    
            elif cmd == 165:
                # ScrollSync (手机控制提词位置)
                sub = parse_protobuf(fields.get(11, b""))
                f1 = sub.get(1) # page?
                f2 = sub.get(2) # line?
                print(f"📍 [Pkt #{idx+1:03d}] {direction} >>> ScrollSync (Type 165, MsgId={msg_id}): Field 1={f1}, Field 2(Line)={f2}")
                
            elif cmd == 4:
                # Type 4 (状态或变暗)
                sub = parse_protobuf(fields.get(6, b""))
                print(f"💡 [Pkt #{idx+1:03d}] {direction} >>> Type 4 State/Dim (MsgId={msg_id}): {sub}")
                
            elif cmd == 255:
                # Complete
                sub = parse_protobuf(fields.get(13, b""))
                print(f"🏁 [Pkt #{idx+1:03d}] {direction} >>> TeleprompterComplete (Type 255, MsgId={msg_id}): {sub}")
            else:
                print(f"ℹ️ [Pkt #{idx+1:03d}] {direction} >>> 0x06-20 Cmd={cmd} (MsgId={msg_id})")
                
        # 2. Teleprompter Rx Svc 0x06-01 (眼镜遥测/按键/触控板控制位置上报)
        elif (shi, slo) == (0x06, 0x01):
            print(f"👓 👆 [Pkt #{idx+1:03d}] {direction} >>> Svc 0x06-01 眼镜位置/手势上报:")
            print(f"    Hex: {payload.hex()}")
            fields = parse_protobuf(payload)
            print(f"    Protobuf: {fields}")
            if 3 in fields:
                sub3 = parse_protobuf(fields[3])
                print(f"    Field 3 解码: {sub3}")
                
        # 3. Svc 0x0E-20 (Display Config)
        elif (shi, slo) == (0x0E, 0x20):
            print(f"🖥️ [Pkt #{idx+1:03d}] {direction} >>> Svc 0x0E-20 Display Config (Len={len(payload)})")
            print(f"    Hex 前 60 字节: {payload[:60].hex()}...")
            
        # 4. Svc 0x80-00 (Render Commit)
        elif (shi, slo) == (0x80, 0x00):
            print(f"✨ [Pkt #{idx+1:03d}] {direction} >>> Svc 0x80-00 Render Commit (Hex={payload.hex()})")
            
        # 5. Svc 0x01-20 (Layout / Touchpad Listener)
        elif (shi, slo) == (0x01, 0x20):
            print(f"🎛️ [Pkt #{idx+1:03d}] {direction} >>> Svc 0x01-20 Layout/Touchpad Config (Hex={payload.hex()})")

if __name__ == "__main__":
    path = "tests/__pycache__/最新固件下推送提词、改变提词位置.pklg"
    if len(sys.argv) > 1:
        path = sys.argv[1]
    analyze(path)
