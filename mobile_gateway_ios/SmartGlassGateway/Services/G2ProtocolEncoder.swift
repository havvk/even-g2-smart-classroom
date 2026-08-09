import Foundation

/// Even G2 智能眼镜 BLE 协议二进制编码器 (100% 物理对齐 G2 提词器最新逆向成果)
class G2ProtocolEncoder {
    
    // MARK: - Protobuf Varint Helper
    
    /// 将整数编码为 Protobuf Varint 字节数组
    static func encodeVarint(_ value: Int) -> Data {
        var val = value
        var result = Data()
        while val > 0x7F {
            result.append(UInt8((val & 0x7F) | 0x80))
            val >>= 7
        }
        result.append(UInt8(val & 0x7F))
        return result
    }
    
    // MARK: - CRC16 CCITT (Init: 0xFFFF, Poly: 0x1021)
    
    /// CRC-16/CCITT 校验计算 (Init: 0xFFFF, Poly: 0x1021)
    static func crc16CCITT(_ data: Data, initVal: UInt16 = 0xFFFF) -> UInt16 {
        var crc: UInt16 = initVal
        for byte in data {
            crc ^= (UInt16(byte) << 8)
            for _ in 0..<8 {
                if (crc & 0x8000) != 0 {
                    crc = ((crc << 1) ^ 0x1021) & 0xFFFF
                } else {
                    crc = (crc << 1) & 0xFFFF
                }
            }
        }
        return crc
    }
    
    /// 给单包数据包增加 2 字节小端 CRC16 校验尾部 (计算范围: 8..<count)
    static func addCRC(_ packet: Data) -> Data {
        guard packet.count >= 8 else { return packet }
        let payloadToCRC = packet.subdata(in: 8..<packet.count)
        let crc = crc16CCITT(payloadToCRC)
        var result = packet
        result.append(UInt8(crc & 0xFF))
        result.append(UInt8((crc >> 8) & 0xFF))
        return result
    }
    
    // MARK: - BLE Packet Builder (单包 Frame CRC vs 多包 Payload CRC)
    
    /// 支持 BLE ATT MTU 分片的物理封包器
    /// - 单包 (<= maxChunkSize): Header(8b) + Payload + Frame-level CRC(2b), Header Len = PayloadLen + 2
    /// - 多包 (> maxChunkSize): 尾部拼接 Payload-level CRC(2b) 后分包，Header Len = ChunkLen, 无子包级 CRC
    static func buildPackets(seq: inout UInt8, serviceHi: UInt8, serviceLo: UInt8, payload: Data, maxChunkSize: Int = 232) -> [Data] {
        let currentSeq = seq
        seq &+= 1 // 一个逻辑包只消耗一个 seq (与官方应用对齐)
        
        if payload.count <= maxChunkSize {
            let lenByte = UInt8((payload.count + 2) & 0xFF)
            var header = Data([0xAA, 0x21, currentSeq, lenByte, 0x01, 0x01, serviceHi, serviceLo])
            header.append(payload)
            return [addCRC(header)]
        }
        
        // 多包模式: 尾部拼接 Payload 级 CRC-16
        let crc = crc16CCITT(payload)
        var payloadWithCRC = payload
        payloadWithCRC.append(UInt8(crc & 0xFF))
        payloadWithCRC.append(UInt8((crc >> 8) & 0xFF))
        
        var packets = [Data]()
        let totalChunks = (payloadWithCRC.count + maxChunkSize - 1) / maxChunkSize
        
        for i in 0..<totalChunks {
            let start = i * maxChunkSize
            let end = min(start + maxChunkSize, payloadWithCRC.count)
            let chunk = payloadWithCRC.subdata(in: start..<end)
            
            let lenByte = UInt8(chunk.count & 0xFF)
            let pktTot = UInt8(totalChunks & 0xFF)
            let pktSer = UInt8((i + 1) & 0xFF)
            
            var header = Data([0xAA, 0x21, currentSeq, lenByte, pktTot, pktSer, serviceHi, serviceLo])
            header.append(chunk)
            packets.append(header) // 多包子包无帧级 CRC
        }
        
        return packets
    }
    
    static func buildPacket(seq: inout UInt8, serviceHi: UInt8, serviceLo: UInt8, payload: Data) -> Data {
        let pkts = buildPackets(seq: &seq, serviceHi: serviceHi, serviceLo: serviceLo, payload: payload)
        return pkts.first ?? Data()
    }
    
    // MARK: - 1. 7-Packet Session Authentication (Service 0x8000 & 0x8020)
    
