import SwiftUI
import CoreMotion
import WatchKit
import HealthKit

struct WatchContentView: View {
    @StateObject private var watchService = WatchBLEGatewayService()
    @ObservedObject private var workoutManager = WatchWorkoutSessionManager.shared
    @ObservedObject private var runtimeManager = WatchRuntimeSessionManager.shared
    
    // 界面模式选择：0 = 提词看板 (默认主控), 1 = G2 眼镜盲操触控板模式
    @State private var selectedTab: Int = 0
    
    // 数字表冠
    @State private var crownValue: Double = 0.0
    @State private var lastCrownValue: Double = 0.0
    @FocusState private var isFocused: Bool
    
    // CoreMotion 传感器手腕甩动检测 (使用专属高优先级后台队列，彻底解放 Watch 主线程)
    private let motionManager = CMMotionManager()
    private let motionQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "edu.ncu.smartglass.motionQueue"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInteractive
        return q
    }()
    @State private var isWristFlickEnabled: Bool = true
    @State private var lastFlickTimestamp: Date = Date.distantPast
    @State private var isGesturePulsing: Bool = false
    
    // 🛡️ 手腕转动状态机（具备反向回弹吸收与寸劲触发算法，单例持久化）
    private let gestureFilter = WristGestureFilter.shared
    
    // 触控板手势反馈动画状态
    @State private var touchLocation: CGPoint? = nil
    @State private var isTouching: Bool = false
    @State private var lastDetectedGesture: String = "等待手势"
    @State private var gestureBadgeColor: Color = .cyan
    @State private var motionDebugText: String = "垂手转腕待命"
    @State private var showDebugSheet: Bool = false
    
    var body: some View {
        VStack(spacing: 4) {
            // MARK: - 模式切换 + 调试入口 (顶部导航栏，释放全部主屏幕空间)
            HStack(spacing: 4) {
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
                
                Button(action: {
                    WKInterfaceDevice.current().play(.click)
                    selectedTab = 1
                }) {
                    Text("触控板")
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
                    showDebugSheet = true
                }) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 11))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.12))
                        .foregroundColor(.gray)
                        .cornerRadius(8)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, 4)
            .padding(.top, 2)
            
            // 主操作画幅：纯粹呈现，100% 释放黄金屏幕空间，绝无多余杂讯
            if selectedTab == 1 {
                // MARK: - 触控板完全替代模式 (Even G2 Touchpad Replacement)
                touchpadSimulatorView
            } else {
                // MARK: - 提词看板与控制模式
                teleprompterDashboardView
            }
        }
        .sheet(isPresented: $showDebugSheet) {
            watchDebugView
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
    }
    
    // MARK: - 专属系统调试与版本状态面板 (完全独立，绝不侵占主界面空间)
    private var watchDebugView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("系统与姿态调试")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.cyan)
                    Spacer()
                    Button("完成") {
                        showDebugSheet = false
                    }
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.green)
                }
                
                Divider()
                
                Group {
                    Text("固件版本: Build 17 (灵敏阈值8·纯净体能保活·即时直通版)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.green)
                    
                    Text("实时姿态: \(motionDebugText)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.yellow)
                    
                    Text("最大实测转速: \(String(format: "%.1f", gestureFilter.maxObservedRx)) rad/s")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.cyan)
                    
                    Text("手机直通: \(watchService.isPhoneReachable ? "🟢 直通畅通(亮屏)" : "🟡 暗屏节电模式")")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white)
                    
                    Text("体能保活: \(workoutManager.sessionStateText)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(workoutManager.isWorkoutActive ? .green : .orange)
                    
                    if !workoutManager.isWorkoutActive {
                        Text("扩展会话: \(runtimeManager.sessionStateText)")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    
                    Text("寸劲阈值: 10.0 rad/s (约 573°/s)")
                        .font(.system(size: 9, weight: .regular))
                        .foregroundColor(.secondary)
                    
                    Text("归位保护: 1.2s 反向回弹物理死锁")
                        .font(.system(size: 9, weight: .regular))
                        .foregroundColor(.secondary)
                    
                    Text("下垂门禁: gx > 0.75 (排除抬手晃动)")
                        .font(.system(size: 9, weight: .regular))
                        .foregroundColor(.secondary)
                }
            }
            .padding(4)
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
    
    private func triggerTouchpadEvent(_ action: String, label: String, postureInfo: [String: Any]? = nil) {
        let now = Date()
        guard now.timeIntervalSince(lastGestureSentTime) >= 0.250 else { return }
        lastGestureSentTime = now
        
        lastDetectedGesture = label
        gestureBadgeColor = (action == "DOUBLE_TAP") ? .purple : ((action == "SINGLE_TAP") ? .green : .cyan)
        
        // 发送 Taptic 物理触觉反馈：
        // ⚠️ 翻页指令 (NEXT_PAGE / PREV_PAGE) 坚决不提前本地盲震，由 ACK 触发纯震动！
        if action == "DOUBLE_TAP" {
            WKInterfaceDevice.current().play(.click)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                WKInterfaceDevice.current().play(.click)
            }
        } else if action != "NEXT_PAGE" && action != "PREV_PAGE" {
            WKInterfaceDevice.current().play(.click)
        }
        
        // 本地瞬时乐观行号预测（Even G2 物理视口为 9 行，最大顶端行严格受限于 totalLines - 9 + 1）
        let maxTopLine = max(watchService.totalLines - 9 + 1, 1)
        if action == "SINGLE_TAP" || action == "CROWN_DOWN" {
            watchService.currentLine = min(watchService.currentLine + 1, maxTopLine)
        } else if action == "SCROLL_DOWN" || action == "SWIPE_UP" {
            watchService.currentLine = min(watchService.currentLine + 3, maxTopLine)
        } else if action == "CROWN_UP" {
            watchService.currentLine = max(watchService.currentLine - 1, 1)
        } else if action == "SCROLL_UP" || action == "SWIPE_DOWN" {
            watchService.currentLine = max(watchService.currentLine - 3, 1)
        }
        watchService.sendPageControl(action: action, source: "WATCH_TOUCHPAD_SIMULATOR", postureInfo: postureInfo)
    }
    
    // MARK: - CoreMotion 仅限手臂自然下垂·手腕自转与回弹吸收 (Hanging Arm Roll & Return-Stroke Rejection)
    private func startWristFlickDetection() {
        guard motionManager.isDeviceMotionAvailable else { return }
        
        // ⚡️ 启用 Watch 授课体能后台会话 (HKWorkoutSession 黄金标准)：确保手臂垂在身侧屏幕熄灭时，进程与传感器依然全速待命，绝不被挂起！
        WatchWorkoutSessionManager.shared.start()
        
        motionManager.deviceMotionUpdateInterval = 0.02
        // ⚡️ 核心架构优化：将 50Hz 传感器更新从主线程移至专属后台队列 motionQueue，杜绝 UI 假死卡顿！
        motionManager.startDeviceMotionUpdates(to: motionQueue) { motion, error in
            guard let motion = motion, isWristFlickEnabled else { return }
            
            let gy = motion.gravity.y
            let gz = motion.gravity.z
            let gx = motion.gravity.x
            let rotRateY = motion.rotationRate.y
            let rotRateX = motion.rotationRate.x
            
            // 🎯【根据实测校准的真实物理轴向与姿态判定】：
            // 1. 垂手姿态：X 轴（小臂长轴）垂直向下，gx > 0.70
            // 2. 桌面平放姿态：小臂水平趴在桌上 (abs(gx) < 0.45)，且表盘朝天 (gz < -0.40) 或微侧 (abs(gy) > 0.40)
            let isHanging = (gx > gestureFilter.hangingThreshold)
            let isDeskResting = (abs(gx) < 0.45 && (gz < -0.40 || abs(gy) > 0.40))
            
            let now = Date()
            
            // 实时感知本地UI反馈：转腕自转角速度落在绕手臂长轴的 rotRateX 上！
            if abs(rotRateX) > 1.2 {
                let tag = isDeskResting ? String(format: "桌面转动: %.1f", rotRateX) : (isHanging ? String(format: "垂手转动: %.1f", rotRateX) : String(format: "空中转动(gx:%.2f)", gx))
                DispatchQueue.main.async { self.motionDebugText = tag }
            } else if now.timeIntervalSince(lastFlickTimestamp) > 1.2 {
                let tag = isDeskResting ? String(format: "桌面就绪(gx:%.2f)", gx) : (isHanging ? String(format: "垂手就绪(gx:%.2f)", gx) : String(format: "抬手表态(gx:%.2f)", gx))
                DispatchQueue.main.async { self.motionDebugText = tag }
            }
            
            // 🔒【经过手势状态机过滤】：包含双门禁校验、动态阈值、以及反向回弹吸收锁
            if let gesture = gestureFilter.evaluate(gx: gx, gy: gy, gz: gz, rotRateX: rotRateX) {
                lastFlickTimestamp = now
                // 📡 不进行本地盲震：数据推向手机，等待手机收到后回传 ACK 播放震动！
                let postureSnapshot: [String: Any] = [
                    "gx": gx,
                    "gy": gy,
                    "gz": gz,
                    "rx": rotRateX,
                    "isDesk": isDeskResting
                ]
                DispatchQueue.main.async {
                    self.motionDebugText = String(format: "✅ 触发 (%.1f)", rotRateX)
                    self.triggerTouchpadEvent(gesture.action, label: gesture.label, postureInfo: postureSnapshot)
                }
            }
        }
    }
    
    private func stopWristFlickDetection() {
        motionManager.stopDeviceMotionUpdates()
        WatchWorkoutSessionManager.shared.stop()
        WatchRuntimeSessionManager.shared.stop()
    }
}

