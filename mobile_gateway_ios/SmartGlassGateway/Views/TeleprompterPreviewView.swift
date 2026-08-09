import SwiftUI

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
    @Environment(\.presentationMode) var presentationMode
    
    @State var script: ScriptItem
    @State private var activeLineIndex: Int = 0
    @State private var showingEditor: Bool = false
    @State private var isPushing: Bool = false
    @State private var isPlaying: Bool = false
    @State private var isProgrammaticScrolling: Bool = false
    @State private var timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()
    
    @State private var widthChars: Double = 28.0
    @State private var linesPerPageValue: Double = 10.0
    @State private var dragSettleWorkItem: DispatchWorkItem?
    
    var currentLinesPerPage: Int {
        return Int(linesPerPageValue)
    }
    
    var wrappedLines: [String] {
        let maxLineWidth = Int(widthChars) * 2
        let (pages, _) = G2ProtocolEncoder.formatTextToPagesOnDemand(script.content, maxLineWidth: maxLineWidth, linesPerPage: currentLinesPerPage)
        let lines = pages.flatMap { $0.components(separatedBy: "\n") }
        return lines.isEmpty ? ["暂无讲稿内容"] : lines
    }
    
    var currentBounds: ViewportBounds {
        let total = wrappedLines.count
        let lpp = currentLinesPerPage
        let maxMovable = max(total - lpp, 0)
        let vStart = max(0, min(activeLineIndex, maxMovable))
        let vEnd = min(vStart + lpp - 1, max(total - 1, 0))
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
                            Text("每行 \(Int(widthChars)) 字 / 视口 \(currentLinesPerPage) 行")
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
                        
                        Spacer(minLength: 120)
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
                    guard !isProgrammaticScrolling else { return }
                    let maxLine = max(wrappedLines.count - currentLinesPerPage, 0)
                    
                    let candidateIndex: Int?
                    if let topCandidate = offsets.filter({ $0.value >= -50 && $0.value <= 180 }).min(by: { abs($0.value) < abs($1.value) }) {
                        candidateIndex = topCandidate.key
                    } else if let fallbackCandidate = offsets.filter({ $0.value >= 0 }).min(by: { $0.value < $1.value }) {
                        candidateIndex = fallbackCandidate.key
                    } else {
                        candidateIndex = nil
                    }
                    
                    if let rawIndex = candidateIndex {
                        let newIndex = max(0, min(rawIndex, maxLine))
                        if newIndex != activeLineIndex {
                            DispatchQueue.main.async {
                                self.activeLineIndex = newIndex
                                self.syncLineToGlasses(lineIndex: newIndex)
                            }
                        }
                        
                        dragSettleWorkItem?.cancel()
                        let item = DispatchWorkItem {
                            self.bleManager.flushFinalScrollSync(lineIndex: newIndex)
                        }
                        self.dragSettleWorkItem = item
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20, execute: item)
                    }
                }
                .onReceive(bleManager.$currentFocusPageLine) { newGlassesLine in
                    guard !wrappedLines.isEmpty else { return }
                    let maxLine = max(wrappedLines.count - currentLinesPerPage, 0)
                    let clampedLine = max(0, min(maxLine, newGlassesLine))
                    if clampedLine != activeLineIndex {
                        self.isProgrammaticScrolling = true
                        self.dragSettleWorkItem?.cancel()
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                            self.activeLineIndex = clampedLine
                            proxy.scrollTo(clampedLine, anchor: .top)
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.80) {
                            self.isProgrammaticScrolling = false
                        }
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
                    
                    VStack(spacing: 8) {
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
                        
                        HStack(spacing: 8) {
                            Text("3行")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            
                            Slider(value: $linesPerPageValue, in: 3...10, step: 1)
                                .accentColor(.purple)
                                .onChange(of: linesPerPageValue) { newVal in
                                    bleManager.linesPerPage = Int(newVal)
                                }
                            
                            Text("10行")
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
            bleManager.linesPerPage = Int(linesPerPageValue)
        }
        .sheet(isPresented: $showingEditor) {
            ScriptEditorView(scriptToEdit: script)
        }
    }
    
    private func updateFocusLine(index: Int, scrollProxy: ScrollViewProxy?) {
        let maxLine = max(wrappedLines.count - currentLinesPerPage, 0)
        let clamped = max(0, min(maxLine, index))
        isProgrammaticScrolling = true
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            activeLineIndex = clamped
            scrollProxy?.scrollTo(clamped, anchor: .top)
        }
        syncLineToGlasses(lineIndex: clamped)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            self.isProgrammaticScrolling = false
        }
    }
    
    private func syncLineToGlasses(lineIndex: Int) {
        guard bleManager.isConnected else { return }
        
        if bleManager.isTeleprompterSessionActive && !bleManager.isPushingText {
            let maxLine = max(wrappedLines.count - currentLinesPerPage, 0)
            let safeLine = max(0, min(maxLine, lineIndex))
            bleManager.sendScrollSync(lineIndex: safeLine)
        }
    }
    
    private func triggerPushToGlasses(scrollProxy: ScrollViewProxy?) {
        isPushing = true
        bleManager.linesPerPage = currentLinesPerPage
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
