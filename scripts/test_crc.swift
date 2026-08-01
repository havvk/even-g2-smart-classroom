import Foundation

func crc16CCITT(_ data: Data, initVal: UInt16 = 0xFFFF) -> UInt16 {
    var crc: UInt16 = initVal
    for byte in data {
        crc ^= (UInt16(byte) << 8)
        for _ in 0..<8 {
            if (crc & 0x8000) != 0 {
                crc = ((crc << 1) ^ 0x1021) & 0xFFFF
            } else {
                crc = (crc << 1) & 0xFFFF
            }
        }
    }
    return crc
}

func addCRC(_ packet: Data) -> Data {
    guard packet.count >= 8 else { return packet }
    let payloadToCRC = packet.subdata(in: 8..<packet.count)
    let crc = crc16CCITT(payloadToCRC)
    var result = packet
    result.append(UInt8(crc & 0xFF))
    result.append(UInt8((crc >> 8) & 0xFF))
    return result
}

let pkt1 = Data([
    0xAA, 0x21, 0x01, 0x0C, 0x01, 0x01, 0x80, 0x00,
    0x08, 0x04, 0x10, 0x0C, 0x1A, 0x04, 0x08, 0x01, 0x10, 0x04
])
let res1 = addCRC(pkt1)
print("Swift Auth1: \(res1.map { String(format: "%02x", $0) }.joined())")
