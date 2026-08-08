//
//  FuzzySlideWindowMatcher.swift
//  SmartGlassGateway
//
//  自研 AI 语音跟随 - 模糊滑动窗口匹配引擎与脱稿检测控制器
//

import Foundation

/// ASR 语音匹配定位结果模型
struct MatchResult {
    let matchedLineIndex: Int
    let similarityScore: Double
    let isDigression: Bool
}

class FuzzySlideWindowMatcher {
    let scriptLines: [String]
    var currentWindowIndex: Int = 0
    let digressionTimeoutSeconds: TimeInterval
    
    private var lastValidMatchTimestamp: Date = Date()
    private var isDigressionMode: Bool = false
    
    init(scriptLines: [String], digressionTimeoutSeconds: TimeInterval = 5.0) {
        self.scriptLines = scriptLines
        self.digressionTimeoutSeconds = digressionTimeoutSeconds
    }
    
    /// 计算两段文本的字符级 Jaccard / 覆盖度混合相似度 (0.0 ~ 1.0)
    static func calculateSimilarity(_ str1: String, _ str2: String) -> Double {
        let s1 = str1.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let s2 = str2.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !s1.isEmpty && !s2.isEmpty else { return 0.0 }
        if s1 == s2 || s1.contains(s2) || s2.contains(s1) { return 1.0 }
        
        let set1 = Set(s1)
        let set2 = Set(s2)
        let intersection = set1.intersection(set2)
        let union = set1.union(set2)
        
        guard !union.isEmpty else { return 0.0 }
        
        let jaccard = Double(intersection.count) / Double(union.count)
        let coverage = Double(intersection.count) / Double(min(set1.count, set2.count))
        
        return max(jaccard, coverage * 0.85)
    }
    
    /// 输入 ASR 识别文本，返回最优高亮行与脱稿状态
    func match(asrText: String) -> MatchResult {
        let now = Date()
        var bestIndex = currentWindowIndex
        var maxScore: Double = 0.0
        
        // 搜索区间：前向滑动窗口 (限制最大下查 4 行，防止误跳跃)
        let searchEnd = min(scriptLines.count, currentWindowIndex + 4)
        for i in currentWindowIndex..<searchEnd {
            let score = FuzzySlideWindowMatcher.calculateSimilarity(asrText, scriptLines[i])
            if score > maxScore {
                maxScore = score
                bestIndex = i
            }
        }
        
        if maxScore >= 0.5 {
            currentWindowIndex = max(currentWindowIndex, bestIndex)
            lastValidMatchTimestamp = now
            isDigressionMode = false
        } else {
            if now.timeIntervalSince(lastValidMatchTimestamp) >= digressionTimeoutSeconds {
                isDigressionMode = true
            }
        }
        
        return MatchResult(
            matchedLineIndex: currentWindowIndex,
            similarityScore: maxScore,
            isDigression: isDigressionMode
        )
    }
}
