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

let ts = 1722495818000
let res = encodeVarint(ts)
print("Swift Varint: \(res.map { String(format: "%02x", $0) }.joined())")