// MARK: - 专门用于小臂自然下垂及桌面平放状态下的手腕自转手势识别与回弹吸收过滤器 (WristGestureFilter)
final class WristGestureFilter {
    static let shared = WristGestureFilter()
    
    // 垂手门禁：gx 需大于 0.70（手臂自然垂于体侧，排除托腮等）
    let hangingThreshold: Double = 0.70
    
    // 🎯 触发阈值：垂手 8.0 rad/s，桌面平放 6.8 rad/s (手臂枕在桌面上轻微转动手腕更省力)
    let hangingTriggerThreshold: Double = 8.0
    let deskTriggerThreshold: Double = 6.8
    
    // 实时记录观测到的最大自转角速度峰值（用于直观校准动作幅度）
    var maxObservedRx: Double = 0.0
    
    // 状态记录（单例持久化，防止 SwiftUI 重绘导致状态重置）
    private var lastTriggerTime: Date = Date.distantPast
    private var lastActionSign: Double = 0.0 // +1.0 表示向外/正向，-1.0 表示向内/反向
    private var suppressOppositeUntil: Date = Date.distantPast
    private var hasSettled: Bool = true
    
    /// 评估传感器帧，支持垂手下垂与桌面平放双姿态，返回触发的动作（"NEXT_PAGE" / "PREV_PAGE" / nil）
    func evaluate(gx: Double, gy: Double, gz: Double, rotRateX: Double) -> (action: String, label: String)? {
        let now = Date()
        let absRx = abs(rotRateX)
        if absRx > maxObservedRx {
            maxObservedRx = absRx
        }
        
        // 1. 归位静止检测：如果角速度小于 0.8 rad/s，说明手腕转动已经平稳
        if absRx < 0.8 {
            hasSettled = true
        }
        
        // 2. 双姿态门禁检查：
        // 姿态 A: 垂手自然下垂 (gx > 0.70)
        // 姿态 B: 桌面平放 (小臂水平 abs(gx) < 0.45，且表盘朝天 gz < -0.40 或微侧向身体 abs(gy) > 0.40)
        let isHanging = (gx > hangingThreshold)
        let isDeskResting = (abs(gx) < 0.45 && (gz < -0.40 || abs(gy) > 0.40))
        
        guard isHanging || isDeskResting else {
            return nil
        }
        
        // 3. 动态触发阈值：桌面平放使用 6.8 rad/s，垂手使用 8.0 rad/s
        let currentThreshold = isDeskResting ? deskTriggerThreshold : hangingTriggerThreshold
        let posturePrefix = isDeskResting ? "桌面转腕" : "垂手转腕"
        
        // 4. 🛡️ 回弹抑制器（Return-Stroke Suppression）：
        // 如果当前处于刚刚触发手势之后的 1.2 秒反向回弹窗口内，且角速度方向与上次相反
        // 这必然是手腕为了恢复到自然姿态而做出的回位归位动作！坚决丢弃！
        if now < suppressOppositeUntil {
            if (rotRateX > 0 && lastActionSign < 0) || (rotRateX < 0 && lastActionSign > 0) {
                return nil
            }
        }
        
        // 5. 同向触发冷却（至少间隔 0.9 秒）
        guard now.timeIntervalSince(lastTriggerTime) > 0.9 else {
            return nil
        }
        
        // 6. 必须经历过平稳归位（或者时间过去较长），防止同一个动作的拖尾震荡重复触发
        guard hasSettled || now.timeIntervalSince(lastTriggerTime) > 1.3 else {
            return nil
        }
        
        // 7. 阈值触发判断
        if rotRateX > currentThreshold {
            lastTriggerTime = now
            lastActionSign = +1.0
            suppressOppositeUntil = now.addingTimeInterval(1.2) // 1.2秒内绝对禁止反向负角速度触发
            hasSettled = false
            return ("NEXT_PAGE", "\(posturePrefix)：下一页")
        } else if rotRateX < -currentThreshold {
            lastTriggerTime = now
            lastActionSign = -1.0
            suppressOppositeUntil = now.addingTimeInterval(1.2) // 1.2秒内绝对禁止正向正角速度触发
            hasSettled = false
            return ("PREV_PAGE", "\(posturePrefix)：上一页")
        }
        
        return nil
    }
}