    /// 生成 7 包全链路静态 Token 鉴权序列 (100% 物理对齐 G2 官方首联鉴权规范)
    /// 生成 100% 动态 Seq/MsgId 的 Auth 7 包序列 (彻底消除二次推送时 Seq 倒退回 1~7 导致的黑屏)
    /// 100% 物理对齐 bt3.pklg Pkt #01-#04 真实官方 4 包鉴权序列
    static func buildAuthPackets(seq: inout UInt8, msgId: inout Int) -> [Data] {
        let timestamp = Int(Date().timeIntervalSince1970)
        let tsVarint = encodeVarint(timestamp)
        let txid = Data([0xE8, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01])
        
        var packets = [Data]()
        
        // Auth 1 (0x80-00) - bt3.pklg Pkt #01
        var p1 = Data([0x08, 0x04, 0x10])
        p1.append(encodeVarint(msgId))
        p1.append(Data([0x1A, 0x04, 0x08, 0x01, 0x10, 0x03]))
        packets.append(buildPacket(seq: &seq, serviceHi: 0x80, serviceLo: 0x00, payload: p1))
        msgId += 1
        
        // Auth 2 (0x80-20) - bt3.pklg Pkt #02
        var p2 = Data([0x08, 0x05, 0x10])
        p2.append(encodeVarint(msgId))
        p2.append(Data([0x22, 0x02, 0x08, 0x01]))
        packets.append(buildPacket(seq: &seq, serviceHi: 0x80, serviceLo: 0x20, payload: p2))
        msgId += 1
        
        // Auth 3 (0x80-20) - bt3.pklg Pkt #03
        var p3 = Data([0x08, 0x80, 0x01, 0x10])
        p3.append(encodeVarint(msgId))
        p3.append(Data([0x82, 0x08, 0x08, 0x08]))
        p3.append(tsVarint)
        p3.append(Data([0x10]))
        p3.append(txid)
        packets.append(buildPacket(seq: &seq, serviceHi: 0x80, serviceLo: 0x20, payload: p3))
        msgId += 1
        
        // Auth 4 (0x80-00) - bt3.pklg Pkt #04
        var p4 = Data([0x08, 0x04, 0x10])
        p4.append(encodeVarint(msgId))
        p4.append(Data([0x1A, 0x04, 0x08, 0x01, 0x10, 0x03]))
        packets.append(buildPacket(seq: &seq, serviceHi: 0x80, serviceLo: 0x00, payload: p4))
        msgId += 1
        
        return packets
    }
    
    // MARK: - 1.5 System App Focus & Touchpad Switch (Service 0x09-20)
    
    /// 生成 Service 0x09-20 前台应用聚焦与触控路由切换报文 (100% 对齐 OfficialRawPkts Pkt 21, 22)
    static func buildAppFocusPackets(seq: inout UInt8, msgId: inout Int) -> [Data] {
        var pkts = [Data]()
        
        // Pkt 1: Service 0x09-20 (Focus App)
        let p1Payload = Data([0x08, 0x02, 0x10, UInt8(msgId & 0xFF), 0x22, 0x02, 0x08, 0x01])
        msgId += 1
        pkts.append(buildPacket(seq: &seq, serviceHi: 0x09, serviceLo: 0x20, payload: p1Payload))
        
        // Pkt 2: Service 0x09-20 (Switch Touchpad Router)
        let p2Payload = Data([0x08, 0x02, 0x10, UInt8(msgId & 0xFF), 0x22, 0x02, 0x08, 0x01])
        msgId += 1
        pkts.append(buildPacket(seq: &seq, serviceHi: 0x09, serviceLo: 0x20, payload: p2Payload))
        
        return pkts
    }
    
    /// 生成 Service 0x09-20 单包 UI Route Switch 报文
    static func buildRouteSwitch(seq: inout UInt8, msgId: Int) -> Data {
        let payload = Data([0x08, 0x02, 0x10, UInt8(msgId & 0xFF), 0x22, 0x02, 0x08, 0x01])
        return buildPacket(seq: &seq, serviceHi: 0x09, serviceLo: 0x20, payload: payload)
    }
    
    // MARK: - 2. Display Config (Service 0x0E-20)
    
    /// 物理显示面板校准配置 (官方基线 106 字节 Hex 串)
    static func buildDisplayConfig(seq: inout UInt8, msgId: Int) -> Data {
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
        payload.append(encodeVarint(msgId))
        payload.append(Data([0x22]))
        payload.append(encodeVarint(configBytes.count))
        payload.append(configBytes)
        
        return buildPacket(seq: &seq, serviceHi: 0x0E, serviceLo: 0x20, payload: payload)
    }
    
