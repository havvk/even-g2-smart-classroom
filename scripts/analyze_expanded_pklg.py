#!/usr/bin/env python3
import pickle
import os

filepath = "tests/对话模式_有AI提示_有展开提示操作.pklg"
print(f"File size: {os.path.getsize(filepath)} bytes")

with open(filepath, "rb") as f:
    raw_data = f.read()

# 尝试用 pickle 解码
packets = None
try:
    obj = pickle.loads(raw_data)
    print(f"Pickle loaded successfully! Object type: {type(obj)}")
    if isinstance(obj, list):
        packets = obj
        print(f"Total packets in list: {len(packets)}")
except Exception as e:
    print(f"Pickle load error: {e}")

if packets:
    print("\n--- 分析 Pickle 内部数据包 ---")
    for i, p in enumerate(packets):
        # 看看 p 是 dict 还是 tuple 还是 object
        # 打印属性
        if i < 20:
            if isinstance(p, dict):
                print(f"Pkt #{i+1}: keys={list(p.keys())}")
            else:
                print(f"Pkt #{i+1}: {repr(p)[:120]}")
else:
    print("\n--- 二进制直接检索 0xAA 0x21 ---")
    pos = 0
    idx_count = 0
    while True:
        idx = raw_data.find(b"\xAA\x21", pos)
        if idx == -1: break
        pos = idx + 2
        if idx + 8 <= len(raw_data):
            seq = raw_data[idx+2]
            plen = raw_data[idx+3]
            tot = raw_data[idx+4]
            ser = raw_data[idx+5]
            shi = raw_data[idx+6]
            slo = raw_data[idx+7]
            payload = raw_data[idx+8 : idx+8+plen-2]
            idx_count += 1
            print(f"Pkt #{idx_count:03d} at 0x{idx:X}: svc={shi:02X}-{slo:02X} seq=0x{seq:02X} tot={tot}/{ser} plen={plen} payload[:16]={payload[:16].hex()}")
