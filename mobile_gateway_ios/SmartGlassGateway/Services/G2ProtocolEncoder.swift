import Foundation



/// Even G2 智能眼镜 BLE 协议二进制编码器 (针对 G2 提词器五步推屏规范)
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
    
    // MARK: - CRC16 CCITT (0xFFFF, 0x1021)
    
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
    
    /// 给裸数据包增加 2 字节小端 CRC16 校验尾部
    static func addCRC(_ packet: Data) -> Data {
        guard packet.count >= 8 else { return packet }
        let payloadToCRC = packet.subdata(in: 8..<packet.count)
        let crc = crc16CCITT(payloadToCRC)
        var result = packet
        result.append(UInt8(crc & 0xFF))
        result.append(UInt8((crc >> 8) & 0xFF))
        return result
    }
    
    /// 支持 BLE ATT MTU 分片的物理封包器 (单包 Payload 严格限制在 160 字节内)
    static func buildPackets(seq: inout UInt8, serviceHi: UInt8, serviceLo: UInt8, payload: Data, maxChunkSize: Int = 160) -> [Data] {
        if payload.count <= maxChunkSize {
            let lenByte = UInt8((payload.count + 2) & 0xFF)
            var header = Data([0xAA, 0x21, seq, lenByte, 0x01, 0x01, serviceHi, serviceLo])
            header.append(payload)
            seq &+= 1
            return [addCRC(header)]
        }
        
        var packets = [Data]()
        let totalChunks = (payload.count + maxChunkSize - 1) / maxChunkSize
        
        for i in 0..<totalChunks {
            let start = i * maxChunkSize
            let end = min(start + maxChunkSize, payload.count)
            let chunk = payload.subdata(in: start..<end)
            
            let lenByte = UInt8((chunk.count + 2) & 0xFF)
            let pktTot = UInt8(totalChunks & 0xFF)
            let pktSer = UInt8((i + 1) & 0xFF)
            
            var header = Data([0xAA, 0x21, seq, lenByte, pktTot, pktSer, serviceHi, serviceLo])
            header.append(chunk)
            packets.append(addCRC(header))
            seq &+= 1 // 每个物理 BLE 帧的 Sequence 必须依次递增！
        }
        
        return packets
    }
    
    static func buildPacket(seq: UInt8, serviceHi: UInt8, serviceLo: UInt8, payload: Data) -> Data {
        var dummySeq = seq
        let pkts = buildPackets(seq: &dummySeq, serviceHi: serviceHi, serviceLo: serviceLo, payload: payload)
        return pkts.first ?? Data()
    }
    
    // MARK: - 1. 7-Packet Session Authentication (Service 0x8000 & 0x8020)
    
    /// 生成标准 7 包 Session 鉴权序列
    static func buildAuthPackets() -> [Data] {
        let timestamp = Int(Date().timeIntervalSince1970)
        let tsVarint = encodeVarint(timestamp)
        let txid = Data([0xE8, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01])
        
        var packets = [Data]()
        
        // Auth 1: Capability query
        packets.append(addCRC(Data([
            0xAA, 0x21, 0x01, 0x0C, 0x01, 0x01, 0x80, 0x00,
            0x08, 0x04, 0x10, 0x0C, 0x1A, 0x04, 0x08, 0x01, 0x10, 0x04
        ])))
        
        // Auth 2: Capability response request
        packets.append(addCRC(Data([
            0xAA, 0x21, 0x02, 0x0A, 0x01, 0x01, 0x80, 0x20,
            0x08, 0x05, 0x10, 0x0E, 0x22, 0x02, 0x08, 0x02
        ])))
        
        // Auth 3: Time sync with transaction ID
        var p3Payload = Data([0x08, 0x80, 0x01, 0x10, 0x0F, 0x82, 0x08, 0x11, 0x08])
        p3Payload.append(tsVarint)
        p3Payload.append(Data([0x10]))
        p3Payload.append(txid)
        let p3Len = UInt8((p3Payload.count + 2) & 0xFF)
        var p3Header = Data([0xAA, 0x21, 0x03, p3Len, 0x01, 0x01, 0x80, 0x20])
        p3Header.append(p3Payload)
        packets.append(addCRC(p3Header))
        
        // Auth 4: Capability exchange
        packets.append(addCRC(Data([
            0xAA, 0x21, 0x04, 0x0C, 0x01, 0x01, 0x80, 0x00,
            0x08, 0x04, 0x10, 0x10, 0x1A, 0x04, 0x08, 0x01, 0x10, 0x04
        ])))
        
        // Auth 5: Capability exchange
        packets.append(addCRC(Data([
            0xAA, 0x21, 0x05, 0x0C, 0x01, 0x01, 0x80, 0x00,
            0x08, 0x04, 0x10, 0x11, 0x1A, 0x04, 0x08, 0x01, 0x10, 0x04
        ])))
        
        // Auth 6: Final capability
        packets.append(addCRC(Data([
            0xAA, 0x21, 0x06, 0x0A, 0x01, 0x01, 0x80, 0x20,
            0x08, 0x05, 0x10, 0x12, 0x22, 0x02, 0x08, 0x01
        ])))
        
        // Auth 7: Final time sync
        var p7Payload = Data([0x08, 0x80, 0x01, 0x10, 0x13, 0x82, 0x08, 0x11, 0x08])
        p7Payload.append(tsVarint)
        p7Payload.append(Data([0x10]))
        p7Payload.append(txid)
        let p7Len = UInt8((p7Payload.count + 2) & 0xFF)
        var p7Header = Data([0xAA, 0x21, 0x07, p7Len, 0x01, 0x01, 0x80, 0x20])
        p7Header.append(p7Payload)
        packets.append(addCRC(p7Header))
        
        return packets
    }
    
    /// 物理屏显唤醒指令 (Service 0x04-20, Field 2 = 1 Wake)
    static func buildWakePacket(seq: UInt8 = 0x05, msgId: Int = 0x05) -> Data {
        var payload = Data([0x08, 0x01, 0x10])
        payload.append(encodeVarint(msgId))
        payload.append(Data([0x1A, 0x08, 0x08, 0x01, 0x10, 0x01, 0x18, 0x05, 0x28, 0x01]))
        return buildPacket(seq: seq, serviceHi: 0x04, serviceLo: 0x20, payload: payload)
    }
    
    /// 物理屏显休眠指令 (Service 0x04-20, Field 2 = 0 Sleep)
    static func buildSleepPacket(seq: UInt8 = 0x06, msgId: Int = 0x06) -> Data {
        var payload = Data([0x08, 0x01, 0x10])
        payload.append(encodeVarint(msgId))
        payload.append(Data([0x1A, 0x08, 0x08, 0x01, 0x10, 0x00, 0x18, 0x05, 0x28, 0x00]))
        return buildPacket(seq: seq, serviceHi: 0x04, serviceLo: 0x20, payload: payload)
    }
    
    /// 退出提词模式指令 (Service 0x06-20 Type 4 Complete)
    static func buildExitTeleprompterModePacket(seq: UInt8 = 0x07, msgId: Int = 0x07) -> Data {
        var payload = Data([0x08, 0x04, 0x10])
        payload.append(encodeVarint(msgId))
        payload.append(Data([0x32, 0x06, 0x08, 0x00, 0x10, 0x0E, 0x18, 0x8C, 0x01]))
        return buildPacket(seq: seq, serviceHi: 0x06, serviceLo: 0x20, payload: payload)
    }
    
    /// 唤醒并切入 G2 提词器 App 前台 (标准 Protobuf 序列化: TeleprompterStart)
    static func buildEnterTeleprompterModePacket(seq: UInt8, msgId: Int) -> Data {
        let stateMsg = Data([0x08, 0x01]) // TeleprompterState: state = 1 (Active)
        var payload = Data([0x08, 0x01, 0x10])
        payload.append(encodeVarint(msgId))
        payload.append(Data([0x1A]))
        payload.append(encodeVarint(stateMsg.count))
        payload.append(stateMsg)
        return buildPacket(seq: seq, serviceHi: 0x06, serviceLo: 0x20, payload: payload)
    }
    
    // MARK: - 2. Display Config (Service 0x0E-20)
    
    static func buildDisplayConfig(seq: UInt8, msgId: Int) -> Data {
        let configHex = "08011213080210904E1D00E0944425000000002800300012130803100D0F1D00408D442500000000280030001212080410001D000088422500000000280030001212080510001D00009242250000A242280030001212080610001D0000C642250000C442280030001800"
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
        payload.append(Data([0x22, 0x6A]))
        payload.append(configBytes)
        
        return buildPacket(seq: seq, serviceHi: 0x0E, serviceLo: 0x20, payload: payload)
    }
    
    // MARK: - 3. Teleprompter Init (Service 0x06-20 type=1)
    
    static func buildTeleprompterInit(seq: UInt8, msgId: Int, totalLines: Int = 10, manualMode: Bool = true) -> Data {
        let mode: UInt8 = manualMode ? 0x00 : 0x01
        let contentHeight = max(1, (totalLines * 2665) / 140)
        
        var display = Data([0x08, 0x01, 0x10, 0x00, 0x18, 0x00, 0x20, 0x8B, 0x02, 0x28])
        display.append(encodeVarint(contentHeight))
        display.append(Data([0x30, 0xE6, 0x01, 0x38, 0x8E, 0x0A, 0x40, 0x05, 0x48, mode]))
        
        var settings = Data([0x08, 0x01, 0x12])
        settings.append(encodeVarint(display.count))
        settings.append(display)
        
        var payload = Data([0x08, 0x01, 0x10])
        payload.append(encodeVarint(msgId))
        payload.append(Data([0x1A]))
        payload.append(encodeVarint(settings.count))
        payload.append(settings)
        
        return buildPacket(seq: seq, serviceHi: 0x06, serviceLo: 0x20, payload: payload)
    }
    
    // MARK: - 4. Content Page (Service 0x06-20 type=3)
    
    static func buildContentPage(seq: UInt8, msgId: Int, pageNum: Int, text: String) -> Data {
        let formattedText = "\n" + text
        let textBytes = Data(formattedText.utf8)
        
        var inner = Data([0x08])
        inner.append(encodeVarint(pageNum))
        inner.append(Data([0x10, 0x0A, 0x1A]))
        inner.append(encodeVarint(textBytes.count))
        inner.append(textBytes)
        
        var content = Data([0x2A])
        content.append(encodeVarint(inner.count))
        content.append(inner)
        
        var payload = Data([0x08, 0x03, 0x10])
        payload.append(encodeVarint(msgId))
        payload.append(content)
        
        return buildPacket(seq: seq, serviceHi: 0x06, serviceLo: 0x20, payload: payload)
    }
    
    // MARK: - Mid-Stream Marker (Service 0x06-20 type=255)
    
    static func buildMarker(seq: UInt8, msgId: Int) -> Data {
        var payload = Data([0x08, 0xFF, 0x01, 0x10])
        payload.append(encodeVarint(msgId))
        payload.append(Data([0x6A, 0x04, 0x08, 0x00, 0x10, 0x06]))
        return buildPacket(seq: seq, serviceHi: 0x06, serviceLo: 0x20, payload: payload)
    }
    
    // MARK: - 5. Sync Trigger (Service 0x80-00 type=14)
    
    static func buildSync(seq: UInt8, msgId: Int) -> Data {
        var payload = Data([0x08, 0x0E, 0x10])
        payload.append(encodeVarint(msgId))
        payload.append(Data([0x6A, 0x00]))
        return buildPacket(seq: seq, serviceHi: 0x80, serviceLo: 0x00, payload: payload)
    }
    
    // MARK: - 6. Render Commit Trigger (Service 0x64-02: 0x80 0x00)
    
    static func buildRenderCommitPacket(seq: UInt8) -> Data {
        let payload = Data([0x80, 0x00])
        return buildPacket(seq: seq, serviceHi: 0x64, serviceLo: 0x02, payload: payload)
    }
    
    /// 配置 G2 提词器手势滚动模式 (0x00: 手动触控, 0x01: 自动滚动)
    static func buildTeleprompterModeConfigPacket(seq: UInt8 = 0x0A, mode: UInt8 = 0x00) -> Data {
        let payload = Data([0x08, 0x01, 0x10, 0x0A, 0x1A, 0x04, 0x48, mode])
        return buildPacket(seq: seq, serviceHi: 0x06, serviceLo: 0x20, payload: payload)
    }
    
    // MARK: - 7. Scroll Sync Event (Service 0x06-20 type=2)
    
    /// 生成官方 ProtoTeleprompterExt|sendTeleprompterScrollSyncEvent 滚动同步报文
    static func buildScrollSync(seq: UInt8, msgId: Int, pageLine: Int) -> Data {
        var inner = Data([0x08])
        inner.append(encodeVarint(pageLine))
        
        var content = Data([0x22])
        content.append(encodeVarint(inner.count))
        content.append(inner)
        
        var payload = Data([0x08, 0x02, 0x10])
        payload.append(encodeVarint(msgId))
        payload.append(content)
        
        return buildPacket(seq: seq, serviceHi: 0x06, serviceLo: 0x20, payload: payload)
    }
    
    // MARK: - Text Formatter (1:1 Match with Python teleprompter.py)
    
    /// 将讲稿文本按照单行 25 字符、单页 10 行切分，并强制补齐至至少 14 页画卷
    static func formatTextToPages(_ rawText: String, charsPerLine: Int = 25, linesPerPage: Int = 10) -> (pages: [String], totalLines: Int) {
        let text = rawText.replacingOccurrences(of: "\\n", with: "\n")
        var wrapped = [String]()
        
        let rawLines = text.components(separatedBy: "\n")
        for line in rawLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                wrapped.append("")
                continue
            }
            
            let words = trimmed.components(separatedBy: .whitespaces)
            var current = ""
            for word in words {
                if current.count + word.count + 1 > charsPerLine {
                    if !current.isEmpty {
                        wrapped.append(current.trimmingCharacters(in: .whitespaces))
                    }
                    current = word + " "
                } else {
                    current += word + " "
                }
            }
            if !current.trimmingCharacters(in: .whitespaces).isEmpty {
                wrapped.append(current.trimmingCharacters(in: .whitespaces))
            }
        }
        
        if wrapped.isEmpty {
            wrapped = [text]
        }
        
        while wrapped.count < linesPerPage {
            wrapped.append(" ")
        }
        
        var pages = [String]()
        for i in stride(from: 0, to: wrapped.count, by: linesPerPage) {
            var pageLines = Array(wrapped[i..<min(i + linesPerPage, wrapped.count)])
            while pageLines.count < linesPerPage {
                pageLines.append(" ")
            }
            pages.append(pageLines.joined(separator: "\n") + " \n")
        }
        
        while pages.count < 14 {
            let emptyPage = Array(repeating: " ", count: linesPerPage).joined(separator: "\n") + " \n"
            pages.append(emptyPage)
        }
        
        let totalLines = rawLines.count
        return (pages, totalLines)
    }
}