    /// 100% 物理对齐 bt3.pklg 抓包: 生成 Service 0x07-20 / 0x03-20 / 0x0C-20 系统全局路由器注册前置帧列表
    static func buildSystemSetupPackets(seq: inout UInt8, msgId: inout Int) -> [Data] {
        var pkts: [Data] = []
        
        // 1. Service 0x07-20 (bt3.pklg 包 #05)
        let s07Payload: [UInt8] = [
            0x08, 0x0A,
            0x10, UInt8(msgId & 0x7F),
            0x6A, 0x06, 0x08, 0x00, 0x10, 0x50, 0x20, 0x00
        ]
        msgId += 1
        pkts.append(buildPacket(seq: &seq, serviceHi: 0x07, serviceLo: 0x20, payload: Data(s07Payload)))
        
        // 2. Service 0x03-20 (bt3.pklg 包 #06)
        let s03Payload: [UInt8] = [
            0x08, 0x00,
            0x10, UInt8(msgId & 0x7F),
            0x1A, 0x33,
            0x08, 0x08, 0x12, 0x04, 0x08, 0x00, 0x20, 0x04,
            0x12, 0x04, 0x08, 0x00, 0x20, 0x0B, 0x12, 0x04, 0x08, 0x00, 0x20, 0x06,
            0x12, 0x04, 0x08, 0x00, 0x20, 0x05, 0x12, 0x04, 0x08, 0x00, 0x20, 0x08,
            0x12, 0x04, 0x08, 0x00, 0x20, 0x07, 0x12, 0x04, 0x08, 0x00, 0x20, 0x01,
            0x12, 0x05, 0x08, 0x00, 0x20, 0x8A, 0x02
        ]
        msgId += 1
        pkts.append(buildPacket(seq: &seq, serviceHi: 0x03, serviceLo: 0x20, payload: Data(s03Payload)))
        
        // 3. Service 0x0C-20 (bt3.pklg 包 #07) — 激活 Display 显示通道
        let s0cPayload: [UInt8] = [
            0x08, 0x02,
            0x10, UInt8(msgId & 0x7F),
            0x22, 0x04, 0x08, 0x01, 0x10, 0x00
        ]
        msgId += 1
        pkts.append(buildPacket(seq: &seq, serviceHi: 0x0C, serviceLo: 0x20, payload: Data(s0cPayload)))
        
        // 4. Service 0x30-20 (bt3.pklg 包 #08) — 系统模式切换与权限响应
        let s30Payload: [UInt8] = [
            0x08, 0x01,
            0x10, UInt8(msgId & 0x7F),
            0x1A, 0x04, 0x08, 0x01, 0x10, 0x00
        ]
        msgId += 1
        pkts.append(buildPacket(seq: &seq, serviceHi: 0x30, serviceLo: 0x20, payload: Data(s30Payload)))
        
        // 5. Service 0x0D-20 (bt3.pklg 包 #09) — 状态同步指示
        let s0dPayload: [UInt8] = [
            0x08, 0x00
        ]
        pkts.append(buildPacket(seq: &seq, serviceHi: 0x0D, serviceLo: 0x20, payload: Data(s0dPayload)))
        
        // 6. Service 0x1F-20 (bt3.pklg 包 #10) — 系统焦点状态绑定 (注册触控中断)
        let s1fPayload: [UInt8] = [
            0x08, 0x00,
            0x10, UInt8(msgId & 0x7F),
            0x1A, 0x02, 0x08, 0x00
        ]
        msgId += 1
        pkts.append(buildPacket(seq: &seq, serviceHi: 0x1F, serviceLo: 0x20, payload: Data(s1fPayload)))
        
        // 7. Service 0x10-20 (bt3.pklg 包 #11) — App 界面挂载通知
        let s10Payload: [UInt8] = [
            0x08, 0x01,
            0x10, UInt8(msgId & 0x7F),
            0x1A, 0x02, 0x08, 0x01
        ]
        msgId += 1
        pkts.append(buildPacket(seq: &seq, serviceHi: 0x10, serviceLo: 0x20, payload: Data(s10Payload)))
        
        return pkts
    }
    
    // MARK: - 3. Teleprompter Init (Service 0x06-20 type=1)
    
    /// 物理屏显提词器初始化 (100% 对齐 bt3.pklg 抓包: 0x48 0x01 开启 Touchpad 触控板手势监听)
    static func buildTeleprompterInit(seq: inout UInt8, msgId: Int, scrollModeAI: Bool = true) -> [Data] {
        let modeByte: UInt8 = 0x01 // 恒定 0x01 (物理抓包 bt3.pklg 包 #98 对齐: 使能 Touchpad 触控板手势监听)
        
        let display = Data([
            0x08, 0x00,        // field 1
            0x10, 0x00,        // field 2
            0x18, 0x00,        // field 3
            0x20, 59,          // field 4: display_width = 59
            0x28, 0xC9, 0x04,  // field 5: content_height = 585
            0x30, 0xB7, 0x04,  // field 6: line_height = 567
            0x38, 0xA9, 0x18,  // field 7: viewport_height = 3113
            0x40, 0x00,        // field 8: font_size = 0
            0x48, modeByte,    // field 9: scroll_mode (1: AI, 0: Manual)
            0x50, 0x09,        // field 10: render_mode = 9 (全屏)
            0x58, 0x00         // field 11 = 0
        ])
        
        var settings = Data([0x08, 0x01, 0x12])
        settings.append(encodeVarint(display.count))
        settings.append(display)
        
        var payload = Data([0x08, 0x01, 0x10])
        payload.append(encodeVarint(msgId))
        payload.append(Data([0x1A]))
        payload.append(encodeVarint(settings.count))
        payload.append(settings)
        
        return buildPackets(seq: &seq, serviceHi: 0x06, serviceLo: 0x20, payload: payload)
    }
    
