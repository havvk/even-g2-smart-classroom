import SwiftUI

/// 讲稿预览与控制台视图 (1:1 官方同款：10行紧凑视口全显、亮白高对比度、防抖滚动同步)
struct TeleprompterPreviewView: View {
    @EnvironmentObject var bleManager: BLEManager
    @ObservedObject var storage = ScriptStorage.shared
    @Environment(\.presentationMode) var presentationMode
    
    @State var script: ScriptItem
    @State private var activeLineIndex: Int = 0
    @State private var showingEditor: Bool = false
    @State private var isPushing: Bool = false
    
    // 自动滚屏定时器 (1:1 官方同款 Auto Scroll)
    @State private var isPlaying: Bool = false
    @State private var timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()
    
    // 每行字数 (通过底部滑块调节，范围 10 ~ 28 汉字)
    @State private var widthChars: Double = 28.0
    
    // 固件标准视口容纳行数 (10 行)
    let viewportLineCount = 10
    
    // 动态根据每行字数重折行后的行数组
    var wrappedLines: [String] {
        let maxLineWidth = Int(widthChars) * 2 // 1个汉字 = 2字节宽度
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
        return lines.isEmpty ? [script.content] : lines
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // MARK: - 顶部讲稿卡片与模式切换器
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
                    
                    // 模式下拉选择器 (官方同款 ||| AI ∨)
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
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(16)
            .padding(.horizontal)
            .padding(.top, 8)
            
            // MARK: - 实时手势与视口调试胶囊 (直观排查滑动响应)
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                    Text("行号: \(bleManager.currentFocusPageLine)")
                        .font(.system(.caption, design: .monospaced))
                        .fontWeight(.bold)
                        .foregroundColor(.green)
                }
                
                Divider().frame(height: 12)
                
                Text("最新手势: \(bleManager.lastGestureReceived.isEmpty ? "无" : bleManager.lastGestureReceived)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(8)
            .padding(.horizontal, 16)
            .padding(.top, 4)
            
            // MARK: - 10行 HUD 视口预览区域 (中央高亮)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
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
                            .overlay(
                                Group {
                                    if isViewportTop {
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(Color.purple.opacity(0.4), lineWidth: 1)
                                    }
                                }
                            )
                            .id(index)
                            .onTapGesture {
                                updateFocusLine(index: index, scrollProxy: proxy)
                            }
                        }
                        
                        // 500px 巨型底边滚动缓冲区 (确保任何最后行均能物理 100% 置顶)
                        Spacer(minLength: 500)
                    }
                    .padding(.vertical, 8)
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 15).onEnded { value in
                        // 手势滑动停止后，精准计算最新焦点行并仅触发一次同步
                        let delta = Int(-value.translation.height / 32.0)
                        let newIndex = min(max(0, activeLineIndex + delta), max(0, wrappedLines.count - 1))
                        if newIndex != activeLineIndex {
                            updateFocusLine(index: newIndex, scrollProxy: proxy)
                        }
                    }
                )
                // 监听眼镜端发来的触控/按键通知 (无门槛驱动 App 界面 1:1 屏顶对齐)
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
            
            // MARK: - 底部控制条 (滑块调节每行字数 10~28 + 自动滚屏)
            VStack(spacing: 12) {
                HStack(spacing: 14) {
                    // 首页复位按钮
                    Button(action: {
                        activeLineIndex = 0
                        syncLineToGlasses(lineIndex: 0)
                    }) {
                        Image(systemName: "arrow.left.to.line.compact")
                            .font(.title3)
                            .foregroundColor(.primary)
                    }
                    
                    // 官方同款 自动平滑滚屏 播放/暂停
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
                    
                    // 控制每行文字数量的滑块 (10 ~ 28 汉字)
                    Slider(
                        value: $widthChars,
                        in: 10...28,
                        step: 1
                    ) {
                        Text("每行字数")
                    } onEditingChanged: { isEditing in
                        if !isEditing {
                            script.targetWidthChars = Int(widthChars)
                            storage.updateScript(script)
                            // 字数重新排版后下发推屏
                            if bleManager.isConnected {
                                triggerPushToGlasses()
                            }
                        }
                    }
                    .accentColor(.purple)
                    
                    Text("28字")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    // 视口边界调节图标 (|-><-|)
                    Button(action: {}) {
                        Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                            .font(.title3)
                            .foregroundColor(.primary)
                    }
                }
                .padding(.horizontal, 24)
                
                // MARK: - 底部核心动作按钮 (编辑 & 开始推屏)
                HStack(spacing: 16) {
                    Button(action: {
                        showingEditor = true
                    }) {
                        HStack {
                            Image(systemName: "square.and.pencil")
                            Text("编辑")
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color(UIColor.secondarySystemGroupedBackground))
                        .foregroundColor(.primary)
                        .cornerRadius(12)
                    }
                    
                    Button(action: {
                        triggerPushToGlasses(scrollProxy: proxy)
                    }) {
                        HStack {
                            if isPushing {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            } else {
                                Image(systemName: "arrow.right.circle.fill")
                            }
                            Text(bleManager.isConnected ? "开始" : "未连接 G2")
                        }
                        .font(.headline)
                        .fontWeight(.bold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(bleManager.isConnected ? Color.primary : Color.gray)
                        .foregroundColor(Color(UIColor.systemBackground))
                        .cornerRadius(12)
                    }
                    .disabled(!bleManager.isConnected || isPushing)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            }
            .padding(.top, 8)
            .background(Color(UIColor.systemGroupedBackground).edgesIgnoringSafeArea(.bottom))
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("预览")
                    .font(.headline)
            }
        }
        .onAppear {
            widthChars = Double(script.targetWidthChars)
        }
        .sheet(isPresented: $showingEditor) {
            ScriptEditorView(scriptToEdit: script)
        }
    }
    
    /// 点击更新焦点行，并同步给眼镜
    private func updateFocusLine(index: Int, scrollProxy: ScrollViewProxy) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            activeLineIndex = index
            scrollProxy.scrollTo(index, anchor: .top)
        }
        syncLineToGlasses(lineIndex: index)
    }
    
    /// 下发行号真实双向位置同步到 G2 眼镜 (100% 对齐 teleprompter.py)
    private func syncLineToGlasses(lineIndex: Int) {
        guard bleManager.isConnected else { return }
        bleManager.sendScrollSync(lineIndex: lineIndex)
    }
    
    /// 按当前设置的每行字数下发推屏 (强制屏顶复位 activeLineIndex = 0)
    private func triggerPushToGlasses(scrollProxy: ScrollViewProxy) {
        isPushing = true
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            activeLineIndex = 0
            scrollProxy.scrollTo(0, anchor: .top)
        }
        bleManager.currentFocusPageLine = 0
        bleManager.sendTeleprompterText(script.content, targetWidthChars: Int(widthChars), scrollModeAI: false)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            isPushing = false
        }
    }
}
