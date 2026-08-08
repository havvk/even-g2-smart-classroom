import SwiftUI
import CoreMotion
import WatchKit

struct WatchContentView: View {
    @StateObject private var watchService = WatchBLEGatewayService()
    
    // 界面模式选择：0 = 提词看板, 1 = G2 眼镜触控板替代模式
    @State private var selectedTab: Int = 1
    
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
            if newValue > lastCrownValue + 1.2 {
                triggerTouchpadEvent("SWIPE_DOWN", label: "下翻页 (表冠)")
                lastCrownValue = newValue
            } else if newValue < lastCrownValue - 1.2 {
                triggerTouchpadEvent("SWIPE_UP", label: "上翻页 (表冠)")
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
                
                // 盲操触摸纹路指南符
                VStack(spacing: 12) {
                    HStack(spacing: 16) {
                        Image(systemName: "hand.tap.fill")
                            .font(.system(size: 14))
                        Text("单击：确认/推进")
                            .font(.system(size: 10, weight: .medium))
                    }
                    
                    HStack(spacing: 16) {
                        Image(systemName: "hand.tap")
                            .font(.system(size: 14))
                        Text("双击：唤醒/休眠")
                            .font(.system(size: 10, weight: .medium))
                    }
                    
                    HStack(spacing: 16) {
                        Image(systemName: "arrow.up.and.down")
                            .font(.system(size: 14))
                        Text("滑动：滚屏翻页")
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
                        triggerTouchpadEvent("SINGLE_TAP", label: "单击：推进/确认")
                    }
                )
            )
            .simultaneousGesture(
                // 3. 滑动手势 (Drag Gesture)
                DragGesture(minimumDistance: 15)
                    .onChanged { value in
                        touchLocation = value.location
                        isTouching = true
                    }
                    .onEnded { value in
                        isTouching = false
                        let translation = value.translation
                        if abs(translation.height) > abs(translation.width) {
                            if translation.height < 0 {
                                triggerTouchpadEvent("SWIPE_UP", label: "向上滑动：前翻")
                            } else {
                                triggerTouchpadEvent("SWIPE_DOWN", label: "向下滑动：后翻")
                            }
                        } else {
                            if translation.width < 0 {
                                triggerTouchpadEvent("SWIPE_FORWARD", label: "向前滑动：前翻")
                            } else {
                                triggerTouchpadEvent("SWIPE_BACKWARD", label: "向后滑动：后翻")
                            }
                        }
                    }
            )
        }
        .padding(.horizontal, 4)
    }
    
    // MARK: - 提词看板界面 (Dashboard)
    private var teleprompterDashboardView: some View {
        ScrollView {
            VStack(spacing: 8) {
                // 顶部状态与 HUD 快捷开关
                HStack {
                    Circle()
                        .fill(watchService.isPhoneReachable ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                    Text(watchService.isPhoneReachable ? "已连通" : "待同步")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Button(action: {
                        WKInterfaceDevice.current().play(.click)
                        watchService.sendDisplayToggle()
                    }) {
                        Image(systemName: watchService.isHUDDisplayActive ? "eye.fill" : "eye.slash.fill")
                            .font(.system(size: 10))
                            .padding(4)
                            .background(Color.white.opacity(0.2))
                            .clipShape(Circle())
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                
                // 当前文本预览
                VStack(alignment: .leading, spacing: 4) {
                    Text("PAGE \(watchService.currentPage) / \(watchService.totalPages)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.cyan)
                    
                    Text(watchService.currentTextSnippet)
                        .font(.system(size: 11))
                        .foregroundColor(.white)
                        .lineLimit(2)
                }
                .padding(6)
                .background(Color.white.opacity(0.1))
                .cornerRadius(8)
                
                // 翻页简单按键
                HStack(spacing: 6) {
                    Button(action: {
                        triggerTouchpadEvent("SWIPE_UP", label: "上一页")
                    }) {
                        Text("上一页")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.gray.opacity(0.3))
                            .cornerRadius(8)
                    }
                    .buttonStyle(PlainButtonStyle())
                    
                    Button(action: {
                        triggerTouchpadEvent("SWIPE_DOWN", label: "下一页")
                    }) {
                        Text("下一页")
                            .font(.system(size: 11, weight: .bold))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .frame(height: 40)
            }
            .padding(4)
        }
    }
    
    // MARK: - 触发手势与 Taptic 震动
    private func triggerTouchpadEvent(_ action: String, label: String) {
        lastDetectedGesture = label
        gestureBadgeColor = (action == "DOUBLE_TAP") ? .purple : ((action == "SINGLE_TAP") ? .green : .cyan)
        
        // 发送 Taptic 物理震动反馈
        if action == "DOUBLE_TAP" {
            WKInterfaceDevice.current().play(.directionUp)
        } else if action == "SINGLE_TAP" {
            WKInterfaceDevice.current().play(.click)
        } else {
            WKInterfaceDevice.current().play(.directionDown)
        }
        
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
                triggerTouchpadEvent("SWIPE_DOWN", label: "甩手：后翻页")
            } else if rotRateX < -3.8 && userAccelZ < -1.2 {
                lastFlickTimestamp = now
                triggerTouchpadEvent("SWIPE_UP", label: "甩手：前翻页")
            }
        }
    }
    
    private func stopWristFlickDetection() {
        motionManager.stopDeviceMotionUpdates()
    }
}
