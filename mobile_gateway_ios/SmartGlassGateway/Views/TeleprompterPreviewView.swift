import SwiftUI
import Combine

struct TeleprompterLineOffsetKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// 视口与文本窗口解耦边界数据模型
struct ViewportBounds {
    let vStart: Int // 视口内文本上界 (0-indexed)
    let vEnd: Int   // 视口内文本下界 (0-indexed)
    let wStart: Int // 文本窗口上界 (0-indexed)
    let wEnd: Int   // 文本窗口下界 (0-indexed)
}

/// 讲稿预览视图 (包含讲稿元信息卡片、当前行号/手势调试胶囊与 10 行视口预览)
struct TeleprompterPreviewView: View {
    @EnvironmentObject var bleManager: BLEManager
    @ObservedObject var storage = ScriptStorage.shared
    @ObservedObject private var speechEngine = SpeechFollowEngine.shared
    @Environment(\.presentationMode) var presentationMode
    
    @State var script: ScriptItem
    @State private var activeLineIndex: Int = 0
    @State private var showingEditor: Bool = false
    @State private var isPushing: Bool = false
    @State private var isPlaying: Bool = false
    @State private var isProgrammaticScrolling: Bool = false
    @State private var timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()
    
    @State private var widthChars: Double = 28.0
    @State private var dragSettleWorkItem: DispatchWorkItem?
    
    /// Even G2 智能眼镜物理视口固定显示 9 行文本 (与官方 App 保持一致)
    static let physicalViewportLines: Int = 9
    
    var wrappedLines: [String] {
        let maxLineWidth = Int(widthChars) * 2
        let (pages, _) = G2ProtocolEncoder.formatTextToPagesOnDemand(script.content, maxLineWidth: maxLineWidth, linesPerPage: 10)
        let lines = pages.flatMap { $0.components(separatedBy: "\n") }
        return lines.isEmpty ? ["暂无讲稿内容"] : lines
    }
    
    var currentBounds: ViewportBounds {
        let total = wrappedLines.count
        let vp = TeleprompterPreviewView.physicalViewportLines
        let maxTop = max(total - vp, 0)
        let vStart = max(0, min(activeLineIndex, maxTop))
        let vEnd = min(vStart + vp - 1, max(total - 1, 0))
        let wStart = max(0, vStart - 4)
        let wEnd = min(vEnd + 4, max(total - 1, 0))
        return ViewportBounds(vStart: vStart, vEnd: vEnd, wStart: wStart, wEnd: wEnd)
    }
    
