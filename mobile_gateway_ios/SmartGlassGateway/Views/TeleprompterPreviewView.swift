import SwiftUI

/// 讲稿预览视图 (包含讲稿元信息卡片、当前行号/手势调试胶囊与 10 行视口预览)
struct TeleprompterPreviewView: View {
    @EnvironmentObject var bleManager: BLEManager
    @ObservedObject var storage = ScriptStorage.shared
    @Environment(\.presentationMode) var presentationMode
    
    @State var script: ScriptItem
    @State private var activeLineIndex: Int = 0
    @State private var showingEditor: Bool = false
    @State private var isPushing: Bool = false
    @State private var isPlaying: Bool = false
    @State private var timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()
    
    @State private var widthChars: Double = 28.0
    let viewportLineCount = 10
    
    var wrappedLines: [String] {
        let maxLineWidth = Int(widthChars) * 2
        let cleanText = script.content.replacingOccurrences(of: "\\n", with: "\n")
        var lines = [String]()
        
        let paragraphs = cleanText.components(separatedBy: "\n")
        for para in paragraphs {
            if para.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append("")
                continue
            }
            var currentLine = ""
            var currentWidth = 0
            for char in para {
                let w = G2ProtocolEncoder.getCharWidth(char)
                if currentWidth + w > maxLineWidth {
                    lines.append(currentLine)
                    currentLine = String(char)
                    currentWidth = w
                } else {
                    currentLine.append(char)
                    currentWidth += w
                }
            }
            if !currentLine.isEmpty {
                lines.append(currentLine)
            }
        }
        return lines.isEmpty ? ["暂无讲稿内容"] : lines
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // MARK: - 顶栏
            HStack {
                Button(action: { presentationMode.wrappedValue.dismiss() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("返回")
                    }
                }
                Spacer()
                Text(script.title).font(.headline).lineLimit(1)
                Spacer()
                Button(action: { showingEditor = true }) {
                    Image(systemName: "square.and.pencil").font(.title3)
                }
            }
            .padding()
            .background(Color(UIColor.systemBackground))
            
            // MARK: - 顶部讲稿卡片与模式选择器
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(script.title)
                            .font(.title3)
                            .fontWeight(.bold)
                            .foregroundColor(.primary)
                            .lineLimit(2)
                        
