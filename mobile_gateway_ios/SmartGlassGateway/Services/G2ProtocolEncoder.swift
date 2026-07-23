import Foundation

/// Even Realities G2 智能眼镜 BLE 协议编码器 (CRC-16/CCITT + Transport Frame)
struct G2ProtocolEncoder {
    
    /// 计算 CRC-16/CCITT 校验和 (Polynomial: 0x1021, Init: 0xFFFF)
    static func calculateCRC16(_ data: Data) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in data {
            crc ^= (UInt16(byte) << 8)
            for _ in 0..<8 {
                if (crc & 0x8000) != 0 {
                    crc = (crc << 1) ^ 0x1021
                } else {
                    crc = crc << 1
                }
            }
        }
        return crc
    }
    
    /// 包装 Transport Packet 帧 (带 Magic Header 0xAA 0x55 与 CRC16 校验和)
    /// 格式: [0xAA, 0x55, length_msb, length_lsb, cmd_type, payload..., crc_msb, crc_lsb]
    static func wrapPacket(cmdType: UInt8, payload: Data) -> Data {
        var packet = Data()
        packet.append(0xAA)
        packet.append(0x55)
        
        let length = UInt16(payload.count + 1) // payload 长度 + cmd_type 字节
        packet.append(UInt8((length >> 8) & 0xFF))
        packet.append(UInt8(length & 0xFF))
        packet.append(cmdType)
        packet.append(payload)
        
        // 计算从 length 到 payload 结尾的 CRC16
        let crcData = packet.subdata(in: 2..<packet.count)
        let crc = calculateCRC16(crcData)
        packet.append(UInt8((crc >> 8) & 0xFF))
        packet.append(UInt8(crc & 0xFF))
        
        return packet
    }
    
    /// 生成 G2 显存屏幕唤醒/亮屏指令包 (cmdType = 0x10)
    static func buildWakePacket() -> Data {
        return wrapPacket(cmdType: 0x10, payload: Data([0x01]))
    }
    
    /// 生成 G2 显存屏幕清屏/息屏指令包 (cmdType = 0x10)
    static func buildSleepPacket() -> Data {
        return wrapPacket(cmdType: 0x10, payload: Data([0x00]))
    }
    
    /// 生成 3 行 HUD 提词文本显存刷新数据帧 (cmdType = 0x20)
    static func buildTextDisplayPacket(chunk: HUDDisplayChunk) -> Data {
        var payload = Data()
        
        // Tag 1: Header / Status line
        let headerStr = chunk.headerText
        if let headerData = headerStr.data(using: .utf8) {
            payload.append(0x0A) // Field 1, wire format 2 (Length-delimited)
            payload.append(UInt8(min(headerData.count, 255)))
            payload.append(headerData.prefix(255))
        }
        
        // Tag 2: Highlighted active line
        let activeStr = chunk.highlightedLine
        if let activeData = activeStr.data(using: .utf8) {
            payload.append(0x12) // Field 2, wire format 2
            payload.append(UInt8(min(activeData.count, 255)))
            payload.append(activeData.prefix(255))
        }
        
        // Tag 3: Next line preview
        let nextStr = chunk.nextLinePreview
        if let nextData = nextStr.data(using: .utf8) {
            payload.append(0x1A) // Field 3, wire format 2
            payload.append(UInt8(min(nextData.count, 255)))
            payload.append(nextData.prefix(255))
        }
        
        return wrapPacket(cmdType: 0x20, payload: payload)
    }
}
