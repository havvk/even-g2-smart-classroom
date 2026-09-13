import Foundation

/// Even G2 对话模式 (Service 0x0B-20) 协议与算法自动化测试套件
@main
struct ConversationTestRunner {
    static func main() {
        var passedCount = 0
        var failedCount = 0

        func assertTest(_ name: String, _ condition: Bool) {
            if condition {
                print("✅ [PASSED] \(name)")
                passedCount += 1
            } else {
                print("❌ [FAILED] \(name)")
                failedCount += 1
            }
        }

        print("==================================================")
        print("🧪 1. ConversateInit (Service 0x0B-20, Type 1) 编码测试")
        print("==================================================")

        var seq: UInt8 = 0x05
        let initPkt = G2ProtocolEncoder.buildConversateInit(seq: &seq)
        
        assertTest("TC_CONV_001: 帧头为 AA 21", initPkt.count > 8 && initPkt[0] == 0xAA && initPkt[1] == 0x21)
        assertTest("TC_CONV_002: 服务通道为 0x0B-20", initPkt[6] == 0x0B && initPkt[7] == 0x20)
        assertTest("TC_CONV_003: 初始大包长度 > 100 字节", initPkt.count > 100)
        
        // 校验 CRC16
        let crcActual = UInt16(initPkt[initPkt.count - 2]) | (UInt16(initPkt[initPkt.count - 1]) << 8)
        let crcExpected = G2ProtocolEncoder.crc16CCITT(initPkt.subdata(in: 8..<(initPkt.count - 2)))
        assertTest("TC_CONV_004: Init 报文 CRC16 校验有效", crcActual == crcExpected)

        print("\n==================================================")
        print("🧪 2. ConversateTranscript (Type 6) 实时语音转写编码测试")
        print("==================================================")

        let transcriptText = "这是一条测试转写字幕"
        var tSeq: UInt8 = 0x12
        let transPkt = G2ProtocolEncoder.buildConversateTranscript(seq: &tSeq, text: transcriptText, isFinal: true)
        
        assertTest("TC_TRANS_001: 转写通道为 0x0B-20", transPkt[6] == 0x0B && transPkt[7] == 0x20)
        assertTest("TC_TRANS_002: 包含 Type 6 (0x08 0x06)", transPkt.subdata(in: 8..<transPkt.count).contains(Data([0x08, 0x06])))
        assertTest("TC_TRANS_003: 包含 UTF-8 转写内容", transPkt.contains(Data(transcriptText.utf8)))
        assertTest("TC_TRANS_004: 包含 is_final=1 标记", transPkt.contains(Data([0x10, 0x01])))

        print("\n==================================================")
        print("🧪 3. ConversateAIPrompt (Type 5) 极简 AI 药丸胶囊编码测试")
        print("==================================================")

        let title = "💡 建议: 先确认工期"
        let detail = "1. 预留 3 周联调缓冲\n2. 前置采购芯片"
        var pSeq: UInt8 = 0x1A
        let promptPkt = G2ProtocolEncoder.buildConversateAIPrompt(seq: &pSeq, title: title, detail: detail, cardType: 4)
        
        assertTest("TC_PROMPT_001: 胶囊通道为 0x0B-20", promptPkt[6] == 0x0B && promptPkt[7] == 0x20)
        assertTest("TC_PROMPT_002: 包含 Type 5 (0x08 0x05)", promptPkt.subdata(in: 8..<promptPkt.count).contains(Data([0x08, 0x05])))
        assertTest("TC_PROMPT_003: 包含 card_type=4 (0x08 0x04)", promptPkt.contains(Data([0x08, 0x04])))
        assertTest("TC_PROMPT_004: 包含 UTF-8 胶囊标题", promptPkt.contains(Data(title.utf8)))
        assertTest("TC_PROMPT_005: 包含 UTF-8 展开详情", promptPkt.contains(Data(detail.utf8)))

        print("\n==================================================")
        print("🧪 4. ConversateSync (Type 255) 与 Exit (Type 1) 控制测试")
        print("==================================================")

        var sSeq: UInt8 = 0x20
        let syncPkt = G2ProtocolEncoder.buildConversateSync(seq: &sSeq)
        assertTest("TC_SYNC_001: 包含 Type 255 标识 (0x08 0xFF 0x01)", syncPkt.contains(Data([0x08, 0xFF, 0x01])))
        assertTest("TC_SYNC_002: 包含 5A 00 显存锁存", syncPkt.contains(Data([0x5A, 0x00])))

        var eSeq: UInt8 = 0x25
        let exitPkt = G2ProtocolEncoder.buildConversateExit(seq: &eSeq)
        assertTest("TC_EXIT_001: 包含 Type 1 与 Action 2 (1A 04 08 02 20 00)", exitPkt.contains(Data([0x1A, 0x04, 0x08, 0x02, 0x20, 0x00])))

        print("\n==================================================")
        print("🧪 5. 真实抓包还原: 0x0B-01 镜腿触控展开事件解析测试")
        print("==================================================")

        // 来自真实原厂抓包 tests/对话模式_有AI提示_有展开提示操作.pklg 中的关键帧 #69
        let realExpandedHex = "AA122E0C01010B0108A301104C6203209A2D89CD"
        var realExpandedData = Data()
        var hexStr = realExpandedHex
        while !hexStr.isEmpty {
            let sub = String(hexStr.prefix(2))
            hexStr = String(hexStr.dropFirst(2))
            if let b = UInt8(sub, radix: 16) {
                realExpandedData.append(b)
            }
        }

        if let notif = G2ProtocolEncoder.parseConversateNotification(realExpandedData) {
            assertTest("TC_NOTIF_001: 成功解出 0x0B-01 事件", true)
            assertTest("TC_NOTIF_002: EventType 解出为 163 (Type 3 展开)", notif.eventType == 163)
            assertTest("TC_NOTIF_003: isCardExpanded 判定为 true", notif.isCardExpanded == true)
            assertTest("TC_NOTIF_004: msgId 正确匹配为 76 (0x4C)", notif.msgId == 76)
        } else {
            assertTest("TC_NOTIF_001: 成功解出 0x0B-01 事件", false)
        }

        print("\n==================================================")
        print("🧪 6. AICopilotPromptManager 微标签门禁与 20 槽位抽屉测试")
        print("==================================================")

        let longTitle = "💡 建议: 这是一个非常非常长甚至超过二十个汉字的超级长标题\n带换行"
        let sanitized = AICopilotPromptManager.sanitizeTitle(longTitle)
        assertTest("TC_TAG_001: 清除换行符", !sanitized.contains("\n"))
        assertTest("TC_TAG_002: 强制截断在 13 字符以内以适配 MicroLED 单行胶囊", sanitized.count <= 13)

        let mgr = AICopilotPromptManager()
        for i in 1...25 {
            mgr.pushCard(msgId: i, rawTitle: "建议 #\(i)", detail: "详情 #\(i)")
        }
        
        // 模拟触发异步刷新
        let exp = mgr.drawerCards
        assertTest("TC_DRAWER_001: 20 槽位硬上限裁切 (FIFO)", exp.count <= 20)

        print("\n==================================================")
        print("🧪 7. DualTrackSpeakerDetector 说话人能量比对测试")
        print("==================================================")

        let detector = DualTrackSpeakerDetector()
        assertTest("TC_SPK_001: 默认说话人为未定", detector.currentSpeaker == .unknown)

        print("\n==================================================")
        print("📊 自动化测试统计: 通过 \(passedCount) 项, 失败 \(failedCount) 项")
        print("==================================================")

        if failedCount == 0 {
            print("🎉 所有对话模式协议与算法测试 100% 顺利通过！")
            exit(0)
        } else {
            print("⚠️ 存在失败项，请检查逻辑！")
            exit(1)
        }
    }
}
