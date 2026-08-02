import struct
import binascii

def parse():
    with open("tests/bt.pklg", "rb") as f:
        while True:
            header = f.read(24)
            if not header or len(header) < 24: break
            orig_len, inc_len, flags, drops, ts_hi, ts_lo = struct.unpack(">IIIIII", header)
            payload = f.read(inc_len)
            
            # HCI ACL Data is type 02. Let's just find 0x1B (Handle Value Notification)
            # Usually HCI header (4) + ACL (4) + L2CAP (4) + ATT (Opcode 1)
            # Find 1B opcode and dump
            if len(payload) > 13:
                # flags: 0x01 is Sent, 0x00 is Received
                # In btSnoop, flags bit 0: 0 = Sent, 1 = Received.
                # Actually, macOS PacketLogger format might be different!
                # It's macOS PacketLogger (.pklg) format!!
                pass
            
            # Let's just do a naive search for ATT Opcode 0x1B (Notification) in the whole payload
            # Assuming ATT handle is something like 0x002A or similar.
            # Just print the payload if it came from the glasses.
            # macOS PacketLogger header: 
            # 4 bytes length, 4 bytes ts_sec, 4 bytes ts_usec, ... wait, format is different!
            pass

def parse_pklg_macos():
    with open("tests/bt.pklg", "rb") as f:
        while True:
            header = f.read(8)
            if not header or len(header) < 8: break
            ts_sec, type, length = struct.unpack("<IIi", header)
            payload = f.read(length)
            
            if type == 2 and len(payload) >= 9:
                # HCI ACL Data
                # PB Flag is in payload[0:2]
                handle_pb = struct.unpack("<H", payload[0:2])[0]
                handle = handle_pb & 0x0FFF
                pb_flag = (handle_pb >> 12) & 0x3
                
                if pb_flag == 2 or pb_flag == 1:
                    l2cap_len = struct.unpack("<H", payload[4:6])[0]
                    cid = struct.unpack("<H", payload[6:8])[0]
                    
                    if cid == 4: # ATT
                        opcode = payload[8]
                        if opcode == 0x1B: # Notification
                            att_handle = struct.unpack("<H", payload[9:11])[0]
                            data = payload[11:]
                            print(f"Handle 0x{att_handle:04X} Notif: {data.hex()}")

parse_pklg_macos()
