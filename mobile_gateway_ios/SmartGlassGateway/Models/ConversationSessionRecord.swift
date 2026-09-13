//
//  ConversationSessionRecord.swift
//  SmartGlassGateway
//
//  Created by Antigravity on 2026-09-13.
//

import Foundation

/// 单条结构化对话发言
struct ConversationUtterance: Identifiable, Codable, Equatable {
    let id: UUID
    let speaker: SpeakerIdentity
    let text: String
    let timestamp: Date
    
    init(id: UUID = UUID(), speaker: SpeakerIdentity, text: String, timestamp: Date = Date()) {
        self.id = id
        self.speaker = speaker
        self.text = text
        self.timestamp = timestamp
    }
    
    var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: timestamp)
    }
}

extension SpeakerIdentity: Codable {}

/// 对话量化统计指标
struct ConversationStats: Codable, Equatable {
    let duration: TimeInterval
    let totalWords: Int
    let myWords: Int
    let guestWords: Int
    let myRatio: Double
    let guestRatio: Double
    let turnCount: Int
    
    var formattedDuration: String {
        let mins = Int(duration) / 60
        let secs = Int(duration) % 60
        return String(format: "%02d分%02d秒", mins, secs)
    }
    
    static func calculate(startTime: Date, endTime: Date, utterances: [ConversationUtterance]) -> ConversationStats {
        let duration = max(1.0, endTime.timeIntervalSince(startTime))
        var myWordCount = 0
        var guestWordCount = 0
        
        for u in utterances {
            let count = u.text.count
            if u.speaker == .me {
                myWordCount += count
            } else {
                guestWordCount += count
            }
        }
        
        let total = myWordCount + guestWordCount
        let myRatio = total > 0 ? Double(myWordCount) / Double(total) : 0.5
        let guestRatio = total > 0 ? Double(guestWordCount) / Double(total) : 0.5
        
        return ConversationStats(
            duration: duration,
            totalWords: total,
            myWords: myWordCount,
            guestWords: guestWordCount,
            myRatio: myRatio,
            guestRatio: guestRatio,
            turnCount: utterances.count
        )
    }
}

/// AI 智能总结结构体
struct ConversationSummary: Codable, Equatable {
    let topic: String
    let takeaways: [String]
    let actionItems: [String]
    let generatedAt: Date
    
    var markdownReport: String {
        var md = "# 对话纪要与核心总结\n\n"
        md += "**核心主题**：\(topic)\n\n"
        
        if !takeaways.isEmpty {
            md += "## 💡 核心共识与要点\n"
            for (idx, item) in takeaways.enumerated() {
                md += "\(idx + 1). \(item)\n"
            }
            md += "\n"
        }
        
        if !actionItems.isEmpty {
            md += "## 📋 待办事项与下一步行动\n"
            for item in actionItems {
                md += "- [ ] \(item)\n"
            }
            md += "\n"
        }
        
        return md
    }
}

/// 完整会话历史记录
struct ConversationSessionRecord: Identifiable, Codable, Equatable {
    let id: UUID
    let startTime: Date
    let endTime: Date
    let utterances: [ConversationUtterance]
    let stats: ConversationStats
    var summary: ConversationSummary?
    
    init(id: UUID = UUID(), startTime: Date, endTime: Date, utterances: [ConversationUtterance], stats: ConversationStats, summary: ConversationSummary? = nil) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.utterances = utterances
        self.stats = stats
        self.summary = summary
    }
    
    var fullTranscriptText: String {
        var text = ""
        for u in utterances {
            text += "[\(u.formattedTime)] \(u.speaker.prefix)\(u.text)\n"
        }
        return text
    }
}
