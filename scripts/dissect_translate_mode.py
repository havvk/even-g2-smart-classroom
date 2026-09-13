import os
from scripts.deep_decode_proto import decode_proto_fields

def parse_translate_pklg(filename):
    print("=" * 80)
    print(f"Deep Decoding Translation Mode (0x05-20): {filename}")
    print("=" * 80)

    with open(filename, "rb") as f:
        data = f.read()

    i = 0
    pkt_idx = 0
    while i < len(data) - 8:
        if data[i] == 0xAA and data[i+1] == 0x21:
            plen = data[i+3]
            tot, idx = data[i+4], data[i+5]
            shi, slo = data[i+6], data[i+7]

            if plen > 0 and i + 8 + plen <= len(data) + 2:
                payload = data[i+8 : i+8+plen]
                proto = payload[:-2] if len(payload) >= 2 else payload

                if (shi, slo) == (0x05, 0x20):
                    fields = decode_proto_fields(proto)
                    f_dict = {}
                    for f in fields:
                        f_dict[f[0]] = f[2]

                    t = f_dict.get(1)
                    msg_id = f_dict.get(2)
                    
                    if t == 1:
                        # Init or Exit
                        c_data = f_dict.get(3, b"")
                        sub = decode_proto_fields(c_data)
                        s_dict = {sf[0]: sf[2] for sf in sub}
                        print(f"Pkt #{pkt_idx:03d} [Type 1 SessionControl] MsgId={msg_id}")
                        print(f"   Action: {s_dict.get(1)}")
                        if 2 in s_dict:
                            try:
                                print(f"   Mode/Pair: {s_dict[2].decode('utf-8')}")
                            except:
                                print(f"   Field 2 (bytes): {s_dict[2].hex()}")
                        if 4 in s_dict:
                            print(f"   Status: {s_dict[4]}")
                    elif t == 2:
                        # Sentence Translation Update
                        body = f_dict.get(4, b"")
                        sub = decode_proto_fields(body)
                        s_dict = {sf[0]: sf[2] for sf in sub}
                        orig = s_dict.get(1, b"").decode("utf-8", errors="ignore")
                        trans = s_dict.get(2, b"").decode("utf-8", errors="ignore")
                        speaker = ""
                        if 5 in s_dict:
                            try:
                                speaker = s_dict[5].decode("utf-16be", errors="ignore")
                            except:
                                speaker = s_dict[5].hex()
                        print(f"Pkt #{pkt_idx:03d} [Type 2 TranslationSentence] MsgId={msg_id} ({idx}/{tot})")
                        if orig:
                            print(f"   [Original]: {orig[:60]}{'...' if len(orig)>60 else ''}")
                        if trans:
                            print(f"   [Target]  : {trans[:60]}{'...' if len(trans)>60 else ''}")
                        if speaker:
                            print(f"   [Speaker] : {speaker.strip()}")
                        print(f"   [Flags]   : F3={s_dict.get(3)}, F4={s_dict.get(4)}")
                    elif t == 255:
                        print(f"Pkt #{pkt_idx:03d} [Type 255 SyncMarker] MsgId={msg_id}")
                    else:
                        print(f"Pkt #{pkt_idx:03d} [Type {t}] MsgId={msg_id} Fields={fields}")

                pkt_idx += 1
                i += 8 + plen
                continue
        i += 1

if __name__ == "__main__":
    parse_translate_pklg("tests/翻译模式_中译英.pklg")
