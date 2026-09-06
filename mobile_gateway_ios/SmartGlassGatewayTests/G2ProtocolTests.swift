//
//  G2ProtocolTests.swift
//  SmartGlassGatewayTests
//
//  基于 Even G2 逆向工程规范 (docs/g2_reverse_engineering.md) 编写的单元测试集
//

import XCTest
@testable import SmartGlassGateway

final class G2ProtocolTests: XCTestCase {
    
    // MARK: - 18.1 模块 1: CRC16 与 Header 编码测试
    
    func testHeaderEncoding_TC_BLE_001() {
        let seq: UInt8 = 0x08
        let svcHi: UInt8 = 0x06
        let svcLo: UInt8 = 0x20
        let payload: [UInt8] = [0x08, 0x01]
        
        let packets = G2ProtocolEncoder.buildPackets(seq: seq, serviceHi: svcHi, serviceLo: svcLo, payload: Data(payload))
        XCTAssertEqual(packets.count, 1)
        
        let header = [UInt8](packets[0].prefix(8))
        XCTAssertEqual(header[0], 0xAA, "Magic 必须为 0xAA")
        XCTAssertEqual(header[1], 0x21, "Type 必须为 0x21 (Command)")
        XCTAssertEqual(header[2], 0x08, "Sequence ID 匹配")
        XCTAssertEqual(header[3], 0x04, "Single packet len = payload + 2")
        XCTAssertEqual(header[4], 0x01, "pktTot == 1")
        XCTAssertEqual(header[5], 0x01, "pktSer == 1")
        XCTAssertEqual(header[6], 0x06, "Service Hi 匹配")
        XCTAssertEqual(header[7], 0x20, "Service Lo 匹配")
    }
    
    func testCRC16Addition_TC_BLE_002() {
        let payload: [UInt8] = [0x08, 0x01, 0x10, 0x14]
        let packets = G2ProtocolEncoder.buildPackets(seq: 0x01, serviceHi: 0x80, serviceLo: 0x00, payload: Data(payload))
        
        XCTAssertEqual(packets.count, 1)
        let frame = [UInt8](packets[0])
        
        // 验证末尾 2 字节为 CRC16
        let crcBytes = Array(frame.suffix(2))
        let computedCRC = G2ProtocolEncoder.crc16CCITT(Data(payload), initVal: 0xFFFF)
        
        XCTAssertEqual(crcBytes[0], UInt8(computedCRC & 0xFF), "CRC 低字节匹配")
        XCTAssertEqual(crcBytes[1], UInt8((computedCRC >> 8) & 0xFF), "CRC 高字节匹配")
    }
    
    // MARK: - 18.2 模块 2: TeleprompterInit 参数测试
    
    func testTeleprompterInitParameters_TC_CFG_001() {
        let packets = G2ProtocolEncoder.buildTeleprompterInit(seq: 1, msgId: 1)
        XCTAssertGreaterThan(packets.count, 0)
        
        let hexString = packets[0].map { String(format: "%02x", $0) }.joined()
        
        // 断言包含 display_width=59 (20 3b -> hex 203b)
        XCTAssertTrue(hexString.contains("203b"), "display_width 必须设置为 59 (0x3B)")
        // 断言包含 line_height=567 (30 b7 04 -> hex 30b704)
        XCTAssertTrue(hexString.contains("30b704"), "line_height 必须设置为 567")
        // 断言包含 viewport_height=3113 (38 a9 18 -> hex 38a918)
        XCTAssertTrue(hexString.contains("38a918"), "viewport_height 必须设置为 3113")
        // 断言包含 render_mode=9 (50 09 -> hex 5009)
        XCTAssertTrue(hexString.contains("5009"), "render_mode 必须设置为 9")
    }
    
    // MARK: - 18.3 模块 3: 提词排版与 14 页缓冲测试
    
    func testTextFormatting_TC_TXT_001_003() {
        let sampleText = "今天我们召开《人机协同程序设计》课程全校统一数智化教学集体备课研讨会"
        let pages = G2ProtocolEncoder.formatTextToPages(sampleText)
        
        // 14 页硬性缓冲区断言
        XCTAssertGreaterThanOrEqual(pages.count, 14, "短文本必须自动扩充补满 14 页缓冲区")
        
        // 检查首页行数与前置 \n
        let firstPageLines = pages[0].components(separatedBy: "\n")
        XCTAssertEqual(firstPageLines.count, 10, "每页必须精确容纳 10 行")
        XCTAssertFalse(firstPageLines[0].isEmpty, "首行不得为前置 \\n 空行")
    }
    