    /// §25 官方按需下发 V2: 支持动态 field_4 (totalPages) 和 field_5 (totalLines)
    /// 初始化时向 MCU 固件透传规范参数 (field 10 严格固定为 0x09 官方渲染模式)
    static func buildTeleprompterInitV2(seq: inout UInt8, msgId: Int, totalPages: Int, totalLines: Int, scrollModeAI: Bool = true) -> [Data] {
        let modeByte: UInt8 = 0x01
        
        var display = Data([
            0x08, 0x00,        // field 1
            0x10, 0x00,        // field 2
            0x18, 0x00         // field 3
        ])
        display.append(Data([0x20]))              // field 4: totalPages
        display.append(encodeVarint(totalPages))
        display.append(Data([0x28]))              // field 5: totalLines
        display.append(encodeVarint(totalLines))
        display.append(Data([0x30, 0xB7, 0x04]))  // field 6: line_height = 567
        display.append(Data([0x38, 0xA9, 0x18]))  // field 7: viewport_height = 3113 (硬件物理屏幕视口高度 = 5.5 行 * 567)
        display.append(Data([0x40, 0x00]))         // field 8: font_size = 0
        display.append(Data([0x48, modeByte]))     // field 9: scroll_mode
        display.append(Data([0x50, 0x09]))         // field 10: render_mode = 9 (官方标准全屏渲染模式)
        display.append(Data([0x58, 0x00]))         // field 11 = 0
        
        var settings = Data([0x08, 0x01, 0x12])
        settings.append(encodeVarint(display.count))
        settings.append(display)
        
        var payload = Data([0x08, 0x01, 0x10])
        payload.append(encodeVarint(msgId))
        payload.append(Data([0x1A]))
        payload.append(encodeVarint(settings.count))
        payload.append(settings)
        
        return buildPackets(seq: &seq, serviceHi: 0x06, serviceLo: 0x20, payload: payload)
    }
    
    /// §25 官方按需下发 V2: 构建 TeleprompterComplete (type=255) 终止帧
    /// 官方 APP 在所有 Content Page 发完后发送此帧，显式告知固件传输结束
    /// multiprompts.pklg 物理抓包: 08 FF 01 10 [MsgId] 6A 04 08 00 10 04
    static func buildTeleprompterComplete(seq: inout UInt8, msgId: Int) -> Data {
        var payload = Data([0x08, 0xFF, 0x01, 0x10])  // type = 255 (varint: FF 01)
        payload.append(encodeVarint(msgId))
        payload.append(Data([0x6A, 0x04, 0x08, 0x00, 0x10, 0x04]))  // field_13 = {f1=0, f2=4}
        return buildPacket(seq: &seq, serviceHi: 0x06, serviceLo: 0x20, payload: payload)
    }
    
    // MARK: - 4. Teleprompter Content Page (Service 0x06-20 type=3)
    
    /// 生成单个 Content 页面分包列表 (field_2 严格反映当前页面文本的实际行数)
    static func buildContentPagePackets(seq: inout UInt8, msgId: Int, pageNum: Int, text: String) -> [Data] {
        guard let textBytes = text.data(using: .utf8) else { return [] }
        let lineCount = text.filter({ $0 == "\n" }).count + 1
        
        var inner = Data([0x08])
        inner.append(encodeVarint(pageNum))
        inner.append(Data([0x10]))
        inner.append(encodeVarint(lineCount))
        inner.append(Data([0x1A]))
        inner.append(encodeVarint(textBytes.count))
        inner.append(textBytes)
        
        var content = Data([0x2A])
        content.append(encodeVarint(inner.count))
        content.append(inner)
        
        var payload = Data([0x08, 0x03, 0x10])
        payload.append(encodeVarint(msgId))
        payload.append(content)
        
        return buildPackets(seq: &seq, serviceHi: 0x06, serviceLo: 0x20, payload: payload)
    }

    // MARK: - 5. Route Switch & Sync (Service 08000 & 0920)
    
    static func buildDashboardSync(seq: inout UInt8, msgId: Int) -> Data {
        var payload = Data([0x08, 0x0E, 0x10])
        payload.append(encodeVarint(msgId))
        payload.append(Data([0x6A, 0x00]))
        return buildPacket(seq: &seq, serviceHi: 0x80, serviceLo: 0x00, payload: payload)
    }
    
    /// 触发 Service 0x80-00 Render Commit 渲染提交信号 (Pkt 42 对齐: MCU 收到后将已接收的 Page 数据一次性渲染至 MicroLED)
    static func buildFlushCommit(seq: inout UInt8, msgId: Int) -> Data {
        let payload = Data([
            0x08, 0x0E,
            0x10, UInt8(msgId & 0x7F),
            0x6A, 0x00
        ])
        return buildPacket(seq: &seq, serviceHi: 0x80, serviceLo: 0x00, payload: payload)
    }
    

    
    /// 触发 0x01-20 系统手势与 App 布局路由绑定 (100% 物理抓包 bt3.pklg 包 #100 对齐)
    static func buildSystemLayoutConfig(seq: inout UInt8, msgId: Int) -> Data {
        var payload = Data([0x08, 0x02, 0x10])
        payload.append(encodeVarint(msgId))
        let hexStr = "22171215080410031a0301020320042a040103020230003801"
        var hexData = Data()
        var tempHex = hexStr
        while !tempHex.isEmpty {
            let sub = tempHex.prefix(2)
            tempHex = String(tempHex.dropFirst(2))
            if let b = UInt8(sub, radix: 16) {
                hexData.append(b)
            }
        }
        payload.append(hexData)
        return buildPacket(seq: &seq, serviceHi: 0x01, serviceLo: 0x20, payload: payload)
    }
    
