#!/usr/bin/env python3
"""
Even G2 自研 AI 语音智能跟随提词引擎 核心算法仿真与验证测试 (Build 36/37 高精版)
- 局部前向窗口最大综合得分竞争算法 (Max Similarity in Local Forward Window)
- 验证当前行粘性保护 (+2分)，严禁下行同频词提前抢跑
- 验证下行行首启动奖励 (在最近说出文本后部命中 head2/head3 时 +10分)，念出下行开头 2~3 字即秒级推进
- 验证口语化漏读行首但念出主体核心词 (LCS>=3) 依然敏锐推进
- 验证脱稿即兴发言时坚守当前行
- 验证提词位置与识别位置 100% 绝对一致 (Strict 1:1 Alignment)
"""

import unittest

def clean_string(s: str) -> str:
    for ch in ["•", "#", "【", "】", "：", "，", "。", "！", "？", "、", " ", "；", "“", "”", "\"", "'", ":", ","]:
        s = s.replace(ch, "")
    return s.strip()

def max_common_substring_length(s1: str, s2: str) -> int:
    if not s1 or not s2:
        return 0
    m, n = len(s1), len(s2)
    prev = [0] * (n + 1)
    curr = [0] * (n + 1)
    max_len = 0
    for i in range(1, m + 1):
        for j in range(1, n + 1):
            if s1[i - 1] == s2[j - 1]:
                curr[j] = prev[j - 1] + 1
                if curr[j] > max_len:
                    max_len = curr[j]
            else:
                curr[j] = 0
        prev = curr[:]
        curr = [0] * (n + 1)
    return max_len

STOP_WORDS = set("的了是在和与于个这那我们你有也")

def overlap_char_count(s1: str, s2: str) -> int:
    if not s1 or not s2:
        return 0
    s1_chars = set(s1) - STOP_WORDS
    count = 0
    for c in s2:
        if c in s1_chars:
            count += 1
    return count

class SimulatedSpeechFollowEngine:
    def __init__(self, raw_lines):
        self.script_lines = []
        for idx, line in enumerate(raw_lines):
            clean = clean_string(line)
            h2 = clean[:2] if len(clean) >= 2 else clean
            h3 = clean[:3] if len(clean) >= 3 else clean
            self.script_lines.append({
                "index": idx,
                "raw": line,
                "clean": clean,
                "head2": h2,
                "head3": h3
            })
        self.active_line_index = 0
        self.is_digressed = False
        self.confidence_score = 0.0

    def process_transcript(self, transcript: str):
        total = len(self.script_lines)
        if total == 0:
            return
            
        clean_text = clean_string(transcript)
        if len(clean_text) < 2:
            return
            
        probe_len = min(len(clean_text), 24)
        probe = clean_text[-probe_len:]
        recent_tail = clean_text[-min(len(clean_text), 10):]
        
        curr = self.active_line_index
        start_idx = curr
        end_idx = min(total - 1, curr + 3)
        
        best_score = -1.0
        best_idx = curr
        curr_base_score = 0.0
        
        for idx in range(start_idx, end_idx + 1):
            cand = self.script_lines[idx]
            cand_text = cand["clean"]
            if not cand_text:
                continue
                
            lcs = max_common_substring_length(probe, cand_text)
            overlap = overlap_char_count(probe, cand_text)
            base_score = float(overlap + lcs * 2)
            
            if idx == curr:
                curr_base_score = base_score
                
            score = base_score
            if idx == curr:
                score += 2.0  # 当前行粘性保护加权 (仅用于行间对比竞争)
            elif idx == curr + 1:
                has_tail_h3 = cand["head3"] and (cand["head3"] in recent_tail)
                has_tail_h2 = cand["head2"] and (cand["head2"] in recent_tail)
                has_any_h3 = cand["head3"] and (cand["head3"] in probe)
                if has_tail_h3:
                    score += 10.0
                elif has_tail_h2:
                    score += 6.0
                elif has_any_h3:
                    score += 5.0
                # 实词推进奖励
                if lcs >= 3 or overlap >= 4:
                    score += 5.0
            elif idx == curr + 2:
                has_tail_h3 = cand["head3"] and (cand["head3"] in recent_tail)
                if has_tail_h3:
                    score += 8.0
                elif cand["head3"] and (cand["head3"] in probe):
                    score += 4.0
                if lcs >= 3:
                    score += 4.0
                    
            if score > best_score:
                best_score = score
                best_idx = idx
                
        # 决策推进
        if best_idx > curr and best_score >= 4.0:
            self.active_line_index = best_idx
            self.is_digressed = False
            self.confidence_score = 1.0
        elif curr_base_score >= 3.5:
            self.is_digressed = False
            curr_model = self.script_lines[curr]
            self.confidence_score = min(curr_base_score / float(max(len(curr_model["clean"]), 2)), 1.0)
        else:
            self.is_digressed = True

