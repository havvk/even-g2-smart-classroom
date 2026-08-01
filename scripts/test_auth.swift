import Foundation

func encodeVarint(_ value: Int) -> Data {
    var val = value
    if val < 0 {
        val += 1 << 64
    }
    var out = Data()
    while val >= 0x80 {
        out.append(UInt8((val & 0x7F) | 0x80))
        val >>= 7
    }
    out.append(UInt8(val))
    return out
}

func crc16CCITT(_ data: Data) -> UInt16 {
    var crc: UInt16 = 0xFFFF
    for byte in data {
        crc ^= UInt16(byte)
        for _ in 0..<8 {
            if (crc & 1) != 0 {
                crc = (crc >> 1) ^ 0xA001
            } else {
                crc >>= 1
            }
        }
    }
    return crc
}

func addCRC(_ data: Data) -> Data {
    let crc = crc16CCITT(data)
    var result = data
    result.append(UInt8(crc & 0xFF))
    result.append(UInt8((crc >> 8) & 0xFF))
    return result
}

let timestamp = 1718000000000 // A dummy timestamp
let tsVarint = encodeVarint(timestamp)
let txid = Data([0xE8, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01])

var p3Payload = Data([0x08, 0x80, 0x01, 0x10, 0x0F, 0x82, 0x08, 0x11, 0x08])
p3Payload.append(tsVarint)
p3Payload.append(Data([0x10]))
p3Payload.append(txid)
let p3Len = UInt8((p3Payload.count + 2) & 0xFF)
var p3Header = Data([0xAA, 0x21, 0x03, p3Len, 0x01, 0x01, 0x80, 0x20])
p3Header.append(p3Payload)
let auth3 = addCRC(p3Header)
print("Auth3: \(auth3.map { String(format: "%02x", $0) }.joined())")
