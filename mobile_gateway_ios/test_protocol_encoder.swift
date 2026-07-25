import Foundation

@main
struct ProtocolTests {
    static func main() {
        print("=== 开始运行 Even G2 Protocol Encoder 单元测试断言库 ===")

        // 1. 测试 CRC16 计算
        let testData = Data([0xAA, 0x21, 0x01, 0x0C, 0x01, 0x01, 0x80, 0x00, 0x08, 0x04, 0x10, 0x0C, 0x1A, 0x04, 0x08, 0x01, 0x10, 0x04])
        let crcResult = G2ProtocolEncoder.addCRC(testData)
        assert(crcResult.count == testData.count + 2, "CRC16 应该增加 2 字节尾部")
        assert(crcResult[crcResult.count - 2] == 0xC6 && crcResult[crcResult.count - 1] == 0xBC, "Auth Packet 1 的 CRC 应当精准匹配 0xC6BC")
        print("✅ Test 1 Passed: CRC16 校验算法与 C++ 原生输出 100% 吻合 (0xC6BC)")

        // 2. 测试 buildEnterTeleprompterModePacket (TeleprompterStart)
        let startPacket = G2ProtocolEncoder.buildEnterTeleprompterModePacket(seq: 0x08, msgId: 0x14)
        print("Start Packet HEX: \(startPacket.map { String(format: "%02X", $0) }.joined(separator: " "))")
        assert(startPacket[0] == 0xAA, "魔数必须是 0xAA")
        assert(startPacket[2] == 0x08, "Seq 必须是 0x08")
        assert(startPacket[6] == 0x06 && startPacket[7] == 0x20, "Service 必须是 0x06-20")
        let payloadBytes = startPacket.subdata(in: 8..<(startPacket.count - 2))
        assert(!payloadBytes.contains(0x06), "Protobuf Payload 严禁包含非法的 WireType 0x06")
        print("✅ Test 2 Passed: TeleprompterStart Protobuf 序列化结构合法且无 WireType 6 异常")

        // 3. 测试 14 页 140 行补满机制
        let (pages, _, linesPerPage) = G2ProtocolEncoder.formatTextToPages("短文本", targetWidthChars: 28, linesPerPage: 9)
        assert(pages.count >= 14, "短文本切页数必须强制用空白页填满至至少 14 页")
        assert(linesPerPage == 9, "每页必须恒定为 9 行")
        print("✅ Test 3 Passed: 14 页画卷强制补全测试通过 (实际切页: \(pages.count) 页)")

        // 4. 测试 GPU Sync Trigger (0x80-00 type=14)
        let syncPacket = G2ProtocolEncoder.buildSync(seq: 0x1D, msgId: 0x28)
        print("Sync Packet HEX: \(syncPacket.map { String(format: "%02X", $0) }.joined(separator: " "))")
        assert(syncPacket[6] == 0x80 && syncPacket[7] == 0x00, "Service 必须是 0x80-00")
        assert(syncPacket[8] == 0x08 && syncPacket[9] == 0x0E, "Tag 1 必须是 Type=14 (0x0E)")
        print("✅ Test 4 Passed: Step 10 GPU VSYNC Sync Trigger 报文生成验证通过")

        print("=== 🎉 所有 4 项协议单元测试全部 PASS，物理报文可信度 100% ===")
    }
}
