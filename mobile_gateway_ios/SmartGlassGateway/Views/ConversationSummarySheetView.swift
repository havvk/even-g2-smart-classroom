//
//  ConversationSummarySheetView.swift
//  SmartGlassGateway
//
//  Created by Antigravity on 2026-09-13.
//

import SwiftUI
import UIKit

/// 对话智能纪要与完整转写报告弹窗
struct ConversationSummarySheetView: View {
    let record: ConversationSessionRecord
    @Environment(\.presentationMode) var presentationMode
    
    @State private var selectedTab: Int = 0
    @State private var showCopiedToast: Bool = false
    @State private var copiedToastMessage: String = ""
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    // MARK: - 1. 对话核心统计概览卡片
                    statsOverviewCard
                    
                    // MARK: - 2. Tab 切换 (AI 智能纪要 vs 完整逐字稿)
                    Picker("内容视图", selection: $selectedTab) {
                        Text("💡 AI 智能纪要").tag(0)
                        Text("📝 完整逐字稿").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 4)
                    
                    if selectedTab == 0 {
                        // AI 总结 Tab
                        summaryContentSection
                    } else {
                        // 完整转写 Tab
                        fullTranscriptSection
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("对话纪要与转写")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button(action: copyMarkdownSummary) {
                            Label("复制 Markdown 纪要", systemImage: "doc.on.doc")
                        }
                        Button(action: copyFullTranscript) {
                            Label("复制完整逐字稿", systemImage: "text.quote")
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            .overlay(
                // 复制成功浮动 Toast
                toastOverlay
            )
        }
    }
    
    // MARK: - 统计概览卡片
    
    private var statsOverviewCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("交流指标概览", systemImage: "chart.bar.xaxis")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                Text("共 \(record.utterances.count) 轮发言")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            // 三维核心数据
            HStack(spacing: 16) {
                statItem(title: "持续时长", value: record.stats.formattedDuration, icon: "clock.fill", color: .blue)
                statItem(title: "总字数", value: "\(record.stats.totalWords) 字", icon: "character.bubble.fill", color: .orange)
                statItem(title: "发言轮次", value: "\(record.stats.turnCount) 次", icon: "arrow.triangle.2.circlepath", color: .purple)
            }
            
            Divider()
            
            // 双方发言比例双色条
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    HStack(spacing: 4) {
                        Circle().fill(Color.green).frame(width: 8, height: 8)
                        Text("我方: \(Int(record.stats.myRatio * 100))% (\(record.stats.myWords)字)")
                            .font(.caption)
                            .foregroundColor(.primary)
                    }
                    Spacer()
                    HStack(spacing: 4) {
                        Text("对方: \(Int(record.stats.guestRatio * 100))% (\(record.stats.guestWords)字)")
                            .font(.caption)
                            .foregroundColor(.primary)
                        Circle().fill(Color.blue).frame(width: 8, height: 8)
                    }
                }
                
                // 双色进度条
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.green)
                            .frame(width: max(4, geo.size.width * CGFloat(record.stats.myRatio)))
                        
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.blue)
                            .frame(width: max(4, geo.size.width * CGFloat(record.stats.guestRatio)))
                    }
                }
                .frame(height: 8)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }
    
    private func statItem(title: String, value: String, icon: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(color)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.primary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    // MARK: - AI 智能总结板块
    
    private var summaryContentSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let summary = record.summary {
                // 1. 核心主题标签
                HStack(spacing: 6) {
                    Text("🏷️ 讨论主题")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(summary.topic)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color.green)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.12))
                        .cornerRadius(8)
                }
                .padding(.horizontal, 4)
                
                // 2. 核心共识与要点
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "lightbulb.fill")
                            .foregroundColor(.yellow)
                        Text("核心共识与要点")
                            .font(.subheadline)
                            .fontWeight(.bold)
                    }
                    
                    ForEach(Array(summary.takeaways.enumerated()), id: \.offset) { idx, item in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(idx + 1).")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.secondary)
                            Text(item)
                                .font(.subheadline)
                                .foregroundColor(.primary)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground))
                .cornerRadius(12)
                
                // 3. 待办事项与行动项
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("待办事项与后续行动 (Action Items)")
                            .font(.subheadline)
                            .fontWeight(.bold)
                    }
                    
                    ForEach(summary.actionItems, id: \.self) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "square")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .padding(.top, 3)
                            Text(item)
                                .font(.subheadline)
                                .foregroundColor(.primary)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemGroupedBackground))
                .cornerRadius(12)
                
                // 复制总结按钮
                Button(action: copyMarkdownSummary) {
                    HStack {
                        Image(systemName: "doc.on.doc.fill")
                        Text("一键复制 Markdown 会议纪要")
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.green)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
                .padding(.top, 6)
            } else {
                HStack {
                    Spacer()
                    ProgressView("AI 正在提炼对话纪要与核心共识...")
                        .font(.subheadline)
                        .padding()
                    Spacer()
                }
            }
        }
    }
    
    // MARK: - 完整转写板块
    
    private var fullTranscriptSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(record.utterances) { u in
                HStack(alignment: .top, spacing: 10) {
                    // 身份小标识
                    Text(u.speaker == .me ? "我" : "对方")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 28, height: 28)
                        .background(u.speaker == .me ? Color.green : Color.blue)
                        .clipShape(Circle())
                    
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(u.speaker == .me ? "我方发言" : "对方交谈")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(u.speaker == .me ? .green : .blue)
                            Spacer()
                            Text(u.formattedTime)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        
                        Text(u.text)
                            .font(.system(size: 14))
                            .foregroundColor(.primary)
                            .padding(10)
                            .background(Color(.tertiarySystemFill))
                            .cornerRadius(8)
                    }
                }
                .padding(.vertical, 2)
            }
            
            // 复制全部逐字稿按钮
            Button(action: copyFullTranscript) {
                HStack {
                    Image(systemName: "text.quote")
                    Text("复制完整对话逐字稿")
                }
                .font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color(.secondarySystemFill))
                .foregroundColor(.primary)
                .cornerRadius(10)
            }
            .padding(.top, 8)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }
    
    // MARK: - 复制与 Toast 逻辑
    
    private func copyMarkdownSummary() {
        guard let summary = record.summary else { return }
        UIPasteboard.general.string = summary.markdownReport
        triggerToast("已复制 Markdown 会议纪要！")
    }
    
    private func copyFullTranscript() {
        UIPasteboard.general.string = record.fullTranscriptText
        triggerToast("已复制完整对话逐字稿！")
    }
    
    private func triggerToast(_ msg: String) {
        copiedToastMessage = msg
        withAnimation {
            showCopiedToast = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation {
                self.showCopiedToast = false
            }
        }
    }
    
    private var toastOverlay: some View {
        VStack {
            Spacer()
            if showCopiedToast {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text(copiedToastMessage)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.85))
                .cornerRadius(20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .padding(.bottom, 24)
            }
        }
    }
}
