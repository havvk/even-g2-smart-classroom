import Foundation

// Assuming we appended G2ProtocolEncoder.swift
var seq: UInt8 = 0x08
var msgId = 0x15

var allPkts = [Data]()
allPkts.append(contentsOf: G2ProtocolEncoder.buildAuthPackets())

allPkts.append(G2ProtocolEncoder.buildDisplayConfig(seq: &seq, msgId: msgId))
msgId += 1

allPkts.append(contentsOf: G2ProtocolEncoder.buildTeleprompterInit(seq: &seq, msgId: msgId, scrollModeAI: true))
msgId += 1

let pages = ["测试"]
for (i, pageText) in pages.enumerated() {
    allPkts.append(contentsOf: G2ProtocolEncoder.buildContentPagePackets(seq: &seq, msgId: msgId, pageNum: i, text: pageText))
    msgId += 1
}

var payload = Data([0x08, 0x0E, 0x10])
payload.append(G2ProtocolEncoder.encodeVarint(msgId))
payload.append(Data([0x6A, 0x00]))
let pktsSync = G2ProtocolEncoder.buildPackets(seq: &seq, serviceHi: 0x80, serviceLo: 0x00, payload: payload)
allPkts.append(contentsOf: pktsSync)
msgId += 1

allPkts.append(G2ProtocolEncoder.buildRouteSwitch(seq: &seq, msgId: msgId))

for p in allPkts {
    print(p.map { String(format: "%02x", $0) }.joined())
}
