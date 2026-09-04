import SwiftUI
import CoreMotion
import WatchKit

struct WatchContentView: View {
    @StateObject private var watchService = WatchBLEGatewayService()
    
    // 界面模式选择：0 = 提词看板 (默认主控), 1 = G2 眼镜盲操触控板模式
    @State private var selectedTab: Int = 0
    
    // 数字表冠
    @State private var crownValue: Double = 0.0
    @State private var lastCrownValue: Double = 0.0
    @FocusState private var isFocused: Bool
    
    // CoreMotion 传感器手腕甩动检测
    private let motionManager = CMMotionManager()
    @State private var isWristFlickEnabled: Bool = true
    @State private var lastFlickTimestamp: Date = Date.distantPast
    @State private var isGesturePulsing: Bool = false
    
    // 触控板手势反馈动画状态
    @State private var touchLocation: CGPoint? = nil
    @State private var isTouching: Bool = false
    @State private var lastDetectedGesture: String = "等待手势"
    @State private var gestureBadgeColor: Color = .cyan
    
    var body: some View {
        VStack(spacing: 4) {
            // MARK: - 模式切换 (HStack Segment Capsules)
            HStack(spacing: 4) {
                Button(action: {
                    WKInterfaceDevice.current().play(.click)
                    selectedTab = 1
                }) {
                    Text("G2触控板")
                        .font(.system(size: 11, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(selectedTab == 1 ? Color.cyan : Color.white.opacity(0.12))
                        .foregroundColor(selectedTab == 1 ? .black : .white)
                        .cornerRadius(8)
                }
                .buttonStyle(PlainButtonStyle())
                
                Button(action: {
                    WKInterfaceDevice.current().play(.click)
                    selectedTab = 0
                }) {
                    Text("提词看板")
                        .font(.system(size: 11, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(selectedTab == 0 ? Color.cyan : Color.white.opacity(0.12))
                        .foregroundColor(selectedTab == 0 ? .black : .white)
                        .cornerRadius(8)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, 4)
            .padding(.top, 2)
            
            if selectedTab == 1 {
                // MARK: - 触控板完全替代模式 (Even G2 Touchpad Replacement)
                touchpadSimulatorView
            } else {
                // MARK: - 提词看板与控制模式
                teleprompterDashboardView
            }
        }
        .focusable(true)
        .focused($isFocused)
        .digitalCrownRotation($crownValue)
        .onChange(of: crownValue) { newValue in
            if newValue > lastCrownValue + 1.0 {
                triggerTouchpadEvent("CROWN_DOWN", label: "下滚 1 行 (表冠)")
                lastCrownValue = newValue
            } else if newValue < lastCrownValue - 1.0 {
                triggerTouchpadEvent("CROWN_UP", label: "上滚 1 行 (表冠)")
                lastCrownValue = newValue
            }
        }
        .onAppear {
            isFocused = true
            isGesturePulsing = true
            startWristFlickDetection()
        }
        .onDisappear {
            stopWristFlickDetection()
        }
    }
    
    // MARK: - G2 眼镜物理触控板 1:1 替代界面 (Touchpad Simulator)
    private var touchpadSimulatorView: some View {
        VStack(spacing: 6) {
            // 手势状态实时反馈 Badge
            HStack {
                Circle()
                    .fill(gestureBadgeColor)
                    .frame(width: 6, height: 6)
                    .shadow(color: gestureBadgeColor, radius: 3)
                
                Text(lastDetectedGesture)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(gestureBadgeColor)
                
                Spacer()
                
                Text("G2 触控模拟")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.white.opacity(0.08))
            .cornerRadius(6)
            
            // 触控画幅操作区 (Large Interactive Touch Canvas)
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(
                        LinearGradient(colors: [Color(white: 0.15), Color(white: 0.08)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(
                                LinearGradient(colors: [.cyan.opacity(0.6), .purple.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing),
                                lineWidth: 1.5
                            )
                    )
                
                // 盲操触摸纹路指南符 (明确两级操作规范)
                VStack(spacing: 10) {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.left.and.right")
                            .font(.system(size: 12))
                        Text("左右滑：切课件页")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.up.and.down")
                            .font(.system(size: 12))
                        Text("上下滑/表冠：滚行")
                            .font(.system(size: 10, weight: .medium))
                    }
                    
                    HStack(spacing: 12) {
                        Image(systemName: "hand.tap")
                            .font(.system(size: 12))
                        Text("双击：HUD休眠/点亮")
                            .font(.system(size: 10, weight: .medium))
                    }
                }
                .foregroundColor(Color.white.opacity(0.45))
                
                // 手指按压触控涟漪效果 (Touch Ripple)
                if isTouching, let loc = touchLocation {
                    Circle()
                        .fill(Color.cyan.opacity(0.3))
                        .frame(width: 40, height: 40)
                        .position(loc)
                        .animation(.easeOut(duration: 0.2), value: isTouching)
                }
            }
            .contentShape(Rectangle())
            // 单击 / 双击 / 拖拽滑动手势解析
            .gesture(
                ExclusiveGesture(
                    // 1. 双击手势 (Double Tap)
                    TapGesture(count: 2).onEnded {
                        triggerTouchpadEvent("DOUBLE_TAP", label: "双击：显示切换")
                    },
                    // 2. 单击手势 (Single Tap)
                    TapGesture(count: 1).onEnded {
                        triggerTouchpadEvent("SINGLE_TAP", label: "单击：微步推进 1 行")
                    }
                )
            )
            .simultaneousGesture(
                // 3. 滑动手势 (Drag Gesture: 横向切课件，纵向滚视口)
                DragGesture(minimumDistance: 15)
                    .onChanged { value in
                        touchLocation = value.location
                        isTouching = true
                    }
                    .onEnded { value in
                        isTouching = false
                        let translation = value.translation
                        if abs(translation.height) > abs(translation.width) {
                            // 垂直滑动：页内长文本视口滚动
                            if translation.height < 0 {
                                triggerTouchpadEvent("SCROLL_DOWN", label: "上滑：下滚行")
                            } else {
                                triggerTouchpadEvent("SCROLL_UP", label: "下滑：上滚行")
                            }
                        } else {
                            // 水平滑动：幻灯片课件切页
                            if translation.width < 0 {
                                triggerTouchpadEvent("NEXT_PAGE", label: "左滑：切下一页")
                            } else {
                                triggerTouchpadEvent("PREV_PAGE", label: "右滑：切上一页")
                            }
                        }
                    }
            )
        }
        .padding(.horizontal, 4)
    }
    
    // MARK: - 提词看板交互主界面 (取消滚动条，全屏手势卡片控制)
    private var teleprompterDashboardView: some View {
        VStack(spacing: 3) {
            // 顶部状态行 (页码 + 行号进度 + 手势提示 + 显存点亮)
            HStack(spacing: 4) {
                Circle()
                    .fill(watchService.isPhoneReachable ? Color.green : Color.orange)
                    .frame(width: 5, height: 5)
                
                Text("P\(watchService.currentPage)/\(watchService.totalPages)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.cyan)
                
                Text("L\(watchService.currentLine)/\(watchService.totalLines)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.yellow)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(Color.yellow.opacity(0.18))
                    .cornerRadius(3)
                
                Spacer()
                
                Text(lastDetectedGesture)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(gestureBadgeColor)
                    .lineLimit(1)
                
                Button(action: {
                    WKInterfaceDevice.current().play(.click)
                    watchService.sendDisplayToggle()
                }) {
                    Image(systemName: watchService.isHUDDisplayActive ? "eye.fill" : "eye.slash.fill")
                        .font(.system(size: 9))
                        .padding(3)
                        .background(Color.white.opacity(0.18))
                        .clipShape(Circle())
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, 4)
            
            // 提词卡片主手势操作区 (全屏触控，手势直通眼镜与课件)
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        LinearGradient(colors: [Color(white: 0.15), Color(white: 0.08)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(
                                LinearGradient(colors: [.cyan.opacity(0.4), .purple.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing),
                                lineWidth: 1.0
                            )
                    )
                
                // 实时提词正文 (首行焦点与眼镜顶端 100% 对齐 + 满幅后续预览，充分利用纵向屏幕)
                VStack(alignment: .leading, spacing: 4) {
                    if !watchService.currentFocusLineText.isEmpty {
                        // 👓 焦点首行：加粗高亮与青色引导指示，一抬腕瞬间锁定当前句
                        HStack(alignment: .top, spacing: 4) {
                            Circle()
                                .fill(Color.cyan)
                                .frame(width: 4, height: 4)
                                .padding(.top, 4)
                            Text(watchService.currentFocusLineText)
                                .font(.system(size: 11.5, weight: .bold))
                                .foregroundColor(.cyan)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        
                        // ⚪️ 后续待讲提词 (充分利用空间，填满原本空白的 2~3 行)
                        if !watchService.remainingSnippet.isEmpty {
                            Text(watchService.remainingSnippet)
                                .font(.system(size: 10.5, weight: .regular))
                                .foregroundColor(.white.opacity(0.75))
                                .lineSpacing(2)
                                .lineLimit(7)
                        }
                    } else {
                        Text(watchService.currentTextSnippet)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white)
                            .lineSpacing(2)
                            .lineLimit(8)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 7)
                .padding(.vertical, 6)
                
                // 触控涟漪效果
                if isTouching, let loc = touchLocation {
                    Circle()
                        .fill(Color.cyan.opacity(0.3))
                        .frame(width: 32, height: 32)
                        .position(loc)
                }
            }
            .contentShape(Rectangle())
            // 挂载单击/双击手势
            .gesture(
                ExclusiveGesture(
                    TapGesture(count: 2).onEnded {
                        triggerTouchpadEvent("DOUBLE_TAP", label: "双击：显示切换")
                    },
                    TapGesture(count: 1).onEnded {
                        triggerTouchpadEvent("SINGLE_TAP", label: "单击：下推 1 行")
                    }
                )
            )
            .simultaneousGesture(
                // 挂载滑动手势 (横向切课件，纵向高效滚 3 行)
                DragGesture(minimumDistance: 12)
                    .onChanged { value in
                        touchLocation = value.location
                        isTouching = true
                    }
                    .onEnded { value in
                        isTouching = false
                        let translation = value.translation
                        if abs(translation.height) > abs(translation.width) {
                            // 垂直滑动：高效滚 3 行
                            if translation.height < 0 {
                                triggerTouchpadEvent("SCROLL_DOWN", label: "上滑：下滚 3 行")
                            } else {
                                triggerTouchpadEvent("SCROLL_UP", label: "下滑：上滚 3 行")
                            }
                        } else {
                            // 水平滑动：课件 Slide 翻页
                            if translation.width < 0 {
                                triggerTouchpadEvent("NEXT_PAGE", label: "左滑：切下一页")
                            } else {
                                triggerTouchpadEvent("PREV_PAGE", label: "右滑：切上一页")
                            }
                        }
                    }
            )
        }
        .padding(.horizontal, 2)
    }
    
    // MARK: - 触发手势指令并发送给 iPhone (带 250ms 物理防抖节流)
    @State private var lastGestureSentTime: Date = Date.distantPast
    
    private func triggerTouchpadEvent(_ action: String, label: String) {
        let now = Date()
        guard now.timeIntervalSince(lastGestureSentTime) >= 0.250 else { return }
        lastGestureSentTime = now
        
        lastDetectedGesture = label
        gestureBadgeColor = (action == "DOUBLE_TAP") ? .purple : ((action == "SINGLE_TAP") ? .green : .cyan)
        
        // 发送 Taptic 物理触觉反馈 (所有手势均提供与单击一致的清脆振动，完全静音绝无“叮叮”提示音)
        WKInterfaceDevice.current().play(.click)
        
        watchService.sendTouchpadEvent(gesture: action)
    }
    
    // MARK: - CoreMotion 手腕甩动 (Wrist Flick Algorithm)
    private func startWristFlickDetection() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 0.02
        motionManager.startDeviceMotionUpdates(to: OperationQueue.main) { motion, error in
            guard let motion = motion, isWristFlickEnabled else { return }
            
            let now = Date()
            guard now.timeIntervalSince(lastFlickTimestamp) > 1.5 else { return }
            
            let rotRateX = motion.rotationRate.x
            let userAccelZ = motion.userAcceleration.z
            
            if rotRateX > 3.8 && userAccelZ > 1.2 {
                lastFlickTimestamp = now
                triggerTouchpadEvent("NEXT_PAGE", label: "甩手：切下一页")
            } else if rotRateX < -3.8 && userAccelZ < -1.2 {
                lastFlickTimestamp = now
                triggerTouchpadEvent("PREV_PAGE", label: "甩手：切上一页")
            }
        }
    }
    
    private func stopWristFlickDetection() {
        motionManager.stopDeviceMotionUpdates()
    }
}
