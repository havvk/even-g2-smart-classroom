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

func buildPackets(seq: inout UInt8, serviceHi: UInt8, serviceLo: UInt8, payload: Data, maxChunkSize: Int = 232) -> [Data] {
    let currentSeq = seq
    seq &+= 1
    
    if payload.count <= maxChunkSize {
        let lenByte = UInt8((payload.count + 2) & 0xFF)
        var header = Data([0xAA, 0x21, currentSeq, lenByte, 0x01, 0x01, serviceHi, serviceLo])
        header.append(payload)
        return [addCRC(header)]
    }
    return []
}

func buildPacket(seq: inout UInt8, serviceHi: UInt8, serviceLo: UInt8, payload: Data) -> Data {
    let pkts = buildPackets(seq: &seq, serviceHi: serviceHi, serviceLo: serviceLo, payload: payload)
    return pkts.first ?? Data()
}

var seq: UInt8 = 25
let msgId = 8
var payload = Data([0x08, 0x0E, 0x10])
payload.append(encodeVarint(msgId))
payload.append(Data([0x6A, 0x00]))
let sync = buildPacket(seq: &seq, serviceHi: 0x80, serviceLo: 0x00, payload: payload)
print("Sync: \(sync.map { String(format: "%02x", $0) }.joined())")

var routePayload = Data([0x08, 0x01, 0x10])
routePayload.append(encodeVarint(msgId + 1))
let hex = "1a1a52180a060800100018000a060800100118000a06080010021800"
var hexData = Data()
var hexStr = hex
while !hexStr.isEmpty {
    let subHex = hexStr.prefix(2)
    hexStr = String(hexStr.dropFirst(2))
    if let b = UInt8(subHex, radix: 16) {
        hexData.append(b)
    }
}
routePayload.append(hexData)
let route = buildPacket(seq: &seq, serviceHi: 0x09, serviceLo: 0x20, payload: routePayload)
print("Route: \(route.map { String(format: "%02x", $0) }.joined())")
