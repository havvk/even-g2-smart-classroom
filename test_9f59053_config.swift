import Foundation

func encodeVarint(_ value: Int) -> Data {
    var v = UInt64(value)
    var result = Data()
    while v >= 128 {
        result.append(UInt8((v & 0x7F) | 0x80))
        v >>= 7
    }
    result.append(UInt8(v))
    return result
}

let configHex = "08011215080210904E1D0000000025000000002800300038001215080310AC021D0000000025000000002800300038001214080410001D0000000025000000002800300038001214080510001D0000000025000000002800300038001214080610001D0000000025000000002800300038001214080910001D0000000025000000002800300038001800"
var configBytes = Data()
var hexStr = configHex
while !hexStr.isEmpty {
    let subHex = hexStr.prefix(2)
    hexStr = String(hexStr.dropFirst(2))
    if let b = UInt8(subHex, radix: 16) {
        configBytes.append(b)
    }
}

var payload = Data([0x08, 0x02, 0x10])
payload.append(encodeVarint(21))
payload.append(Data([0x22]))
payload.append(encodeVarint(configBytes.count))
payload.append(configBytes)

print(payload.map { String(format: "%02x", $0) }.joined())