    /// 生成 Service 0x01-20 前台活跃心跳锁 (100% 对齐 §16.2 物理抓包: 唤醒 Touchpad 物理中断并派发至 06-01 通道)
    static func buildActiveFocusLock(seq: inout UInt8, msgId: Int) -> Data {
        var payload = Data([0x08, 0x02, 0x10])
        payload.append(encodeVarint(msgId))
        let lockBytes: [UInt8] = [
            0x22, 0x0A,
            0x1A, 0x08,
            0x12, 0x06,
            0x12, 0x04, 0x08, 0x01
        ]
        payload.append(contentsOf: lockBytes)
        return buildPacket(seq: &seq, serviceHi: 0x01, serviceLo: 0x20, payload: payload)
    }
    
    /// 100% 物理对齐 bt3.pklg 抓包包 #18: 生成 Touchpad 手势监听配置报文 (Service 0x01-20, msg_id=0x13)
    static func buildTouchpadEventListener(seq: inout UInt8, msgId: Int = 0x13) -> Data {
        var payload = Data([0x08, 0x02, 0x10])
        payload.append(encodeVarint(msgId))
        
        // 物理 Payload: 22 0C 1A 0A 12 08 1A 06 08 00 10 00 20 01
        let listenerBytes: [UInt8] = [
            0x22, 0x0C,
            0x1A, 0x0A,
            0x12, 0x08,
            0x1A, 0x06,
            0x08, 0x00,
            0x10, 0x00,
            0x20, 0x01  // enable_touchpad_listener = true
        ]
        payload.append(contentsOf: listenerBytes)
        return buildPacket(seq: &seq, serviceHi: 0x01, serviceLo: 0x20, payload: payload)
    }
    
    // MARK: - Hardware Touch Activation (bt3.pklg / bt.pklg)
    
    /// 生成 Service 0x0E-20 GPU 显存纹理分配报文 (100% 对齐 bt.pklg 帧 #24/#28/#32)
    static func buildPktTextureAlloc0E(seq: inout UInt8, msgId: Int) -> Data {
        var payload = Data([0x08, 0x02, 0x10])
        payload.append(encodeVarint(msgId))
        let hexStr = "228a0108011215080210904e1d0000000025000000002800300038001215080310904e1d0000000025000000002800300038001215080410904e1d0000000025000000002800300038001215080510904e1d0000000025000000002800300038001215080610904e1d0000000025000000002800300038001215080910904e1d000000002500000000280030003800"
        var hexData = Data()
        var tempHex = hexStr
        while !tempHex.isEmpty {
            let sub = tempHex.prefix(2)
            tempHex = String(tempHex.dropFirst(2))
            if let b = UInt8(sub, radix: 16) {
                hexData.append(b)
            }
        }
        payload.append(hexData)
        return buildPacket(seq: &seq, serviceHi: 0x0E, serviceLo: 0x20, payload: payload)
    }
    
    /// 生成 Service 0x04-20 HUD 视口渲染容器挂载报文 (100% 对齐 bt3.pklg Pkt 40)
    static func buildPkt40HUDMount(seq: inout UInt8, msgId: Int) -> Data {
        var payload = Data([0x08, 0x01, 0x10])
        payload.append(encodeVarint(msgId))
        payload.append(Data([0x1A, 0x08, 0x08, 0x00, 0x10, 0x00, 0x18, 0x00, 0x28, 0x01]))
        return buildPacket(seq: &seq, serviceHi: 0x04, serviceLo: 0x20, payload: payload)
    }
    
    /// 生成 Service 0x09-20 三路 Touchpad 手势路由绑定报文 (100% 对齐 bt3.pklg Pkt 41, 含完整 0/1/2 号路由表)
    static func buildPkt41TouchpadRouter(seq: inout UInt8, msgId: Int) -> Data {
        var payload = Data([0x08, 0x01, 0x10])
        payload.append(encodeVarint(msgId))
        // 完整 3 路 Touchpad 路由表 (将 0/1/2 号手势路由全部绑定到提词前台)
        payload.append(Data([
            0x1A, 0x1A, 0x52, 0x18,
            0x0A, 0x06, 0x08, 0x00, 0x10, 0x00, 0x18, 0x00,
            0x0A, 0x06, 0x08, 0x00, 0x10, 0x01, 0x18, 0x00,
            0x0A, 0x06, 0x08, 0x00, 0x10, 0x02, 0x18, 0x00
        ]))
        return buildPacket(seq: &seq, serviceHi: 0x09, serviceLo: 0x20, payload: payload)
    }
    
    /// 生成 Service 0x1F-20 触控板物理中断使能报文 (100% 对齐 bt3.pklg Pkt 10, enable=1)
    static func buildPkt42TouchpadInterruptEnable(seq: inout UInt8, msgId: Int) -> Data {
        var payload = Data([0x08, 0x00, 0x10])
        payload.append(encodeVarint(msgId))
        payload.append(Data([0x1A, 0x02, 0x08, 0x01]))
        return buildPacket(seq: &seq, serviceHi: 0x1F, serviceLo: 0x20, payload: payload)
    }
    