// MARK: - 手表授课体态后台保活管理 (基于纯净 HKWorkoutSession，实现暗屏垂手 100% 持续全速运行)
final class WatchWorkoutSessionManager: NSObject, ObservableObject, HKWorkoutSessionDelegate {
    static let shared = WatchWorkoutSessionManager()
    
    private let healthStore = HKHealthStore()
    private var workoutSession: HKWorkoutSession?
    
    @Published var sessionStateText: String = "未就绪"
    @Published var isWorkoutActive: Bool = false
    
    private var isStarting = false
    
    func start() {
        guard HKHealthStore.isHealthDataAvailable() else {
            DispatchQueue.main.async {
                self.sessionStateText = "❌ HealthKit 不可用"
            }
            WatchRuntimeSessionManager.shared.start()
            return
        }
        
        guard workoutSession == nil, !isStarting else { return }
        isStarting = true
        
        DispatchQueue.main.async {
            self.sessionStateText = "🟡 启动体能保活..."
            
            let configuration = HKWorkoutConfiguration()
            configuration.activityType = .other // 其他体能活动（用于授课体态监测）
            configuration.locationType = .indoor
            
            do {
                // ⚠️ 关键架构：纯保活运行无需向用户弹窗申请个人健康权限，亦无需 HKLiveWorkoutBuilder，直接开启会话即可！
                let session = try HKWorkoutSession(healthStore: self.healthStore, configuration: configuration)
                session.delegate = self
                self.workoutSession = session
                
                let startDate = Date()
                session.startActivity(with: startDate)
                self.isStarting = false
                self.isWorkoutActive = true
                self.sessionStateText = "🟢 授课保活中 (Running)"
                NSLog("🏃‍♂️ [WatchWorkout] HKWorkoutSession 成功直接进入活跃保活状态，暗屏垂手永不冻结！")
            } catch {
                self.isStarting = false
                self.sessionStateText = "❌ 异常: \(error.localizedDescription)"
                NSLog("❌ [WatchWorkout] 启动 Workout 异常: %@", error.localizedDescription)
                WatchRuntimeSessionManager.shared.start()
            }
        }
    }
    