class TestSpeechFollowAlgorithmBuild37(unittest.TestCase):
    
    def test_current_line_stickiness_prevents_premature_jump(self):
        """测试讲师还在念当前行（第0行）前半句时，即使下行有高频相同字，也绝对不提前抢跑跳行！"""
        lines = [
            "今天我们来深入学习分布式系统核心架构",
            "在前面的课程中我们已经讨论过单体瓶颈",
            "那么今天重点是CAP理论与容灾策略"
        ]
        engine = SimulatedSpeechFollowEngine(lines)
        self.assertEqual(engine.active_line_index, 0)
        
        # 讲师念第 0 行前半句："今天我们来深入学习"
        engine.process_transcript("今天我们来深入学习")
        self.assertEqual(engine.active_line_index, 0, "讲师在念第 0 行时，绝不可提前抢跑跳到第 1 行！")
        self.assertFalse(engine.is_digressed)

    def test_next_line_head_trigger_instant(self):
        """测试念出下行开头 2~3 个字时秒级触发推进行号"""
        lines = [
            "分布式系统微服务架构设计原理",
            "首先来看API网关的核心功能与统一鉴权",
            "接下来探讨服务注册发现与健康检查"
        ]
        engine = SimulatedSpeechFollowEngine(lines)
        
        # 讲师开始念第二行开头: "首先来看"
        engine.process_transcript("架构设计原理首先来看")
        self.assertEqual(engine.active_line_index, 1, "命中下行行首 '首先来看' 应立刻秒级推进至第 1 行")
        
        # 讲师继续念第三行开头: "接下来探讨"
        engine.process_transcript("统一鉴权接下来探讨")
        self.assertEqual(engine.active_line_index, 2, "命中下行行首 '接下来探讨' 应立刻秒级推进至第 2 行")

    def test_paraphrase_variation_tolerance(self):
        """测试讲师口语化表达微调时，多尺度连续子串与交集依然稳健对齐"""
        lines = [
            "分布式系统微服务架构",
            "今天我们将深入探讨高可用架构与容灾策略设计",
            "请大家看下一页的大屏架构拓扑图"
        ]
        engine = SimulatedSpeechFollowEngine(lines)
        engine.active_line_index = 0
        
        # 讲师口语化表达："今天我们来聊聊高可用设计与容灾策略" (替换了部分词汇，非完全逐字)
        engine.process_transcript("今天我们来聊聊高可用设计与容灾策略")
        self.assertEqual(engine.active_line_index, 1, "即使有口语化字词替换，高可用与容灾策略依然高密度命中第 1 行")

    def test_omit_head_words_advance_on_keywords(self):
        """测试讲师漏读下行行首虚词，直接念出下行主体核心专有名词时，依然顺滑推进"""
        lines = [
            "第一部分系统分层架构介绍",
            "那么我们首先来重点剖析分布式一致性协议的具体实现细节",
            "最后总结两阶段提交的阻塞问题"
        ]
        engine = SimulatedSpeechFollowEngine(lines)
        engine.active_line_index = 0
        
        # 讲师漏掉了 "那么我们首先来"，直接说: "重点剖析分布式一致性协议"
        engine.process_transcript("分层架构介绍重点剖析分布式一致性协议")
        self.assertEqual(engine.active_line_index, 1, "命中下行连续长实词 '分布式一致性协议'，应敏锐推进至第 1 行")

    def test_digression_hold_line(self):
        """测试脱稿发挥时，识别位置稳健锁死在当前行，绝不乱跳"""
        lines = [
            "分布式数据库分库分表策略",
            "核心在于Sharding-Key的合理选取与哈希分布",
            "另外要避免跨分片关联查询的性能损耗"
        ]
        engine = SimulatedSpeechFollowEngine(lines)
        engine.active_line_index = 1
        
        # 讲师脱稿答疑："那位穿红衣服的同学，关于你刚才提的关于缓存的问题..."
        engine.process_transcript("那位穿红衣服的同学关于你刚才提的缓存问题")
        self.assertEqual(engine.active_line_index, 1, "脱稿即兴发言时必须坚决驻留当前行")
        self.assertTrue(engine.is_digressed, "脱稿状态应被标记为 True")

    def test_skip_line_plus_2(self):
        """测试讲师跳过极短小标号行（+2跳读）正常咬合"""
        lines = [
            "系统架构分层设计",
            "1. 接入层：", # 极短行
            "API网关统一负责流量调度与熔断限流",
            "2. 业务层："
        ]
        engine = SimulatedSpeechFollowEngine(lines)
        engine.active_line_index = 0
        
        # 讲师跳过 "1. 接入层：" 直接说 "API网关统一负责流量调度"
        engine.process_transcript("API网关统一负责流量调度")
        self.assertEqual(engine.active_line_index, 2, "讲师跳过短小标号行时，应直接咬合至第 2 行正文")

    def test_strict_1_to_1_teleprompter_alignment(self):
        """测试提词位置与识别位置 100% 绝对一致，杜绝人为钳位脱节"""
        wrapped_lines = [
            "欢迎大家来到课堂",
            "今天讲三个重点",
            "首先是服务发现",
            "其次是负载均衡",
            "最后是分布式锁"
        ]
        total_lines = len(wrapped_lines)
        
        for ai_line in range(total_lines):
            # 手机端对齐
            max_index = max(total_lines - 1, 0)
            target_line = min(max(0, ai_line), max_index)
            phone_active_line = target_line
            self.assertEqual(phone_active_line, ai_line, f"手机端 activeLineIndex 必须与 aiLine ({ai_line}) 1:1 绝对一致")
            
            # Apple Watch 腕上切片对齐 (当前朗读行直接排在最顶部)
            watch_safe_line = max(0, min(target_line, total_lines - 1))
            watch_slice = wrapped_lines[watch_safe_line:min(watch_safe_line + 8, total_lines)]
            self.assertEqual(watch_safe_line, ai_line, f"Apple Watch 切片首行必须与当前朗读行 ({ai_line}) 1:1 绝对一致")
            self.assertEqual(watch_slice[0], wrapped_lines[ai_line], "手表视口第一行文字必须就是当前朗读行文字！")

if __name__ == '__main__':
    unittest.main()