    /// 生成 1:1 官方原装 11 包前置 Setup 信令 (对齐 bt3.pklg Pkts 5~15: 建立 10 行 Canvas 画布、App 容器与 Touchpad 中断)
    static func buildOfficialSetupSequence(seq: inout UInt8, msgId: inout Int) -> [(data: Data, desc: String)] {
        var result: [(Data, String)] = []
        
        // 1. Service 07-20 Viewport 容器
        var p07 = Data([0x08, 0x0A, 0x10])
        p07.append(encodeVarint(msgId))
        p07.append(Data([0x6A, 0x06, 0x08, 0x00, 0x10, 0x50, 0x20, 0x00]))
        result.append((buildPacket(seq: &seq, serviceHi: 0x07, serviceLo: 0x20, payload: p07), "Setup: Viewport (0x07-20)"))
        msgId += 1
        
        // 2. Service 03-20 Canvas 画布参数 (59B, 包含全屏 10 行 Layout 规格)
        var p03 = Data([0x08, 0x00, 0x10])
        p03.append(encodeVarint(msgId))
        let p03Body: [UInt8] = [
            0x1A, 0x33, 0x08, 0x08, 0x12, 0x04, 0x08, 0x00, 0x20, 0x04, 0x12, 0x04,
            0x08, 0x00, 0x20, 0x0B, 0x12, 0x04, 0x08, 0x00, 0x20, 0x06, 0x12, 0x04,
            0x08, 0x00, 0x20, 0x05, 0x12, 0x04, 0x08, 0x00, 0x20, 0x08, 0x12, 0x04,
            0x08, 0x00, 0x20, 0x07, 0x12, 0x04, 0x08, 0x00, 0x20, 0x01, 0x12, 0x05,
            0x08, 0x00, 0x20, 0x8A, 0x02
        ]
        p03.append(contentsOf: p03Body)
        result.append((buildPacket(seq: &seq, serviceHi: 0x03, serviceLo: 0x20, payload: p03), "Setup: Canvas Layout (0x03-20)"))
        msgId += 1
        
        // 3. Service 0C-20 Display 显示通道激活
        var p0C = Data([0x08, 0x02, 0x10])
        p0C.append(encodeVarint(msgId))
        p0C.append(Data([0x22, 0x04, 0x08, 0x01, 0x10, 0x00]))
        result.append((buildPacket(seq: &seq, serviceHi: 0x0C, serviceLo: 0x20, payload: p0C), "Setup: Display Channel (0x0C-20)"))
        msgId += 1
        
        // 4. Service 30-20 (跳过：发送 0x30-20 会导致眼镜 MCU 主动抛出 0x0D-01 Session Terminated 销毁画布)
        // var p30 = Data([0x08, 0x01, 0x10])
        // p30.append(encodeVarint(msgId))
        // p30.append(Data([0x1A, 0x04, 0x08, 0x01, 0x10, 0x00]))
        // result.append((buildPacket(seq: &seq, serviceHi: 0x30, serviceLo: 0x20, payload: p30), "Setup: System Mode (0x30-20)"))
        // msgId += 1
        
        // 5. Service 0D-20 状态同步指示
        var p0D = Data([0x08, 0x00, 0x10])
        p0D.append(encodeVarint(msgId))
        p0D.append(Data([0x10, 0x05]))
        result.append((buildPacket(seq: &seq, serviceHi: 0x0D, serviceLo: 0x20, payload: p0D), "Setup: Status Sync (0x0D-20)"))
        msgId += 1
        
        // 6. Service 09-20 Touchpad Listener
        var p09_1 = Data([0x08, 0x01, 0x10])
        p09_1.append(encodeVarint(msgId))
        p09_1.append(Data([0x1A, 0x0C, 0x4A, 0x0A, 0x08, 0x00, 0x10, 0x00, 0x18, 0x00, 0x20, 0x00, 0x28, 0x01]))
        result.append((buildPacket(seq: &seq, serviceHi: 0x09, serviceLo: 0x20, payload: p09_1), "Setup: Touchpad Listener (0x09-20)"))
        msgId += 1
        
        // 7. Service 1F-20 焦点状态绑定
        var p1F = Data([0x08, 0x00, 0x10])
        p1F.append(encodeVarint(msgId))
        p1F.append(Data([0x1A, 0x02, 0x08, 0x01]))
        result.append((buildPacket(seq: &seq, serviceHi: 0x1F, serviceLo: 0x20, payload: p1F), "Setup: Focus State (0x1F-20)"))
        msgId += 1
        
        return result
    }
    
    // MARK: - Legacy / UI Control Helpers
    
    /// 生成 0x06-20 Type 165 手机主动平移视口同步报文 (100% 物理对齐 app-control.pklg 官方 App 抓包 Pkts #065 ~ #119)
    static func buildScrollSync(seq: inout UInt8, msgId: Int = 0x50, lineIndex: Int) -> Data {
        let page = lineIndex / 10
        let line = lineIndex % 10
        
        var inner = Data([0x08])
        inner.append(encodeVarint(page))
        inner.append(Data([0x10]))
        inner.append(encodeVarint(line))
        
        var payload = Data([0x08, 0xA5, 0x01, 0x10]) // Type 165 (0xA5 0x01): Teleprompter App Scroll Sync
        payload.append(encodeVarint(msgId))
        payload.append(Data([0x5A]))                 // Tag 11 (0x5A) 视口定位负载
        payload.append(encodeVarint(inner.count))
        payload.append(inner)
        
        return buildPacket(seq: &seq, serviceHi: 0x06, serviceLo: 0x20, payload: payload)
    }
    
