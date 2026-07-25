import SwiftUI

/// 官方级“所见即所得” 9 行高亮视窗提词器 View
struct TeleprompterWYSIWYGView: View {
    @EnvironmentObject var bleManager: BLEManager
    
    @State private var teleprompterText: String = """
各位领导、各位老师，大家上午好！
今天我们召开《人机协同程序设计》课程全校统一数智化教学集体备课研讨会，主要目的是为了贯彻落实教务处文件精神，面向各理工科学院及医学院负责该课程授课的全体老师，共同研讨教学规范，明确教学要求，并合力推进标准化教学资源的建设。
我们这门课程定位为跨界通识课，将在 2026 年秋季学期，也就是今年 9 月份正式开课。课程设置可能是 2.0 或 3.0 学分，对应 32 或 48 学时。今天我将围绕本门课程的建设思路、教学策略、考核改革以及资源保障等方面，与各位老师进行深入的探讨与交流。

首先，我们来看一下执行摘要的第一部分，关于课程的痛点与定位。
为了响应全校“专业+AI”的培养大势，我们采用了每周“2+2”的理实一体课时设置：包含 2 学时理论、2 学时实践，以及 2 学时课后协同大作业。这旨在通过“人机协同”与“人际协同”的双重训练，补足大一新生在传统应试教育中匮乏的核心沟通协作本领。
我们针对两大痛点：非专业学生因为学习曲线陡峭，往往未入门即放弃；而专业学生偏重底层刷题，极易在未来被 AI 取代。
因此，本课程重新确立了“人在回路（HOTL）”的核心培养定位。
"""
    
    /// 显示区域宽度（10..28 个汉字）
    @State private var targetWidthChars: Double = 11.0
    /// 当前在 App 上手动拖动的偏移量
    @State private var scrollLineOffset: Int = 0
    
    var body: some View {
        VStack(spacing: 16) {
            // 1. 顶部控制条 (可变显示区域宽度调节)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "ruler.fill")
                        .foregroundColor(.blue)
                    Text("显示区域宽度调节:")
                        .font(.subheadline)
                        .fontWeight(.bold)
                    Spacer()
                    Text("\(Int(targetWidthChars)) 个汉字/行")
                        .font(.subheadline)
                        .fontWeight(.heavy)
                        .foregroundColor(.blue)
                }
                
                Slider(value: $targetWidthChars, in: 10...28, step: 1) {
                    Text("宽度")
                } minimumValueLabel: {
                    Text("10字").font(.caption).foregroundColor(.gray)
                } maximumValueLabel: {
                    Text("28字").font(.caption).foregroundColor(.gray)
                }
                .onChange(of: targetWidthChars) { newValue in
                    triggerPush()
                }
                
                Text("物理字号恒定为 23px，改变显示宽度可容纳不同字数")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(10)
            
            // 2. 9 行“所见即所得”高亮视窗
            let (pages, wrappedLines, linesPerPage) = G2ProtocolEncoder.formatTextToPages(teleprompterText, targetWidthChars: Int(targetWidthChars))
            
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Label("9 行高亮“所见即所得”提词视窗", systemImage: "eye.fill")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("同步行: \(bleManager.currentFocusPageLine)")
                        .font(.caption2)
                        .foregroundColor(.blue)
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)
                
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(0..<wrappedLines.count, id: \.self) { index in
                                let isHighlighted = (index >= scrollLineOffset && index < scrollLineOffset + 9)
                                
                                HStack {
                                    Text(wrappedLines[index])
                                        .font(.system(size: 15, weight: isHighlighted ? .bold : .regular, design: .default))
                                        .foregroundColor(isHighlighted ? .primary : .secondary.opacity(0.4))
                                        .padding(.vertical, 2)
                                        .padding(.horizontal, 8)
                                    Spacer()
                                }
                                .background(isHighlighted ? Color.white : Color.clear)
                                .cornerRadius(isHighlighted ? 4 : 0)
                                .shadow(color: isHighlighted ? Color.black.opacity(0.08) : Color.clear, radius: 2, x: 0, y: 1)
                                .id(index)
                            }
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 4)
                    }
                    .frame(height: 280)
                    .background(Color(UIColor.tertiarySystemBackground))
                    .cornerRadius(12)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let lineDelta = Int(-value.translation.height / 25)
                                let newOffset = max(0, min(wrappedLines.count - 9, scrollLineOffset + lineDelta))
                                if newOffset != scrollLineOffset {
                                    scrollLineOffset = newOffset
                                    bleManager.sendScrollSync(pageLine: scrollLineOffset)
                                }
                            }
                    )
                    .onChange(of: bleManager.currentFocusPageLine) { newLine in
                        scrollLineOffset = newLine
                        withAnimation {
                            proxy.scrollTo(newLine, anchor: .top)
                        }
                    }
                }
            }
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(12)
            
            // 3. 推送与控制按钮
            HStack(spacing: 12) {
                Button(action: { triggerPush() }) {
                    HStack {
                        Image(systemName: "paperplane.fill")
                        Text("推屏至 Even G2")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.purple)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
            }
        }
        .padding(.horizontal)
    }
    
    private func triggerPush() {
        bleManager.sendTeleprompterText(teleprompterText, targetWidthChars: Int(targetWidthChars))
    }
}
