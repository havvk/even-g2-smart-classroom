import os

def decode_varint(data, offset):
    res = 0
    shift = 0
    while offset < len(data):
        b = data[offset]
        offset += 1
        res |= (b & 0x7F) << shift
        if not (b & 0x80):
            break
        shift += 7
    return res, offset

def decode_proto_fields(data):
    fields = []
    offset = 0
    while offset < len(data):
        try:
            key, offset = decode_varint(data, offset)
        except:
            break
        field_num = key >> 3
        wire_type = key & 0x07

        if wire_type == 0: # varint
            val, offset = decode_varint(data, offset)
            fields.append((field_num, "varint", val))
        elif wire_type == 2: # length-delimited
            length, offset = decode_varint(data, offset)
            val = data[offset:offset+length]
            offset += length
            fields.append((field_num, "bytes", val))
        elif wire_type == 5: # 32-bit
            val = data[offset:offset+4]
            offset += 4
            fields.append((field_num, "fixed32", val))
        elif wire_type == 1: # 64-bit
            val = data[offset:offset+8]
            offset += 8
            fields.append((field_num, "fixed64", val))
        else:
            break
    return fields

def parse_pklg(filename):
    print("=" * 80)
    print(f"Deep Protobuf Decoding: {filename}")
    print("=" * 80)

    with open(filename, "rb") as f:
        data = f.read()

    i = 0
    pkt_idx = 0
    while i < len(data) - 8:
        if data[i] == 0xAA and data[i+1] in (0x11, 0x12, 0x21, 0x22):
            ptype, seq, plen = data[i+1], data[i+2], data[i+3]
            tot, idx = data[i+4], data[i+5]
            shi, slo = data[i+6], data[i+7]

            if plen > 0 and i + 8 + plen <= len(data) + 2:
                payload = data[i+8 : i+8+plen]
                # Filter CRC (last 2 bytes)
                proto_data = payload[:-2] if len(payload) >= 2 else payload
                crc = payload[-2:] if len(payload) >= 2 else b''

                if (shi, slo) in [(0x0B, 0x20), (0x0B, 0x00), (0x0E, 0x20), (0x80, 0x00)]:
                    fields = decode_proto_fields(proto_data)
                    field_desc = []
                    for fnum, ftype, fval in fields:
                        if ftype == "bytes":
                            try:
                                s = fval.decode("utf-8")
                                if s and any(c.isprintable() for c in s):
                                    field_desc.append(f"F{fnum}(str):\"{s}\"")
                                    continue
                            except:
                                pass
                            # Try sub-decode
                            sub_f = decode_proto_fields(fval)
                            if sub_f:
                                sub_str = []
                                for sfnum, sftype, sfval in sub_f:
                                    if sftype == "bytes":
                                        try:
                                            s = sfval.decode("utf-8")
                                            sub_str.append(f"sF{sfnum}:\"{s}\"")
                                        except:
                                            sub_str.append(f"sF{sfnum}:<{len(sfval)}B>")
                                    else:
                                        sub_str.append(f"sF{sfnum}:{sfval}")
                                field_desc.append(f"F{fnum}(sub):[{', '.join(sub_str)}]")
                            else:
                                field_desc.append(f"F{fnum}(bytes):<{len(fval)}B>")
                        else:
                            field_desc.append(f"F{fnum}({ftype}):{fval}")

                    dir_str = "APP->G2" if ptype == 0x21 else "G2->APP"
                    print(f"#{pkt_idx:03d} {dir_str} Seq={seq:02X} Svc={shi:02X}-{slo:02X} Len={plen:2d} | {' | '.join(field_desc)}")

                pkt_idx += 1
                i += 8 + plen
                continue
        i += 1

if __name__ == "__main__":
    parse_pklg("tests/__pycache__/对话模式_无AI提示_有退出对话模式.pklg")
