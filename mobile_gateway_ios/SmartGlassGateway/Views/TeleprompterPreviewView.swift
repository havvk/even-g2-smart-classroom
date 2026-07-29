import SwiftUI

/// 讲稿预览与控制台视图 (1:1 官方同款：滑块控制每行字数，滑动手势实时同步眼镜内容)
struct TeleprompterPreviewView: View {
    @EnvironmentObject var bleManager: BLEManager
    @ObservedObject var storage = ScriptStorage.shared
    @Environment(\.presentationMode) var presentationMode
    
    @State var script: ScriptItem
    @State private var activeLineIndex: Int = 0
    @State private var showingEditor: Bool = false
    @State private var isPushing: Bool = false
    
    // 每行字数 (通过底部滑块调节，范围 10 ~ 28 汉字)
    @State private var widthChars: Double = 28.0
    
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
                            Text("每行 \(Int(widthChars)) 字")
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
            .padding()
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(16)
            .padding(.horizontal)
            .padding(.top, 8)
            
            // MARK: - 可视化视口与焦点高亮区 (支持滑动手势 + 实时眼镜同步)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 12) {
                        Spacer(minLength: 120)
                        
                        ForEach(Array(wrappedLines.enumerated()), id: \.offset) { index, lineText in
                            let isActive = (index == activeLineIndex)
                            
                            HStack {
                                Text(lineText.isEmpty ? " " : lineText)
                                    .font(.system(size: isActive ? 18 : 15, weight: isActive ? .medium : .regular))
                                    .foregroundColor(isActive ? .primary : .secondary.opacity(0.35))
                                    .multilineTextAlignment(.leading)
                                    .lineSpacing(6)
                                Spacer()
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, isActive ? 14 : 8)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(isActive ? Color(UIColor.secondarySystemGroupedBackground) : Color.clear)
                                    .shadow(color: isActive ? Color.black.opacity(0.06) : Color.clear, radius: 6, x: 0, y: 3)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(isActive ? Color.gray.opacity(0.12) : Color.clear, lineWidth: 1)
                            )
                            .id(index)
                            .onTapGesture {
                                updateFocusLine(index: index, scrollProxy: proxy)
                            }
                        }
                        
                        Spacer(minLength: 180)
                    }
                }
                .simultaneousGesture(
                    DragGesture().onChanged { value in
                        // 手指在屏幕滑动时，根据偏移量计算并动态跟进当前焦点行
                        let deltaLines = Int(-value.translation.height / 36.0)
                        let newIndex = min(max(0, activeLineIndex + deltaLines), wrappedLines.count - 1)
                        if newIndex != activeLineIndex {
                            activeLineIndex = newIndex
                            // 实时向眼镜下发行位置同步
                            syncLineToGlasses(lineIndex: newIndex)
                        }
                    }
                )
            }
            
            // MARK: - 底部控制条 (滑块控制每行字数 10~28)
            VStack(spacing: 12) {
                HStack(spacing: 14) {
                    // 首页复位按钮 (>||<)
                    Button(action: {
                        activeLineIndex = 0
                        syncLineToGlasses(lineIndex: 0)
                    }) {
                        Image(systemName: "arrow.left.to.line.compact")
                            .font(.title3)
                            .foregroundColor(.primary)
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
                            // 字数重新排版后重新下发推屏
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
                        triggerPushToGlasses()
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
            scrollProxy.scrollTo(index, anchor: .center)
        }
        syncLineToGlasses(lineIndex: index)
    }
    
    /// 下发行号实时同步到 G2 眼镜
    private func syncLineToGlasses(lineIndex: Int) {
        guard bleManager.isConnected else { return }
        bleManager.sendScrollSync(pageLine: lineIndex)
    }
    
    /// 按当前设置的每行字数重新推屏下发
    private func triggerPushToGlasses() {
        isPushing = true
        bleManager.sendTeleprompterText(script.content, targetWidthChars: Int(widthChars))
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            isPushing = false
        }
    }
}
