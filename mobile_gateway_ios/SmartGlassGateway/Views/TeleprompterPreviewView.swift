import SwiftUI

/// 讲稿预览与控制台视图 (1:1 还原官方界面架构)
struct TeleprompterPreviewView: View {
    @EnvironmentObject var bleManager: BLEManager
    @ObservedObject var storage = ScriptStorage.shared
    @Environment(\.presentationMode) var presentationMode
    
    @State var script: ScriptItem
    @State private var activeLineIndex: Int = 0
    @State private var showingEditor: Bool = false
    @State private var isPushing: Bool = false
    
    // 讲稿切分为自然行
    var scriptLines: [String] {
        let lines = script.content.replacingOccurrences(of: "\\n", with: "\n").components(separatedBy: "\n")
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
                        
                        Text(script.formattedDateString)
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
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(16)
            .padding(.horizontal)
            .padding(.top, 8)
            
            // MARK: - 可视化视口与焦点高亮区 (1:1 模拟 Glasses 成像)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 16) {
                        Spacer(minLength: 120)
                        
                        ForEach(Array(scriptLines.enumerated()), id: \.offset) { index, lineText in
                            let isActive = (index == activeLineIndex)
                            
                            HStack {
                                Text(lineText.isEmpty ? " " : lineText)
                                    .font(.system(size: isActive ? 18 : 15, weight: isActive ? .medium : .regular))
                                    .foregroundColor(isActive ? .primary : .secondary.opacity(0.4))
                                    .multilineTextAlignment(.leading)
                                    .lineSpacing(6)
                                Spacer()
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, isActive ? 16 : 8)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(isActive ? Color(UIColor.systemBackground) : Color.clear)
                                    .shadow(color: isActive ? Color.black.opacity(0.08) : Color.clear, radius: 8, x: 0, y: 4)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(isActive ? Color.gray.opacity(0.15) : Color.clear, lineWidth: 1)
                            )
                            .id(index)
                            .onTapGesture {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                    activeLineIndex = index
                                    proxy.scrollTo(index, anchor: .center)
                                }
                            }
                        }
                        
                        Spacer(minLength: 180)
                    }
                }
                .onChange(of: activeLineIndex) { newIndex in
                    withAnimation {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
            }
            
            // MARK: - 控制条与进度 Handle 滑块
            VStack(spacing: 12) {
                HStack(spacing: 16) {
                    // 首页复位按钮 (>||<)
                    Button(action: {
                        withAnimation {
                            activeLineIndex = 0
                        }
                    }) {
                        Image(systemName: "arrow.left.to.line.compact")
                            .font(.title3)
                            .foregroundColor(.primary)
                    }
                    
                    // 打点进度条 Slider
                    Slider(
                        value: Binding(
                            get: { Double(activeLineIndex) },
                            set: { newValue in activeLineIndex = Int(newValue) }
                        ),
                        in: 0...Double(max(0, scriptLines.count - 1)),
                        step: 1
                    )
                    .accentColor(.purple)
                    
                    // 视口间距 / 边界调节图标 (|-><-|)
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
                        .padding(.vertical, 16)
                        .background(Color(UIColor.secondarySystemBackground))
                        .foregroundColor(.primary)
                        .cornerRadius(14)
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
                        .padding(.vertical, 16)
                        .background(bleManager.isConnected ? Color.black : Color.gray)
                        .foregroundColor(.white)
                        .cornerRadius(14)
                    }
                    .disabled(!bleManager.isConnected || isPushing)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            }
            .padding(.top, 8)
            .background(Color(UIColor.systemBackground).edgesIgnoringSafeArea(.bottom))
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("预览")
                    .font(.headline)
            }
        }
        .sheet(isPresented: $showingEditor) {
            ScriptEditorView(scriptToEdit: script)
        }
    }
    
    private func triggerPushToGlasses() {
        isPushing = true
        bleManager.sendTeleprompterText(script.content, targetWidthChars: 28)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            isPushing = false
        }
    }
}
