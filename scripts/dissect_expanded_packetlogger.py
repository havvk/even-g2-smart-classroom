#!/usr/bin/env python3
"""
Apple PacketLogger (.pklg) 深度剖析工具
针对《对话模式_有AI提示_有展开提示操作.pklg》

功能:
1. 完整解析 PacketLogger 记录头 (Length, Timestamp, RecordType)
2. 区分 Direction: TX (Phone -> Glasses) / RX (Glasses -> Phone)
3. 重点解码 Service 0x0B-20 与任何非 0xAA 报文 (ATT Write / Notify / Touchpad)
4. 抓取“展开提示”操作发生时的时间窗口与双向数据
"""

import struct
import os
import sys

def parse_pklg(filepath):
    if not os.path.exists(filepath):
        print(f"File not found: {filepath}")
        return

    with open(filepath, "rb") as f:
        data = f.read()

    file_len = len(data)
    print(f"Loaded {filepath}: {file_len} bytes")

    pos = 0
    record_idx = 0
    records = []

    while pos < file_len:
        if pos + 13 > file_len:
            break
        # Header: len (4B BE), ts_sec (4B BE), ts_usec (4B BE), type (1B)
        rec_len, ts_sec, ts_usec, rec_type = struct.unpack(">III B", data[pos : pos + 13])
        payload = data[pos + 13 : pos + rec_len]
        
        # rec_type:
        # 0x00: HCI Command (TX)
        # 0x01: HCI Event (RX)
        # 0x02: Sent ACL Data (TX, Phone -> Glasses)
        # 0x03: Received ACL Data (RX, Glasses -> Phone)
        direction = "TX (Phone->G2)" if rec_type in (0x00, 0x02) else ("RX (G2->Phone)" if rec_type in (0x01, 0x03) else f"Type=0x{rec_type:02X}")
        
        records.append({
            "idx": record_idx,
            "sec": ts_sec,
            "usec": ts_usec,
            "type": rec_type,
            "dir": direction,
            "raw": payload
        })
        
        pos += rec_len
        record_idx += 1

    print(f"Total PacketLogger records: {len(records)}")
    if not records:
        return

    base_time = records[0]["sec"] + records[0]["usec"] / 1e6

    # 寻找包含 0x0B-20 Type 5 (AI Prompt) 的关键时间点
    prompt_time = None
    exit_time = None

    for r in records:
        t = (r["sec"] + r["usec"] / 1e6) - base_time
        r["rel_time"] = t
        raw = r["raw"]
        # 检查是否包含 0xAA 0x21
        aa_idx = raw.find(b"\xAA\x21")
        if aa_idx != -1 and aa_idx + 8 <= len(raw):
            seq = raw[aa_idx+2]
            plen = raw[aa_idx+3]
            tot = raw[aa_idx+4]
            ser = raw[aa_idx+5]
            shi = raw[aa_idx+6]
            slo = raw[aa_idx+7]
            p_body = raw[aa_idx+8 : aa_idx+8+plen-2]
            r["g2"] = {
                "seq": seq, "tot": tot, "ser": ser, "shi": shi, "slo": slo, "body": p_body
            }
            if (shi, slo) == (0x0B, 0x20) and len(p_body) > 1 and p_body[0] == 0x08:
                ptype = p_body[1]
                r["g2"]["type"] = ptype
                if ptype == 5:
                    prompt_time = t
                    print(f"\n🌟 [找到 AI 胶囊下发] Time={t:.3f}s Record #{r['idx']} {r['dir']}: seq=0x{seq:02X}")
                elif ptype == 1 and len(p_body) >= 5 and p_body[4] == 0x02: # action=2 exit
                    exit_time = t
                    print(f"🛑 [找到会话退出] Time={t:.3f}s Record #{r['idx']} {r['dir']}: seq=0x{seq:02X}\n")

    print(f"Prompt Time: {prompt_time:.3f}s | Exit Time: {exit_time:.3f}s | Window: {exit_time - prompt_time:.3f}s\n")
    print("=" * 100)
    print(f"{'Time (s)':<10} {'Dir':<16} {'G2 Svc':<10} {'Seq':<6} {'Type':<6} {'Payload / Description'}")
    print("=" * 100)

    # 打印从 prompt_time - 1.0s 到 exit_time + 1.0s 之间的所有报文（包括所有非 0xAA 的 ATT 报文）
    for r in records:
        t = r["rel_time"]
        if prompt_time is not None and (prompt_time - 0.5 <= t <= (exit_time or prompt_time + 30) + 1.0):
            d_str = r["dir"]
            raw = r["raw"]
            if "g2" in r:
                g = r["g2"]
                svc_str = f"0x{g['shi']:02X}-{g['slo']:02X}"
                seq_str = f"0x{g['seq']:02X}"
                type_str = str(g.get("type", "-"))
                desc = g["body"][:30].hex()
                
                # 尝试解析文本
                if g.get("type") == 5:
                    desc = f"[AI PROMPT] len={len(g['body'])} {g['body'][:20].hex()}..."
                elif g.get("type") == 6:
                    # 尝试提取 text
                    sub = g["body"][3:] # 42 len ...
                    if len(sub) > 2 and sub[0] == 0x42:
                        l = sub[1]
                        txt = sub[4 : 4 + sub[3]].decode("utf-8", errors="ignore") if len(sub) > 4 else ""
                        desc = f"[TRANSCRIPT] '{txt}'"
                elif g.get("type") == 255:
                    desc = "[FLUSH SYNC]"
                elif g.get("type") == 1:
                    desc = f"[SESSION CTRL] hex={g['body'].hex()}"

                print(f"{t:9.3f}s  {d_str:<16} {svc_str:<10} {seq_str:<6} {type_str:<6} {desc}")
            else:
                # 原始 ACL / ATT 报文 (可能是手势上报、非 0xAA 数据等)
                # 检查 ATT Opcode
                # 典型的 BLE ACL data: handle (2B), pb/bc (2B), l2cap_len (2B), cid (2B), att_data...
                att_info = ""
                if len(raw) >= 9:
                    att_data = raw[8:] # 跳过 ACL/L2CAP 头部
                    if len(att_data) > 0:
                        att_opcode = att_data[0]
                        att_info = f"[ATT opcode=0x{att_opcode:02X}, len={len(att_data)}] hex={att_data[:20].hex()}"
                print(f"{t:9.3f}s  {d_str:<16} {'NON-G2':<10} {'-':<6} {'-':<6} {att_info if att_info else raw[:20].hex()}")

if __name__ == "__main__":
    filepath = "tests/对话模式_有AI提示_有展开提示操作.pklg"
    if len(sys.argv) > 1:
        filepath = sys.argv[1]
    parse_pklg(filepath)
