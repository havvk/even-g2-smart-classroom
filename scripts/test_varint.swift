import Foundation
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
let v = encodeVarint(1785501864)
print("Swift: \(v.map { String(format: "%02x", $0) }.joined())")