    /// 生成 0x06-20 Type 6 AI 跟随模式位置同步报文
    static func buildAISync(seq: inout UInt8, msgId: Int = 0x50, lineIndex: Int) -> Data {
        let page = lineIndex / 10
        let line = lineIndex % 10
        
        var inner = Data([0x08])
        inner.append(encodeVarint(page))
        inner.append(Data([0x10]))
        inner.append(encodeVarint(line))
        inner.append(Data([0x18, 0x00]))
        
        var payload = Data([0x08, 0x06, 0x10]) // Type 6: Teleprompter AI Sync Event
        payload.append(encodeVarint(msgId))
        payload.append(Data([0x2A]))
        payload.append(encodeVarint(inner.count))
        payload.append(inner)
        
        return buildPacket(seq: &seq, serviceHi: 0x06, serviceLo: 0x20, payload: payload)
    }
    
    static func buildWakePacket(seq: inout UInt8, msgId: Int = 0x05) -> Data {
        var payload = Data([0x08, 0x01, 0x10])
        payload.append(encodeVarint(msgId))
        payload.append(Data([0x1A, 0x08, 0x08, 0x01, 0x10, 0x01, 0x18, 0x05, 0x28, 0x01]))
        return buildPacket(seq: &seq, serviceHi: 0x04, serviceLo: 0x20, payload: payload)
    }
    
    static func buildSleepPacket(seq: inout UInt8, msgId: Int = 0x06) -> Data {
        var payload = Data([0x08, 0x01, 0x10])
        payload.append(encodeVarint(msgId))
        payload.append(Data([0x1A, 0x08, 0x08, 0x01, 0x10, 0x00, 0x18, 0x05, 0x28, 0x00]))
        return buildPacket(seq: &seq, serviceHi: 0x04, serviceLo: 0x20, payload: payload)
    }
    
    /// 构造 Service 0x06-20 Type 1 (state=4) 提词视口激活与 Touchpad 滑动 Notify 解禁报文 (100% 对齐 bt2.pklg 抓包)
    static func buildTeleprompterActivateState4Packet(seq: inout UInt8, msgId: Int) -> Data {
        var payload = Data([0x08, 0x01, 0x10])
        payload.append(encodeVarint(msgId))
        payload.append(Data([0x1A, 0x02, 0x08, 0x04]))
        return buildPacket(seq: &seq, serviceHi: 0x06, serviceLo: 0x20, payload: payload)
    }
    
    static func buildEnterTeleprompterModePacket(seq: inout UInt8, msgId: Int = 0x15) -> Data {
        let stateMsg = Data([0x08, 0x01])
        var payload = Data([0x08, 0x01, 0x10])
        payload.append(encodeVarint(msgId))
        payload.append(Data([0x1A]))
        payload.append(encodeVarint(stateMsg.count))
        payload.append(stateMsg)
        return buildPacket(seq: &seq, serviceHi: 0x06, serviceLo: 0x20, payload: payload)
    }
    
    static func buildTeleprompterModeConfigPacket(seq: inout UInt8, mode: UInt8 = 0x00) -> Data {
        var payload = Data([0x08, 0x01, 0x10, 0x16, 0x48, mode])
        return buildPacket(seq: &seq, serviceHi: 0x06, serviceLo: 0x20, payload: payload)
    }
    
    /// 查询眼镜当前提词器模式与运行状态 (Service 0x06-20 Type 2 Status Query)
    static func buildQueryTeleprompterStatePacket(seq: inout UInt8, msgId: Int = 0x20) -> Data {
        var payload = Data([0x08, 0x02, 0x10])
        payload.append(encodeVarint(msgId))
        payload.append(Data([0x22, 0x02, 0x08, 0x01]))
        return buildPacket(seq: &seq, serviceHi: 0x06, serviceLo: 0x20, payload: payload)
    }
    
    // MARK: - Text Formatting Helper
    
    static func getCharWidth(_ char: Character) -> Int {
        for scalar in char.unicodeScalars {
            if scalar.value > 0x7F { return 2 }
        }
        return 1
    }
    
    /// 将文本切分为 28 中文字符/行、10 行/页的数组 (硬性填满 G2 固件要求的 14 页 Buffer 槽位 §16.1)
    static func formatTextToPages(_ text: String, maxLineWidth: Int = 56, linesPerPage: Int = 10, targetPageCount: Int = 14) -> [String] {
        let cleanText = text.replacingOccurrences(of: "\\n", with: "\n")
        var wrappedLines = [String]()
        
        let paragraphs = cleanText.components(separatedBy: "\n")
        for para in paragraphs {
            if para.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                wrappedLines.append("")
                continue
            }
            var currentLine = ""
            var currentWidth = 0
            for char in para {
                let w = getCharWidth(char)
                if currentWidth + w > maxLineWidth {
                    wrappedLines.append(currentLine)
                    currentLine = String(char)
                    currentWidth = w
                } else {
                    currentLine.append(char)
                    currentWidth += w
                }
            }
            if !currentLine.isEmpty {
                wrappedLines.append(currentLine)
            }
        }
        
        if wrappedLines.isEmpty {
            wrappedLines = [text]
        }
        
        var pages = [String]()
        for i in stride(from: 0, to: wrappedLines.count, by: linesPerPage) {
            let end = min(i + linesPerPage, wrappedLines.count)
            var chunk = Array(wrappedLines[i..<end])
            while chunk.count < linesPerPage {
                chunk.append("")
            }
            pages.append(chunk.joined(separator: "\n"))
        }
        