    // MARK: - 18.4 模块 4: 位置 Notification 解调测试
    
    func testPositionNotificationParsing_TC_NOTIFY_002_003() {
        // 模拟捕抓的 Raw Notification 数据包: Line 3 (00002760-08c2-11e1-9073-0e8ac72e5402, Svc 0x0601, Type 165)
        let rawNotificationHex = "aa12470b0101060108a501105e5a02100364d7"
        let rawData = Data(hexString: rawNotificationHex)!
        
        let parsedPos = G2ProtocolEncoder.parsePositionNotification(from: rawData)
        XCTAssertNotNil(parsedPos)
        XCTAssertEqual(parsedPos?.eventType, 165, "Event Type 必须为 165 (0xA5)")
        XCTAssertEqual(parsedPos?.currentLine, 3, "成功解调出 currentLine == 3")
        
        // 校验行号到页码换算逻辑
        if let line = parsedPos?.currentLine {
            let pageId = line / 10
            let rawLine = line % 10
            XCTAssertEqual(pageId, 0)
            XCTAssertEqual(rawLine, 3)
        }
    }
    
    // MARK: - 18.5 模块 5: 麦克风音频控制帧测试 (EvenHub Cmd=15 / 0x0E)
    
    func testAudioControlPacket_TC_AUDIO_001() {
        var seq: UInt8 = 0x05
        let enablePkt = G2ProtocolEncoder.buildAudioControlPacket(enable: true, seq: &seq, magic: 0xA1)
        XCTAssertEqual(seq, 0x06, "自增序列号消耗 1")
        
        // 校验 Header (8 字节)
        XCTAssertEqual(enablePkt[0], 0xAA, "Magic 为 0xAA")
        XCTAssertEqual(enablePkt[1], 0x21, "Type 为 0x21 (Cmd)")
        XCTAssertEqual(enablePkt[2], 0x05, "Seq 匹配")
        XCTAssertEqual(enablePkt[4], 0x01, "pktTot 为 1")
        XCTAssertEqual(enablePkt[5], 0x01, "pktSer 为 1")
        XCTAssertEqual(enablePkt[6], 0xE0, "ServiceHi 为 0xE0 (EvenHub)")
        XCTAssertEqual(enablePkt[7], 0x00, "ServiceLo 为 0x00")
        
        // 校验 Payload: 08 0F 10 A1 92 01 02 08 01
        let payload = enablePkt.subdata(in: 8..<(enablePkt.count - 2))
        XCTAssertEqual([UInt8](payload), [0x08, 0x0F, 0x10, 0xA1, 0x92, 0x01, 0x02, 0x08, 0x01])
        
        // 校验 CRC
        let crcBytes = Array(enablePkt.suffix(2))
        let computedCRC = G2ProtocolEncoder.crc16CCITT(payload)
        XCTAssertEqual(crcBytes[0], UInt8(computedCRC & 0xFF))
        XCTAssertEqual(crcBytes[1], UInt8((computedCRC >> 8) & 0xFF))
        
        // 校验透传指令
        let rawEnable = G2ProtocolEncoder.buildRawMicControlPacket(enable: true)
        XCTAssertEqual([UInt8](rawEnable), [0x0E, 0x01])
        let rawDisable = G2ProtocolEncoder.buildRawMicControlPacket(enable: false)
        XCTAssertEqual([UInt8](rawDisable), [0x0E, 0x00])
    }
}

// Data Hex 拓展工具 helper
extension Data {
    init?(hexString: String) {
        let len = hexString.count / 2
        var data = Data(capacity: len)
        var i = hexString.startIndex
        for _ in 0..<len {
            let j = hexString.index(i, offsetBy: 2)
            let bytes = hexString[i..<j]
            if let num = UInt8(bytes, radix: 16) {
                data.append(num)
            } else {
                return nil
            }
            i = j
        }
        self = data
    }
}
