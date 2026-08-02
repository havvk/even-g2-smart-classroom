import Foundation

func crc16CCITT(_ data: Data) -> UInt16 {
    var crc: UInt16 = 0xFFFF
    for byte in data {
        crc ^= (UInt16(byte) << 8)
        for _ in 0..<8 {
            if (crc & 0x8000) != 0 {
                crc = (crc << 1) ^ 0x1021
            } else {
                crc = crc << 1
            }
        }
    }
    return crc
}

func encodeVarint(_ value: Int) -> Data {
    var val = value
    var out = Data()
    while val >= 0x80 {
        out.append(UInt8((val & 0x7F) | 0x80))
        val >>= 7
    }
    out.append(UInt8(val))
    return out
}

func addCRC(_ data: Data) -> Data {
    let payload = data.subdata(in: 8..<data.count)
    let crc = crc16CCITT(payload)
    var result = data
    result.append(UInt8(crc & 0xFF))
    result.append(UInt8((crc >> 8) & 0xFF))
    return result
}

func buildPacket(seq: inout UInt8, serviceHi: UInt8, serviceLo: UInt8, payload: Data) -> Data {
    let currentSeq = seq
    seq &+= 1
    let lenByte = UInt8((payload.count + 2) & 0xFF)
    var header = Data([0xAA, 0x21, currentSeq, lenByte, 0x01, 0x01, serviceHi, serviceLo])
    header.append(payload)
    return addCRC(header)
}

var seq: UInt8 = 1
let timestamp = 1785501864
let tsVarint = encodeVarint(timestamp)
let txid = Data([0xE8, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01])

let p1 = buildPacket(seq: &seq, serviceHi: 0x80, serviceLo: 0x00, payload: Data([
    0x08, 0x04, 0x10, 0x0C, 0x1A, 0x04, 0x08, 0x01, 0x10, 0x04
]))
print("Swift Auth 1: \(p1.map { String(format: "%02x", $0) }.joined())")

let p2 = buildPacket(seq: &seq, serviceHi: 0x80, serviceLo: 0x20, payload: Data([
    0x08, 0x05, 0x10, 0x0E, 0x22, 0x02, 0x08, 0x02
]))
print("Swift Auth 2: \(p2.map { String(format: "%02x", $0) }.joined())")

var p3Payload = Data([0x08, 0x80, 0x01, 0x10, 0x0F, 0x82, 0x08, 0x11, 0x08])
p3Payload.append(tsVarint)
p3Payload.append(Data([0x10]))
p3Payload.append(txid)
let p3 = buildPacket(seq: &seq, serviceHi: 0x80, serviceLo: 0x20, payload: p3Payload)
print("Swift Auth 3: \(p3.map { String(format: "%02x", $0) }.joined())")