    func stop() {
        guard let session = workoutSession else { return }
        session.end()
        self.workoutSession = nil
        DispatchQueue.main.async {
            self.isWorkoutActive = false
            self.sessionStateText = "⚪️ 保活已停止"
        }
    }
    
    // MARK: - HKWorkoutSessionDelegate
    func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {
        DispatchQueue.main.async {
            switch toState {
            case .running:
                self.isWorkoutActive = true
                self.sessionStateText = "🟢 授课保活中 (Running)"
                NSLog("🏃‍♂️ [WatchWorkout] WorkoutSession 进入 Running 状态，暗屏垂手全速保持！")
            case .ended, .stopped:
                self.isWorkoutActive = false
                self.sessionStateText = "⚪️ 保活已停止"
            case .paused:
                self.sessionStateText = "🟠 会话已暂停"
            @unknown default:
                break
            }
        }
    }
    
    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        DispatchQueue.main.async {
            self.isWorkoutActive = false
            self.sessionStateText = "⚠️ 保活故障: \(error.localizedDescription)"
            NSLog("⚠️ [WatchWorkout] WorkoutSession 故障: %@", error.localizedDescription)
        }
        self.workoutSession = nil
        WatchRuntimeSessionManager.shared.start()
    }
}

// MARK: - 手表扩展运行时备选保活管理 (Extended Runtime Session Fallback)
final class WatchRuntimeSessionManager: NSObject, ObservableObject, WKExtendedRuntimeSessionDelegate {
    static let shared = WatchRuntimeSessionManager()
    private var session: WKExtendedRuntimeSession?
    @Published var sessionStateText: String = "未就绪"
    private var isStarting = false
    