                        HStack(spacing: 12) {
                            Text(script.formattedDateString)
                            Text("•")
                            Text("每行 \(Int(widthChars)) 字 / 视口 10 行")
                                .foregroundColor(.purple)
                                .fontWeight(.semibold)
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Menu {
                        ForEach(TeleprompterScrollMode.allCases) { mode in
                            Button(action: {
                                script.scrollMode = mode
                                storage.updateScript(script)
                            }) {
                                Label(mode.displayName, systemImage: mode.iconName)
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: script.scrollMode.iconName)
                            Text(script.scrollMode.rawValue)
                                .fontWeight(.semibold)
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color(UIColor.tertiarySystemFill))
                        .cornerRadius(12)
                        .foregroundColor(.primary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(16)
            .padding(.horizontal)
            .padding(.top, 8)
            
            // MARK: - 实时当前行号与眼镜手势调试胶囊
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(bleManager.isConnected ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text("行号:\(bleManager.currentFocusPageLine)")
                        .font(.system(.caption, design: .monospaced))
                        .fontWeight(.bold)
                        .foregroundColor(.green)
                }
                
                Divider().frame(height: 12)
                
                Text("Rx:\(bleManager.rxPacketCount)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.purple)
                
                Divider().frame(height: 12)
                
                Text("手势: \(bleManager.lastGestureReceived.isEmpty ? "无" : bleManager.lastGestureReceived)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.orange)
                
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(8)
            .padding(.horizontal, 16)
            .padding(.top, 4)
            
            // MARK: - 10 行视口预览区域
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 4) {
                        Spacer(minLength: 20)
                        
                        ForEach(Array(wrappedLines.enumerated()), id: \.offset) { index, lineText in
                            let isInViewport = (index >= activeLineIndex && index < activeLineIndex + viewportLineCount)
                            let isViewportTop = (index == activeLineIndex)
                            
                            HStack(alignment: .center, spacing: 8) {
                                Text(String(format: "%02d", index + 1))
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundColor(isInViewport ? Color.purple : Color.gray.opacity(0.3))
                                    .frame(width: 22, alignment: .trailing)
                                
                                Text(lineText.isEmpty ? " " : lineText)
                                    .font(.system(size: isInViewport ? 15 : 13.5, weight: isInViewport ? .medium : .regular))
                                    .foregroundColor(isInViewport ? Color.primary : Color.secondary.opacity(0.3))
                                    .lineLimit(1)
                                
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 4)
                            .background(
                                Group {
                                    if isInViewport {
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(isViewportTop ? Color.purple.opacity(0.12) : Color.purple.opacity(0.04))
                                    } else {
                                        Color.clear
                                    }
                                }
                            )
                            .id(index)
                            .onTapGesture {
                                updateFocusLine(index: index, scrollProxy: proxy)
                            }
                        }
                        
                        Spacer(minLength: 500)
                    }
                    .padding(.vertical, 8)
                }
                .onReceive(bleManager.$currentFocusPageLine) { newGlassesLine in
                    guard !wrappedLines.isEmpty else { return }
                    let clampedLine = max(0, min(wrappedLines.count - 1, newGlassesLine))
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        self.activeLineIndex = clampedLine
                        proxy.scrollTo(clampedLine, anchor: .top)
                    }
                }
                .onReceive(timer) { _ in
                    if isPlaying && !wrappedLines.isEmpty {
                        let nextLine = (activeLineIndex + 1) % wrappedLines.count
                        updateFocusLine(index: nextLine, scrollProxy: proxy)
                    }
                }
            }
            .background(Color(UIColor.systemGroupedBackground))
            
            // MARK: - 底部控制工具条 (含每行字数调节滑块 + 自动滚屏)
            VStack(spacing: 12) {
                HStack(spacing: 14) {
                    Button(action: {
                        updateFocusLine(index: 0, scrollProxy: nil)
                    }) {
                        Image(systemName: "arrow.left.to.line.compact")
                            .font(.title3)
                            .foregroundColor(.primary)
                    }
                    
                    Button(action: {
                        isPlaying.toggle()
                    }) {
                        Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.title)
                            .foregroundColor(.purple)
                    }
                    
                    Text("10字")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    Slider(value: $widthChars, in: 10...28, step: 1)
                        .accentColor(.purple)
                    
                    Text("28字")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 24)
                
                HStack(spacing: 16) {
                    Button(action: { showingEditor = true }) {
                        HStack {
                            Image(systemName: "square.and.pencil")
                            Text("编辑")
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color(UIColor.secondarySystemGroupedBackground))
                        .foregroundColor(.primary)
                        .cornerRadius(12)
                    }
                    
                    Button(action: {
                        triggerPushToGlasses(scrollProxy: nil)
                    }) {
                        HStack {
                            if isPushing {
                                ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white))
                            } else {
                                Image(systemName: "arrow.right.circle.fill")
                            }
                            Text(bleManager.isConnected ? "推送至眼镜" : "未连接 G2")
                        }
                        .font(.headline)
                        .fontWeight(.bold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(bleManager.isConnected ? Color.purple : Color.gray)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }
                    .disabled(!bleManager.isConnected || isPushing)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
            }
            .padding(.vertical, 10)
            .background(Color(UIColor.secondarySystemGroupedBackground))
        }
        .navigationBarHidden(true)
        .onAppear {
            widthChars = Double(script.targetWidthChars)
        }
        .sheet(isPresented: $showingEditor) {
            ScriptEditorView(scriptToEdit: script)
        }
    }
    
    private func updateFocusLine(index: Int, scrollProxy: ScrollViewProxy?) {
        let clamped = max(0, min(wrappedLines.count - 1, index))
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            activeLineIndex = clamped
            scrollProxy?.scrollTo(clamped, anchor: .top)
        }
        syncLineToGlasses(lineIndex: clamped)
    }
    
    private func syncLineToGlasses(lineIndex: Int) {
        guard bleManager.isConnected else { return }
        
        if bleManager.isTeleprompterSessionActive {
            // ✅ 场景 1：眼镜正处于提词模式 -> 极速发送 1 包位置同步 (0 延迟跟随)
            bleManager.sendScrollSync(lineIndex: lineIndex)
        } else if !bleManager.isPushingText {
            // ⚠️ 场景 2：眼镜已被用户退出或处于桌面 -> 智能自动唤醒点屏，并直接跳转至 lineIndex
            bleManager.addLog("💡 [智能唤醒] 检测到眼镜当前不在提词模式，手机滑动自动重新唤醒点亮 MicroLED 物理屏，并定位至第 \(lineIndex) 行...")
            bleManager.sendTeleprompterText(script.content, targetWidthChars: Int(widthChars), scrollModeAI: false, startLine: lineIndex)
        }
    }
    
    private func triggerPushToGlasses(scrollProxy: ScrollViewProxy?) {
        isPushing = true
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            activeLineIndex = 0
            scrollProxy?.scrollTo(0, anchor: .top)
        }
        bleManager.currentFocusPageLine = 0
        bleManager.sendTeleprompterText(script.content, targetWidthChars: Int(widthChars), scrollModeAI: false)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            isPushing = false
        }
    }
}
