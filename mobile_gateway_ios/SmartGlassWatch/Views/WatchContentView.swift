import SwiftUI
import CoreMotion
import WatchKit

struct WatchContentView: View {
    @StateObject private var watchService = WatchBLEGatewayService()
    
    // 数字表冠
    @State private var crownValue: Double = 0.0
    @State private var lastCrownValue: Double = 0.0
    
    // CoreMotion 传感器手腕甩动检测
    private let motionManager = CMMotionManager()
    @State private var isWristFlickEnabled: Bool = true
    @State private var lastFlickTimestamp: Date = Date.distantPast
    
    var body: some View {
        VStack(spacing: 6) {
            // Header 状态栏
            HStack {
                Text("P\(String(format: "%02d", watchService.currentPage))/\(String(format: "%02d", watchService.totalPages))")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(.green)
                Spacer()
                Circle()
                    .fill(watchService.isPhoneReachable ? Color.green : Color.red)
                    .frame(width: 7, height: 7)
            }
            .padding(.horizontal, 4)
            
            // 模式指示
            HStack {
                Image(systemName: "hand.tap")
                Text("捏手指 / 甩手翻页")
            }
            .font(.system(size: 10))
            .foregroundColor(.secondary)
            
            // 屏幕翻页按键
            HStack(spacing: 8) {
                Button(action: {
                    triggerPageTurn(action: "PREV", source: "WATCH_TAP")
                }) {
                    VStack {
                        Image(systemName: "chevron.left")
                            .font(.title3)
                        Text("上一页")
                            .font(.system(size: 10))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.gray.opacity(0.3))
                    .cornerRadius(10)
                }
                .buttonStyle(PlainButtonStyle())
                
                Button(action: {
                    triggerPageTurn(action: "NEXT", source: "WATCH_TAP")
                }) {
                    VStack {
                        Image(systemName: "chevron.right")
                            .font(.title3)
                        Text("下一页")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .frame(height: 60)
        }
        .padding(4)
        .focusable(true)
        // 模式 1: 数字表冠旋转
        .digitalCrownRotation($crownValue)
        .onChange(of: crownValue) { newValue in
            if newValue > lastCrownValue + 1.2 {
                triggerPageTurn(action: "NEXT", source: "WATCH_CROWN")
                lastCrownValue = newValue
            } else if newValue < lastCrownValue - 1.2 {
                triggerPageTurn(action: "PREV", source: "WATCH_CROWN")
                lastCrownValue = newValue
            }
        }
        .onAppear {
            startWristFlickDetection()
        }
        .onDisappear {
            stopWristFlickDetection()
        }
    }
    
    // MARK: - 手势触敏与触发封装
    private func triggerPageTurn(action: String, source: String) {
        // Taptic Engine 震动反馈
        WKInterfaceDevice.current().play(.click)
        watchService.sendPageControl(action: action, source: source)
    }
    
    // MARK: - 模式 2 & 3: CoreMotion 手腕甩动 (Wrist Flick Algorithm)
    private func startWristFlickDetection() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 0.02 // 50Hz 采样率
        motionManager.startDeviceMotionUpdates(to: OperationQueue.main) { motion, error in
            guard let motion = motion, isWristFlickEnabled else { return }
            
            // 防抖冷却时间判定 (1.5秒)
            let now = Date()
            guard now.timeIntervalSince(lastFlickTimestamp) > 1.5 else { return }
            
            let rotRateX = motion.rotationRate.x
            let rotRateY = motion.rotationRate.y
            let userAccelZ = motion.userAcceleration.z
            
            // 甩手翻页波形特征比对 (快速向下/向上甩手反弹)
            if rotRateX > 3.8 && userAccelZ > 1.2 {
                lastFlickTimestamp = now
                triggerPageTurn(action: "NEXT", source: "WATCH_WRIST_FLICK")
            } else if rotRateX < -3.8 && userAccelZ < -1.2 {
                lastFlickTimestamp = now
                triggerPageTurn(action: "PREV", source: "WATCH_WRIST_FLICK")
            }
        }
    }
    
    private func stopWristFlickDetection() {
        motionManager.stopDeviceMotionUpdates()
    }
}