        // 保守策略: 虽然固件接受按需下发 (§16.1/§19.3 真机验证)，但补满 14 页 Buffer 槽位可确保各固件版本最大兼容性
        let emptyPageText = Array(repeating: "", count: linesPerPage).joined(separator: "\n")
        while pages.count < targetPageCount {
            pages.append(emptyPageText)
        }
        
        return pages
    }
    
    /// §25 官方按需下发 V2: 按实际内容切分页面，不补满 14 页
    /// 最后一页的 line_count 反映真实行数（官方 APP 行为）
    /// §25 官方按需下发 V2: 按硬件标准 8 行/页切分，防止 MCU 自动补齐引发文本截断
    static func formatTextToPagesOnDemand(_ text: String, maxLineWidth: Int = 56, linesPerPage: Int = 10) -> (pages: [String], totalLines: Int) {
        let cleanText = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
        
        var wrappedLines = [String]()
        let paragraphs = cleanText.components(separatedBy: "\n")
        for para in paragraphs {
            let trimmed = para.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue } // 过滤空段落，消除提词器屏幕空白行
            
            var currentLine = ""
            var currentWidth = 0
            for char in trimmed {
                let w = getCharWidth(char)
                if currentWidth + w > maxLineWidth {
                    wrappedLines.append(currentLine)
                    currentLine = String(char)
                    currentWidth = w
                } else {
                    currentLine.append(char)
                    currentWidth += w
                }
            }
            if !currentLine.isEmpty {
                wrappedLines.append(currentLine)
            }
        }
        
        if wrappedLines.isEmpty {
            wrappedLines = [text]
        }
        
        let totalLines = wrappedLines.count
        var pages = [String]()
        let blePageCapacity = max(linesPerPage, 1)
        for i in stride(from: 0, to: wrappedLines.count, by: blePageCapacity) {
            let end = min(i + blePageCapacity, wrappedLines.count)
            let chunk = Array(wrappedLines[i..<end])
            pages.append(chunk.joined(separator: "\n"))
        }
        
        return (pages, totalLines)
    }
    
    // MARK: - Position Notification Parser (Service 0x06-01)
    
    struct PositionNotification {
        let eventType: UInt32
        let currentLine: Int
        let pageId: Int
        let rawLine: Int
    }
    
    /// 从眼镜 Notify 数据帧中解调 0x0601 位置与手势变更通知 (支持 Type 164 / 165 / 167)
    static func parsePositionNotification(from rawFrame: Data) -> PositionNotification? {
        guard rawFrame.count >= 10,
              rawFrame[0] == 0xAA,
              rawFrame[1] == 0x12,
              rawFrame[6] == 0x06,
              rawFrame[7] == 0x01 else {
            return nil
        }
        
        let payload = rawFrame.subdata(in: 8..<rawFrame.count)
        guard payload.count >= 3, payload[0] == 0x08 else { return nil }
        
        let eventType = UInt32(payload[1]) // 164 (0xA4), 165 (0xA5), 167 (0xA7)
        var pageNum = 0
        var lineNum = 0
        var hasPositionData = false
        
        if eventType == 165 { // Type 165 (0xA5): 触控板滑动通知 (Tag 11 / 0x5A)
            if let idx5A = payload.range(of: Data([0x5A]))?.lowerBound {
                let p = idx5A + 1
                if p < payload.count {
                    let subLen = Int(payload[p])
                    let subData = payload.subdata(in: (p+1)..<min(p+1+subLen, payload.count))
                    var i = 0
                    while i < subData.count {
                        if subData[i] == 0x08 && i + 1 < subData.count {
                            pageNum = Int(subData[i+1])
                            i += 2
                        } else if subData[i] == 0x10 && i + 1 < subData.count {
                            lineNum = Int(subData[i+1])
                            i += 2
                        } else {
                            i += 1
                        }
                    }
                    hasPositionData = true
                }
            }
        } else if eventType == 164 { // Type 164 (0xA4): 页面装载确认 (Tag 10 / 0x52)
            if let idx52 = payload.range(of: Data([0x52]))?.lowerBound {
                let p = idx52 + 1
                if p < payload.count {
                    let subLen = Int(payload[p])
                    let subData = payload.subdata(in: (p+1)..<min(p+1+subLen, payload.count))
                    if subData.count >= 2 && subData[0] == 0x08 {
                        pageNum = Int(subData[1])
                        hasPositionData = true
                    }
                }
            }
        } else if eventType == 167 { // Type 167 (0xA7): 翻页触底触发 (Tag 14 / 0x72)
            if let idx72 = payload.range(of: Data([0x72]))?.lowerBound {
                let p = idx72 + 1
                if p < payload.count {
                    let subLen = Int(payload[p])
                    let subData = payload.subdata(in: (p+1)..<min(p+1+subLen, payload.count))
                    if subData.count >= 2 && subData[0] == 0x10 {
                        pageNum = Int(subData[1])
                        hasPositionData = true
                    }
                }
            }
        }
        
        if hasPositionData {
            let absLine = pageNum * 10 + lineNum
            return PositionNotification(
                eventType: eventType,
                currentLine: absLine,
                pageId: pageNum,
                rawLine: lineNum
            )
        }
        
        return nil
    }
}
