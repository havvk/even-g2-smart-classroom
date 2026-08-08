//
//  AIVoiceFollowingTests.swift
//  SmartGlassGatewayTests
//
//  自研 AI 语音跟随与模糊匹配算法 TDD 单元测试集
//

import XCTest
import Foundation

final class AIVoiceFollowingTests: XCTestCase {
    
    let sampleScriptLines = [
        "同学们好，今天我们进入人机协同程序设计课程",
        "本节课重点讲解基于大模型的 Agent 架构",
        "特别是 HOTL 人在回路中的指挥与监督机制",
        "下面我们来看第一个代码实战案例"
    ]
    
    // MARK: - TC_AI_001: 校验精确文本 ASR 输入的行定位
    func testExactTextMatch_TC_AI_001() {
        let matcher = FuzzySlideWindowMatcher(scriptLines: sampleScriptLines)
        let result = matcher.match(asrText: "本节课重点讲解基于大模型的 Agent 架构")
        
        XCTAssertEqual(result.matchedLineIndex, 1, "应精确定位到第 1 行")
        XCTAssertGreaterThanOrEqual(result.similarityScore, 0.9, "相似度得分应 >= 0.9")
        XCTAssertFalse(result.isDigression, "不应触发脱稿降级")
    }
    
    // MARK: - TC_AI_002: 校验带口误与同音词错别字 ASR 的模糊定位
    func testFuzzyTextWithASRErrors_TC_AI_002() {
        let matcher = FuzzySlideWindowMatcher(scriptLines: sampleScriptLines)
        // ASR 识别口误: "人在回路" 识别为 "人在回路中"，"监督" 识别为 "检督"
        let result = matcher.match(asrText: "特别是 HOTL 人在回路中的指挥与检督机制")
        
        XCTAssertEqual(result.matchedLineIndex, 2, "即使存在 ASR 同音错别字，仍应准确定位到第 2 行")
        XCTAssertGreaterThanOrEqual(result.similarityScore, 0.6, "模糊匹配得分应 >= 0.6")
    }
    
    // MARK: - TC_AI_003: 校验前向滑动窗口策略 (禁止倒退跳行)
    func testForwardSlidingWindowStrategy_TC_AI_003() {
        let matcher = FuzzySlideWindowMatcher(scriptLines: sampleScriptLines)
        
        // 第一次定位到第 2 行
        _ = matcher.match(asrText: "特别是 HOTL 人在回路中")
        XCTAssertEqual(matcher.currentWindowIndex, 2)
        
        // 模拟后续语音：哪怕输入了类似第 0 行的词，由于窗口前向约束，不应倒退回第 0 行
        let result = matcher.match(asrText: "下面我们来看第一个代码实战案例")
        XCTAssertEqual(result.matchedLineIndex, 3, "应继续前向滑动定位到第 3 行")
    }
    
    // MARK: - TC_AI_004: 校验脱稿 5 秒（低得分）触发提纲降级机制
    func testDigressionFallbackTrigger_TC_AI_004() {
        let matcher = FuzzySlideWindowMatcher(scriptLines: sampleScriptLines, digressionTimeoutSeconds: 0.5)
        
        // 输入与讲稿完全无关的脱稿解说或回答学生提问
        let result1 = matcher.match(asrText: "那个后排的同学请把手机收起来，听懂了吗")
        XCTAssertLessThan(result1.similarityScore, 0.3, "脱稿解说匹配得分应 < 0.3")
        
        // 等待超过脱稿超时阈值
        Thread.sleep(forTimeInterval: 0.6)
        
        let result2 = matcher.match(asrText: "好，我们接着刚才的问题讨论")
        XCTAssertTrue(result2.isDigression, "连续低得分且超时后，必须触发 isDigression = true 降级通知")
    }
}
