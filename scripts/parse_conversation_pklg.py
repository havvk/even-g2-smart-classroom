import sys
import os

SERVICES = {
    (0x80, 0x00): "Auth/Control/Commit",
    (0x80, 0x20): "Auth Data",
    (0x80, 0x01): "Auth Response",
    (0x02, 0x20): "Notification",
    (0x03, 0x20): "Screen Geometry",
    (0x04, 0x20): "Display Wake",
    (0x06, 0x20): "Teleprompter",
    (0x07, 0x20): "Dashboard",
    (0x09, 0x00): "Device Info",
    (0x0B, 0x20): "Conversate/Translate",
    (0x0C, 0x20): "Tasks",
    (0x0D, 0x00): "Config",
    (0x0E, 0x20): "Display Config",
    (0x11, 0x20): "Conversate (Alt)",
    (0x1F, 0x20): "Touchpad Interrupt",
    (0x20, 0x20): "Commit",
    (0x30, 0x20): "Event Trigger",
    (0x64, 0x50): "Audio Stream",
    (0xE0, 0x00): "EvenHub Main",
    (0xE0, 0x01): "EvenHub",
}

def extract_strings(data):
    res = []
    curr = bytearray()
    for b in data:
        if 0x20 <= b <= 0x7E or b >= 0x80:
            curr.append(b)
        else:
            if len(curr) >= 3:
                try:
                    s = curr.decode('utf-8', errors='ignore').strip()
                    if s and any('\u4e00' <= c <= '\u9fa5' for c in s) or len(s) >= 4:
                        res.append(s)
                except:
                    pass
            curr = bytearray()
    if len(curr) >= 3:
        try:
            s = curr.decode('utf-8', errors='ignore').strip()
            if s:
                res.append(s)
        except:
            pass
    return res

def parse_pklg(filename):
    print("=" * 80)
    print(f"Analyzing: {filename}")
    print("=" * 80)
    if not os.path.exists(filename):
        print(f"File not found: {filename}")
        return

    with open(filename, "rb") as f:
        data = f.read()

    print(f"Total file size: {len(data)} bytes")

    # Search for 0xAA packets
    packets = []
    i = 0
    while i < len(data) - 8:
        if data[i] == 0xAA and data[i+1] in (0x11, 0x12, 0x21, 0x22):
            ptype = data[i+1]
            seq = data[i+2]
            plen = data[i+3]
            tot = data[i+4]
            idx = data[i+5]
            shi = data[i+6]
            slo = data[i+7]

            if plen > 0 and i + 8 + plen <= len(data) + 2:
                payload = data[i+8 : i+8+plen]
                packets.append({
                    "offset": i,
                    "type": ptype,
                    "seq": seq,
                    "plen": plen,
                    "tot": tot,
                    "idx": idx,
                    "shi": shi,
                    "slo": slo,
                    "payload": payload
                })
                i += 8 + plen
                continue
        i += 1

    print(f"Found {len(packets)} 0xAA G2 packets")
    
    # Summary of services
    svc_counts = {}
    for p in packets:
        k = (p["shi"], p["slo"])
        svc_counts[k] = svc_counts.get(k, 0) + 1

    print("\n[Service ID Distribution]")
    for (shi, slo), count in sorted(svc_counts.items(), key=lambda x: -x[1]):
        sname = SERVICES.get((shi, slo), "Unknown")
        print(f"  0x{shi:02X}-{slo:02X} ({sname:20s}): {count:4d} packets")

    print("\n[Chronological Packet Stream (Detailed)]")
    for idx, p in enumerate(packets):
        shi, slo = p["shi"], p["slo"]
        sname = SERVICES.get((shi, slo), f"Unknown({shi:02x}-{slo:02x})")
        ptype_str = "CMD(0x21)" if p["type"] == 0x21 else f"0x{p['type']:02X}"
        strings = extract_strings(p["payload"])
        str_info = f" | text: {strings}" if strings else ""
        
        # Highlight important setup / config / conversate / commit packets
        is_highlight = shi in (0x0B, 0x0E, 0x03, 0x80, 0x07, 0x06) or p["type"] in (0x21, 0x22)
        if is_highlight or idx < 15 or idx >= len(packets) - 10:
            print(f"#{idx:03d} [off:{p['offset']:6d}] {ptype_str} seq={p['seq']:02X} svc=0x{shi:02X}-{slo:02X} ({sname}) len={p['plen']:3d} | hex={p['payload'][:32].hex()}{'...' if len(p['payload'])>32 else ''}{str_info}")

if __name__ == "__main__":
    if len(sys.argv) > 1:
        for fn in sys.argv[1:]:
            parse_pklg(fn)
    else:
        parse_pklg("tests/对话模式_无AI提示.pklg")
        parse_pklg("tests/__pycache__/对话模式_无AI提示_有退出对话模式.pklg")
