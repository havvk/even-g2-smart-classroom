//
//  ConversationSummaryService.swift
//  SmartGlassGateway
//
//  Created by Antigravity on 2026-09-13.
//

import Foundation

/// 对话智能总结与纪要服务 (Conversation Summary Service)
final class ConversationSummaryService {
    static let shared = ConversationSummaryService()
    
    private init() {}
    
    /// 为指定对话流水异步生成结构化总结
    func generateSummary(
        for utterances: [ConversationUtterance],
        stats: ConversationStats,
        completion: @escaping (ConversationSummary) -> Void
    ) {
        // 在后台线程执行启发式自然语言分析与语义提取
        DispatchQueue.global(qos: .userInitiated).async {
            let summary = Self.extractSummaryHeuristically(utterances: utterances, stats: stats)
            // 稍作 0.3s 平滑微延迟，提供清晰的 AI 提炼感
            Thread.sleep(forTimeInterval: 0.3)
            DispatchQueue.main.async {
                completion(summary)
            }
        }
    }
    
    // MARK: - 启发式语义萃取算法 (无需外部网络即可 100% 极速离线生成)
    
    private static func extractSummaryHeuristically(
        utterances: [ConversationUtterance],
        stats: ConversationStats
    ) -> ConversationSummary {
        guard !utterances.isEmpty else {
            return ConversationSummary(
                topic: "短时交谈",
                takeaways: ["本次对话未采集到有效语音内容。"],
                actionItems: [],
                generatedAt: Date()
            )
        }
        
        let allTexts = utterances.map { $0.text }
        let fullDialogue = allTexts.joined(separator: " ")
        
        // 1. 提炼核心主题 (Topic Extraction)
        var detectedTopic = "工作交流与方案探讨"
        let topicKeywords: [(String, String)] = [
            ("架构", "系统架构与技术选型探讨"),
            ("眼镜", "Even G2 智能眼镜应用交流"),
            ("接口", "接口联调与协议规范确认"),
            ("工期", "项目交付周期与工期排定"),
            ("测试", "软硬件集成测试与问题排查"),
            ("课时", "智慧课堂教案与多媒体方案"),
            ("商务", "商务合作与条款洽谈")
        ]
        for (kw, topicDesc) in topicKeywords {
            if fullDialogue.contains(kw) {
                detectedTopic = topicDesc
                break
            }
        }
        
        // 2. 提取核心要点 (Key Takeaways)
        var takeaways: [String] = []
        let takeawaySignals = ["认为", "重点是", "方案是", "同意", "关键在", "核心是", "建议", "确认", "需要", "发现"]
        
        for u in utterances {
            let sentence = u.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard sentence.count >= 6 else { continue }
            
            for sig in takeawaySignals {
                if sentence.contains(sig) {
                    let speakerTag = u.speaker == .me ? "我方表示" : "对方指出"
                    let point = "\(speakerTag)：\(sentence)"
                    if !takeaways.contains(point) && takeaways.count < 4 {
                        takeaways.append(point)
                    }
                    break
                }
            }
        }
        
        // 兜底保障：若未匹配到信号词，直接提取双方较有信息量的主干句
        if takeaways.isEmpty {
            for u in utterances.prefix(3) {
                let clean = u.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if clean.count >= 5 {
                    takeaways.append("\(u.speaker == .me ? "我方" : "对方")：\(clean)")
                }
            }
        }
        
        // 3. 提取待办事项与承诺 (Action Items / TODOs)
        var actionItems: [String] = []
        let actionSignals = ["明天", "下周", "稍后", "准备", "负责", "发给你", "联系", "对接", "提交", "核对", "更新", "修改", "采购", "上线"]
        
        for u in utterances {
            let sentence = u.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard sentence.count >= 5 else { continue }
            
            for sig in actionSignals {
                if sentence.contains(sig) {
                    let assignee = u.speaker == .me ? "我方" : "对方"
                    let item = "[\(assignee)] \(sentence)"
                    if !actionItems.contains(item) && actionItems.count < 3 {
                        actionItems.append(item)
                    }
                    break
                }
            }
        }
        
        if actionItems.isEmpty {
            actionItems.append("针对本次 \(detectedTopic) 保持日常进度同步与跟进")
        }
        
        return ConversationSummary(
            topic: detectedTopic,
            takeaways: takeaways,
            actionItems: actionItems,
            generatedAt: Date()
        )
    }
}
