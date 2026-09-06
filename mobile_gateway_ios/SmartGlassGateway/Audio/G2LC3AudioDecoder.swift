//
//  G2LC3AudioDecoder.swift
//  SmartGlassGateway
//
//  Created by Antigravity on 2026-09-06.
//

import Foundation
import AVFoundation
import LC3

/// Even G2 智能眼镜专用的 LC3 音频解码器
///
/// 固件规格：
/// - 每个 6402 包固定 205 字节
/// - 包含 5 帧 10ms 的 LC3 编码音频（每帧 40 字节，32kbps，16kHz 单声道）
/// - Byte 200..203 为保留字节
/// - Byte 204 为单字节递增序列号 (0..255)，用于链路丢包遥测
/// - 每个包解码出 5 × 160 = 800 个采样点 (50ms PCM 连续音频)
final class G2LC3AudioDecoder {
    
    // MARK: - LC3 Constants
    static let frameDurationUs: Int32 = 10000 // 10ms
    static let sampleRateHz: Int32 = 16000    // 16kHz
    static let samplesPerFrame: Int = 160     // 10ms * 16kHz = 160 samples
    static let framesPerPacket: Int = 5       // 5 frames per 205B packet
    static let frameByteLength: Int = 40      // 40 bytes per LC3 frame
    static let packetByteLength: Int = 205    // G2 fixed audio packet length
    
    // MARK: - Properties
    let audioFormat: AVAudioFormat
    
    private var decoderMem: UnsafeMutableRawPointer?
    private var decoder: lc3_decoder_t?
    
    private var lastSequenceNumber: UInt8?
    private(set) var totalPacketsDecoded: Int = 0
    private(set) var lostPacketsDetected: Int = 0
    
    // MARK: - Initialization
    init?() {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(Self.sampleRateHz),
            channels: 1,
            interleaved: false
        ) else {
            return nil
        }
        self.audioFormat = format
        
        let decSize = lc3_decoder_size(Self.frameDurationUs, Self.sampleRateHz)
        guard decSize > 0 else { return nil }
        
        let mem = UnsafeMutableRawPointer.allocate(byteCount: Int(decSize), alignment: 8)
        guard let dec = lc3_setup_decoder(Self.frameDurationUs, Self.sampleRateHz, Self.sampleRateHz, mem) else {
            mem.deallocate()
            return nil
        }
        
        self.decoderMem = mem
        self.decoder = dec
    }
    
    deinit {
        if let mem = decoderMem {
            mem.deallocate()
            decoderMem = nil
        }
    }
    
    // MARK: - State Management
    func reset() {
        lastSequenceNumber = nil
        totalPacketsDecoded = 0
        lostPacketsDetected = 0
        if let mem = decoderMem {
            self.decoder = lc3_setup_decoder(Self.frameDurationUs, Self.sampleRateHz, Self.sampleRateHz, mem)
        }
    }
    
    // MARK: - Packet Decoding
    
    /// 将 6402 接收到的 205 字节音频数据包解码为 800 个采样的 PCM 音频缓冲区 (50ms @ 16kHz Float32)
    /// - Parameter packetData: 来自 6402 特征值的原始 Data
    /// - Returns: 解码出的 AVAudioPCMBuffer，若包格式不正确则返回 nil
    func decodePacket(_ packetData: Data) -> AVAudioPCMBuffer? {
        guard packetData.count == Self.packetByteLength, let decoder = decoder else {
            return nil
        }
        
        // 1. 序列号与丢包检测
        let currentSeq = packetData[Self.packetByteLength - 1] // Byte 204
        if let lastSeq = lastSequenceNumber {
            let diff = (Int(currentSeq) - Int(lastSeq)) & 0xFF
            if diff > 1 && diff < 30 {
                // 发生跳帧丢包 (容忍正常回绕)
                let lost = diff - 1
                lostPacketsDetected += lost
            }
        }
        lastSequenceNumber = currentSeq
        totalPacketsDecoded += 1
        
        // 2. 创建 800 个采样点的 PCM 缓冲区
        let totalSamples = Self.samplesPerFrame * Self.framesPerPacket
        guard let pcmBuffer = AVAudioPCMBuffer(
            pcmFormat: audioFormat,
            frameCapacity: AVAudioFrameCount(totalSamples)
        ) else {
            return nil
        }
        pcmBuffer.frameLength = AVAudioFrameCount(totalSamples)
        guard let floatChannelData = pcmBuffer.floatChannelData?[0] else {
            return nil
        }
        
        // 3. 逐帧解码 5 个 LC3 块 (每块 40 字节 -> 160 采样)
        var frameInt16 = [Int16](repeating: 0, count: Self.samplesPerFrame)
        
        packetData.withUnsafeBytes { rawBuffer in
            guard let basePtr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            
            for frameIdx in 0..<Self.framesPerPacket {
                let frameOffset = frameIdx * Self.frameByteLength
                let framePtr = basePtr.advanced(by: frameOffset)
                
                let res = lc3_decode(
                    decoder,
                    framePtr,
                    Int32(Self.frameByteLength),
                    LC3_PCM_FORMAT_S16,
                    &frameInt16,
                    1
                )
                
                let sampleOffset = frameIdx * Self.samplesPerFrame
                if res == 0 {
                    for i in 0..<Self.samplesPerFrame {
                        floatChannelData[sampleOffset + i] = Float(frameInt16[i]) / 32768.0
                    }
                } else {
                    // 解码出现错误或校验不通过时静音
                    for i in 0..<Self.samplesPerFrame {
                        floatChannelData[sampleOffset + i] = 0.0
                    }
                }
            }
        }
        
        return pcmBuffer
    }
    
    /// 当检测到网络严重丢包时，执行 LC3 丢包隐藏算法 (Packet Loss Concealment, PLC)
    /// 输出 1 帧 (160 采样) 的平滑插值 PCM
    func decodeLossConcealmentFrame() -> [Float] {
        guard let decoder = decoder else {
            return [Float](repeating: 0, count: Self.samplesPerFrame)
        }
        
        var frameInt16 = [Int16](repeating: 0, count: Self.samplesPerFrame)
        // 在 Google liblc3 中，传入 NULL (nil) 指针即触发 PLC 解码
        _ = lc3_decode(
            decoder,
            nil,
            0,
            LC3_PCM_FORMAT_S16,
            &frameInt16,
            1
        )
        
        var floatOut = [Float](repeating: 0, count: Self.samplesPerFrame)
        for i in 0..<Self.samplesPerFrame {
            floatOut[i] = Float(frameInt16[i]) / 32768.0
        }
        return floatOut
    }
}