    func start() {
        guard session == nil || session?.state == .invalid else { return }
        guard !isStarting else { return }
        isStarting = true
        
        DispatchQueue.main.async {
            self.sessionStateText = "🟡 请求扩展会话..."
            let newSession = WKExtendedRuntimeSession()
            newSession.delegate = self
            newSession.start()
            self.session = newSession
            self.isStarting = false
            NSLog("⌚️ [WatchRuntimeSessionManager] 主线程请求启动 ExtendedRuntimeSession")
        }
    }
    
    func stop() {
        session?.invalidate()
        session = nil
        DispatchQueue.main.async {
            self.sessionStateText = "⚪️ 已停止"
        }
        NSLog("⌚️ [WatchRuntimeSessionManager] 停止 ExtendedRuntimeSession")
    }
    
    func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        DispatchQueue.main.async {
            self.sessionStateText = "🟢 正在扩展保活 (Active)"
        }
        NSLog("⌚️ [WatchRuntimeSessionManager] ExtendedRuntimeSession 激活 (State: %ld)", extendedRuntimeSession.state.rawValue)
    }
    
    func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        DispatchQueue.main.async {
            self.sessionStateText = "🟠 扩展会话续期中..."
        }
        NSLog("⚠️ [WatchRuntimeSessionManager] ExtendedRuntimeSession 即将过期")
        session = nil
        start()
    }
    
    func extendedRuntimeSession(_ extendedRuntimeSession: WKExtendedRuntimeSession, didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason, error: Error?) {
        let errDesc = error?.localizedDescription ?? "无详细原因"
        let errCode = (error as NSError?)?.code ?? 0
        DispatchQueue.main.async {
            self.sessionStateText = "⚠️ 扩展失效(\(reason.rawValue)): \(errDesc) [\(errCode)]"
        }
        NSLog("⚠️ [WatchRuntimeSessionManager] ExtendedRuntimeSession 失效 (Reason: %ld, error: %@ [code: %ld])", reason.rawValue, errDesc, errCode)
        session = nil
    }
}
