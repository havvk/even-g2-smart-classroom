import sys
class Mock:
    def __getattr__(self, name):
        return Mock()
sys.modules['bleak'] = Mock()
import sys
sys.path.append('even-g2-protocol/examples/teleprompter')
import teleprompter
import asyncio

async def dummy():
    pass

# We can just call the builders!
seq = 0x08
msg_id = 0x15

all_pkts = []
all_pkts.extend(teleprompter.build_auth_packets())

all_pkts.extend(teleprompter.build_display_config(seq, msg_id))
seq += 1; msg_id += 1

all_pkts.extend(teleprompter.build_teleprompter_init(seq, msg_id))
seq += 1; msg_id += 1

# One content page
pages = teleprompter.format_text("测试")
for i, page_text in enumerate(pages):
    all_pkts.extend(teleprompter.build_content_page(seq, msg_id, i, page_text))
    seq = (seq + 1) & 0xFF; msg_id += 1

# Sync trigger
payload = bytes([0x08, 0x0E, 0x10]) + teleprompter.encode_varint(msg_id) + bytes([0x6A, 0x00])
all_pkts.extend(teleprompter.build_packets(seq, 0x80, 0x00, payload))
seq = (seq + 1) & 0xFF; msg_id += 1

# UI Route
route_pkt = teleprompter.build_packets(seq, 0x09, 0x20,
    bytes.fromhex("080110") + teleprompter.encode_varint(msg_id) +
    bytes.fromhex("1a1a52180a060800100018000a060800100118000a06080010021800"))
all_pkts.extend(route_pkt)

for p in all_pkts:
    print(p.hex())