    var body: some View {
        let bounds = currentBounds
        
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
                            Text("每行 \(Int(widthChars)) 字 • 视口固定 9 行")
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
            
            // MARK: - 动态行数解耦视口预览区域
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 4) {
                        Spacer(minLength: 20)
                        
                        ForEach(Array(wrappedLines.enumerated()), id: \.offset) { index, lineText in
                            let isInViewport = (index >= bounds.vStart && index <= bounds.vEnd)
                            let isViewportTop = (index == bounds.vStart)
                            let isCurrentReading = (speechEngine.isListening && index == activeLineIndex)
                            let isPastRead = (speechEngine.isListening && index < activeLineIndex)
                            
                            HStack(alignment: .center, spacing: 8) {
                                HStack(spacing: 3) {
                                    if isCurrentReading {
                                        Circle()
                                            .fill(Color.green)
                                            .frame(width: 6, height: 6)
                                    }
                                    Text(String(format: "%02d", index + 1))
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundColor(isCurrentReading ? Color.green : (isPastRead ? Color.gray.opacity(0.3) : (isInViewport ? Color.purple : Color.gray.opacity(0.3))))
                                }
                                .frame(width: 28, alignment: .trailing)
                                
                                let dynamicSize = min(15.0, max(10.5, 310.0 / CGFloat(widthChars)))
                                
                                if isCurrentReading {
                                    let order = max(0, min(speechEngine.currentWordOrder, lineText.count))
                                    if order == 0 {
                                        Text(lineText.isEmpty ? " " : lineText)
                                            .font(.system(size: dynamicSize, weight: .bold))
                                            .foregroundColor(Color.green)
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.70)
                                            .allowsTightening(true)
                                    } else if order >= lineText.count {
                                        Text(lineText.isEmpty ? " " : lineText)
                                            .font(.system(size: dynamicSize, weight: .medium))
                                            .foregroundColor(Color.gray.opacity(0.45))
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.70)
                                            .allowsTightening(true)
                                    } else {
                                        let spokenIndex = lineText.index(lineText.startIndex, offsetBy: order)
                                        let spokenPart = String(lineText[..<spokenIndex])
                                        let remainingPart = String(lineText[spokenIndex...])
                                        
                                        (Text(spokenPart)
                                            .foregroundColor(Color.gray.opacity(0.45))
                                            .font(.system(size: dynamicSize, weight: .medium))
                                         +
                                         Text(remainingPart)
                                            .foregroundColor(Color.green)
                                            .font(.system(size: dynamicSize, weight: .bold))
                                        )
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.70)
                                        .allowsTightening(true)
                                    }
                                } else if isPastRead {
                                    Text(lineText.isEmpty ? " " : lineText)
                                        .font(.system(size: dynamicSize * 0.95, weight: .regular))
                                        .foregroundColor(Color.gray.opacity(0.40))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.70)
                                        .allowsTightening(true)
                                } else {
                                    Text(lineText.isEmpty ? " " : lineText)
                                        .font(.system(size: isInViewport ? dynamicSize : dynamicSize * 0.95, weight: isInViewport ? .medium : .regular))
                                        .foregroundColor(isInViewport ? Color.primary : Color.secondary.opacity(0.35))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.70)
                                        .allowsTightening(true)
                                }
                                
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 4)
                            .background(
                                Group {
                                    if isCurrentReading {
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Color.green.opacity(0.12))
                                    } else if isInViewport {
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(isViewportTop ? Color.purple.opacity(0.12) : Color.purple.opacity(0.04))
                                    } else {
                                        Color.clear
                                    }
                                }
                            )
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: TeleprompterLineOffsetKey.self,
                                        value: [index: geo.frame(in: .named("teleprompter_scroll")).minY]
                                    )
                                }
                            )
                            .id(index)
                            .onTapGesture {
                                updateFocusLine(index: index, scrollProxy: proxy)
                            }
                        }
                        
                        Spacer(minLength: 90)
                    }
                    .padding(.vertical, 8)
                }
                .coordinateSpace(name: "teleprompter_scroll")
                .simultaneousGesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { _ in
                            self.isProgrammaticScrolling = false
                            self.bleManager.resetGlassesRxShield()
                        }
                )
                .onPreferenceChange(TeleprompterLineOffsetKey.self) { offsets in
                    // 🛡️ 只有程序自动滚动期间才忽略 offset
                    guard !isProgrammaticScrolling else { return }
                    // 🛡️ 核心防干扰：当 AI 语音跟随模式开启时，提词位置由 AI 引擎绝对独占，严禁物理滚动反向篡改！
                    guard !(isPlaying && script.scrollMode == .ai) else { return }
                    let maxLine = max(wrappedLines.count - TeleprompterPreviewView.physicalViewportLines, 0)
                    
                    let candidateIndex: Int?
                    // 精确对齐 ScrollView 容器顶部 (minY ≈ 0)
                    if let topCandidate = offsets.filter({ $0.value >= -35 && $0.value <= 100 }).min(by: { abs($0.value) < abs($1.value) }) {
                        candidateIndex = topCandidate.key
                    } else {
                        candidateIndex = nil
                    }
                    
                    if let rawIndex = candidateIndex {
                        let newIndex = max(0, min(rawIndex, maxLine))
                        // 1. 本地 UI 实时跟随（包含松手后的惯性滑动）
                        if newIndex != activeLineIndex {
                            DispatchQueue.main.async {
                                self.activeLineIndex = newIndex
                                self.syncLineToGlasses(lineIndex: newIndex)
                            }
                        }
                        
                        // 2. 🎯 手势停顿/滑动结束终点闭环：取消旧倒计时，200ms 后强制刷帧与解封校验
                        dragSettleWorkItem?.cancel()
                        let item = DispatchWorkItem {
                            self.bleManager.flushFinalScrollSync(lineIndex: newIndex)
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                                proxy.scrollTo(newIndex, anchor: .top)
                            }
                        }
                        self.dragSettleWorkItem = item
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20, execute: item)
                    }
                }
                .onReceive(bleManager.$currentFocusPageLine) { newGlassesLine in
                    guard !wrappedLines.isEmpty else { return }
                    let maxLine = max(wrappedLines.count - TeleprompterPreviewView.physicalViewportLines, 0)
                    let clampedLine = max(0, min(maxLine, newGlassesLine))
                    
                    // 🛡️ 消除乒乓效应: 若眼镜回波行号与手机当前已停靠的 activeLineIndex 完全一致，
                    // 说明手机本身已处于该位置，严禁重复触发 proxy.scrollTo 引起弹簧震荡与界面弹跳！
                    guard clampedLine != activeLineIndex else { return }
                    
                    // 🛡️ 手机主控防拉扯：若手机端刚主动滑动过 (500ms 内)，严禁被外部回波强行触发 proxy.scrollTo 引起回弹
                    guard !self.bleManager.isRecentPhoneScroll else { return }
                    
                    self.isProgrammaticScrolling = true
                    self.dragSettleWorkItem?.cancel()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        self.activeLineIndex = clampedLine
                        proxy.scrollTo(clampedLine, anchor: .top)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.40) {
                        self.isProgrammaticScrolling = false
                    }
                }
                .onReceive(timer) { _ in
                    if isPlaying && script.scrollMode == .auto && !wrappedLines.isEmpty {
                        let nextLine = (activeLineIndex + 1) % wrappedLines.count
                        updateFocusLine(index: nextLine, scrollProxy: proxy)
                    }
                }
                .onReceive(speechEngine.$activeLineIndex) { aiLine in
                    guard isPlaying && script.scrollMode == .ai && !wrappedLines.isEmpty else { return }
                    let targetLine = min(max(0, aiLine), max(wrappedLines.count - 1, 0))
                    guard targetLine != activeLineIndex else { return }
                    updateFocusLine(index: targetLine, scrollProxy: proxy)
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
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        isPlaying.toggle()
                        if script.scrollMode == .ai {
                            if isPlaying {
                                speechEngine.loadSlideScriptLines(lines: wrappedLines, rawScript: script.content)
                                speechEngine.startListening()
                            } else {
                                speechEngine.stopListening()
                            }
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: isPlaying ? "pause.circle.fill" : (script.scrollMode == .ai ? "sparkles.tv.fill" : "play.circle.fill"))
                                .font(.title)
                                .foregroundColor(script.scrollMode == .ai ? (isPlaying ? .green : .purple) : .purple)
                        }
                    }
                    
                    if script.scrollMode == .ai {
                        AudioSourceToggleCapsule(speechEngine: speechEngine, isHUDStyle: true)
                    }
                    
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("每行字数")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(Int(widthChars)) 字 / 行")
                                .font(.caption2)
                                .fontWeight(.bold)
                                .foregroundColor(.purple)
                        }
                        
                        HStack(spacing: 8) {
                            Text("10字")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            
                            Slider(value: $widthChars, in: 10...28, step: 1)
                                .accentColor(.purple)
                            
                            Text("28字")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        
                        // 🌟 每屏行数调节器 (3~10行动态调节，默认 9 行)
                        HStack {
                            Text("每屏行数")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(bleManager.linesPerPage) 行 / 屏")
                                .font(.caption2)
                                .fontWeight(.bold)
                                .foregroundColor(.purple)
                        }
                        
                        HStack(spacing: 8) {
                            Text("3行")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            
                            Slider(
                                value: Binding(
                                    get: { Double(bleManager.linesPerPage) },
                                    set: { bleManager.linesPerPage = min(9, max(1, Int($0))) }
                                ),
                                in: 3...9,
                                step: 1
                            )
                            .accentColor(.purple)
                            
                            Text("9行")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
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
            if bleManager.isTeleprompterSessionActive {
                let target = min(bleManager.currentFocusPageLine, max(wrappedLines.count - 1, 0))
                self.activeLineIndex = target
            } else {
                self.activeLineIndex = 0
            }
        }
        .onDisappear {
            if isPlaying {
                isPlaying = false
                speechEngine.stopListening()
            }
        }
        .sheet(isPresented: $showingEditor) {
            ScriptEditorView(scriptToEdit: script)
        }
    }
    
    private func updateFocusLine(index: Int, scrollProxy: ScrollViewProxy?) {
        let maxLine = max(wrappedLines.count - TeleprompterPreviewView.physicalViewportLines, 0)
        let clamped = max(0, min(maxLine, index))
        isProgrammaticScrolling = true
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            activeLineIndex = clamped
            scrollProxy?.scrollTo(clamped, anchor: .top)
        }
        bleManager.resetGlassesRxShield()
        bleManager.flushFinalScrollSync(lineIndex: clamped)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            self.isProgrammaticScrolling = false
        }
    }
    
    private func syncLineToGlasses(lineIndex: Int) {
        guard bleManager.isConnected else { return }
        
        if bleManager.isTeleprompterSessionActive && !bleManager.isPushingText {
            let maxLine = max(wrappedLines.count - TeleprompterPreviewView.physicalViewportLines, 0)
            let safeLine = max(0, min(maxLine, lineIndex))
            bleManager.sendScrollSync(lineIndex: safeLine)
        }
    }
    
    private func triggerPushToGlasses(scrollProxy: ScrollViewProxy?) {
        isPushing = true
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            activeLineIndex = 0
            scrollProxy?.scrollTo(0, anchor: .top)
        }
        bleManager.currentFocusPageLine = 0
        bleManager.resetGlassesRxShield()
        
        let isAI = (script.scrollMode == .ai)
        bleManager.sendTeleprompterText(script.content, targetWidthChars: Int(widthChars), scrollModeAI: isAI, linesPerPage: bleManager.linesPerPage)
        
        // 🌟 核心打通：推流后自动装载脚本进入语音跟随引擎并开启监听
        speechEngine.loadSlideScriptLines(lines: self.wrappedLines, rawScript: script.content)
        if isAI && bleManager.isConnected {
            speechEngine.startListening()
            speechEngine.onSpeechSyncUpdated = { [weak bleManager] line, order in
                bleManager?.sendAISync(lineIndex: line, wordOrder: order)
            }
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            isPushing = false
        }
    }
}
