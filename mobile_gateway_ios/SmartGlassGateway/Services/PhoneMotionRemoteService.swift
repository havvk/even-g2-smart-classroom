import Foundation
import CoreMotion
import UIKit
import Combine

/// 手机端体感遥控器服务 (Phone Air Remote Service)
/// 将 iPhone 变为无线体感激光笔/翻页器：
/// - 向左利落挥动：下一页 PPT
/// - 向右利落挥动：上一页 PPT
/// - 向前点头/下甩：提词视口下滚 3 行
/// - 向上仰头/挑动：提词视口上滚 3 行
final class PhoneMotionRemoteService: ObservableObject {
    static let shared = PhoneMotionRemoteService()
    
    // MARK: - 用户控制与状态发布
    @Published var isEnabled: Bool = true
    @Published var lastGestureName: String = "体感待命中"
    @Published var lastGestureTimestamp: Date = Date.distantPast
    
    // 实时姿态指标 (用于界面调试显示)
    @Published var currentRotY: Double = 0.0
    @Published var currentRotX: Double = 0.0
    @Published var maxObservedRotY: Double = 0.0
    @Published var maxObservedRotX: Double = 0.0
    
    // 灵敏度阈值 (rad/s)
    @Published var flickThreshold: Double = 4.2  // 横向挥动翻页阈值 (约 240°/s)
    @Published var pitchThreshold: Double = 3.5  // 纵向挑动滚动阈值 (约 200°/s)
    
    // MARK: - 回调接口
    var onPageNavTriggered: ((_ isNext: Bool) -> Void)?
    var onScrollDeltaTriggered: ((_ delta: Int) -> Void)?
    
    // MARK: - CoreMotion 私有实例
    private let motionManager = CMMotionManager()
    private let motionQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "edu.ncu.smartglass.phonemotion"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInteractive
        return q
    }()
    
    // MARK: - 状态机与回弹抑制 (Return-Stroke Suppression)
    private var lastTriggerDate: Date = Date.distantPast
    
    // 横向 (Y轴自转，左右挥动)
    private var lastActionSignY: Double = 0.0
    private var suppressOppositeYUntil: Date = Date.distantPast
    private var hasSettledY: Bool = true
    
    // 纵向 (X轴俯仰，前后甩动)
    private var lastActionSignX: Double = 0.0
    private var suppressOppositeXUntil: Date = Date.distantPast
    private var hasSettledX: Bool = true
    
    private init() {
        start()
    }
    
    func start() {
        guard motionManager.isDeviceMotionAvailable else {
            DispatchQueue.main.async {
                self.lastGestureName = "❌ 陀螺仪传感器不可用"
            }
            return
        }
        
        motionManager.deviceMotionUpdateInterval = 0.02 // 50Hz 高速实时采样
        motionManager.startDeviceMotionUpdates(to: motionQueue) { [weak self] motion, error in
            guard let self = self, let motion = motion, self.isEnabled else { return }
            self.processMotionFrame(motion)
        }
    }
    
    func stop() {
        motionManager.stopDeviceMotionUpdates()
    }
    
    func toggleEnabled() {
        isEnabled.toggle()
        if isEnabled {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            lastGestureName = "🪄 体感遥控已开启"
        } else {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            lastGestureName = "⚪️ 体感遥控已暂停"
        }
    }
    
    // MARK: - 50Hz 传感器帧核心识别算法
    private func processMotionFrame(_ motion: CMDeviceMotion) {
        let now = Date()
        
        // 提取角速度 (rad/s)
        // 竖屏握持坐标系：
        // rotY: 绕手机纵向长轴自转 (向左挥动/向右挥动)
        // rotX: 绕手机横向短轴翻动 (向前点头甩下/向后挑起)
        let rotY = motion.rotationRate.y
        let rotX = motion.rotationRate.x
        
        let absRotY = abs(rotY)
        let absRotX = abs(rotX)
        
        // 1. 平稳归位检测：角速度降至 0.8 rad/s 以下表示挥动已结束
        if absRotY < 0.8 {
            hasSettledY = true
        }
        if absRotX < 0.8 {
            hasSettledX = true
        }
        
        // 2. 调试指标更新 (限频派发至主线程)
        if absRotY > 1.5 || absRotX > 1.5 {
            DispatchQueue.main.async {
                self.currentRotY = rotY
                self.currentRotX = rotX
                if absRotY > self.maxObservedRotY { self.maxObservedRotY = absRotY }
                if absRotX > self.maxObservedRotX { self.maxObservedRotX = absRotX }
            }
        }
        
        // 3. 全局防抖冷却：触发动作后 0.50 秒内静默
        guard now.timeIntervalSince(lastTriggerDate) > 0.50 else { return }
        
        // MARK: - 判定 A: 横向挥动切页 (优先级最高)
        if absRotY > flickThreshold {
            // 🛡️ 反向回弹锁：若处于刚刚向相反方向挥动后的 0.8 秒归位窗口内，坚决丢弃回手动作！
            if now < suppressOppositeYUntil {
                if (rotY > 0 && lastActionSignY < 0) || (rotY < 0 && lastActionSignY > 0) {
                    return
                }
            }
            
            // 必须已经平稳归位过
            guard hasSettledY else { return }
            
            lastTriggerDate = now
            hasSettledY = false
            suppressOppositeYUntil = now.addingTimeInterval(0.80)
            
            if rotY < -flickThreshold {
                // 手腕内旋/向左自转 -> 下一页 PPT
                lastActionSignY = -1.0
                triggerPageNav(isNext: true, label: "手腕内旋/转动：下一页 (Next)")
                return
            } else if rotY > flickThreshold {
                // 手腕外旋/向右自转 -> 上一页 PPT
                lastActionSignY = +1.0
                triggerPageNav(isNext: false, label: "手腕外旋/转动：上一页 (Prev)")
                return
            }
        }
        
        // MARK: - 判定 B: 纵向甩动滚动视口 (当无大幅横向挥动时判定)
        if absRotX > pitchThreshold && absRotY < (flickThreshold * 0.7) {
            // 检测是否处于自然垂手握持姿态 (手机朝下垂放时 gravity.y > 0.0)
            let isHangingArm = motion.gravity.y > 0.0
            
            if now < suppressOppositeXUntil {
                if (rotX > 0 && lastActionSignX < 0) || (rotX < 0 && lastActionSignX > 0) {
                    return
                }
            }
            
            guard hasSettledX else { return }
            
            lastTriggerDate = now
            hasSettledX = false
            suppressOppositeXUntil = now.addingTimeInterval(0.70)
            
            // 🎯 人体工学自适应：
            // 1. 垂手姿态下 (isHangingArm): 握持手机向下甩动时 rotX < 0，映射为向下滚动 (Scroll Down) 推进讲稿，极度省力
            // 2. 抬手直立下 (!isHangingArm): 握持手机向前低头下甩时 rotX > 0，映射为向下滚动 (Scroll Down)
            if isHangingArm {
                if rotX < -pitchThreshold {
                    // 垂手向下甩动 -> 提词视口下滚 3 行 (顺手推进提词，最省力)
                    lastActionSignX = -1.0
                    triggerScrollDelta(delta: 3, label: "垂手向下甩动：下滚 3 行 (Scroll Down)")
                    return
                } else if rotX > pitchThreshold {
                    // 垂手向上提拉 -> 提词视口上滚 3 行 (回退)
                    lastActionSignX = +1.0
                    triggerScrollDelta(delta: -3, label: "垂手向上挑动：上滚 3 行 (Scroll Up)")
                    return
                }
            } else {
                if rotX > pitchThreshold {
                    // 抬手向前点头下甩 -> 提词视口下滚 3 行 (推进)
                    lastActionSignX = +1.0
                    triggerScrollDelta(delta: 3, label: "向前甩动：下滚 3 行 (Scroll Down)")
                    return
                } else if rotX < -pitchThreshold {
                    // 抬手向上挑动 -> 提词视口上滚 3 行 (回退)
                    lastActionSignX = -1.0
                    triggerScrollDelta(delta: -3, label: "向上挑动：上滚 3 行 (Scroll Up)")
                    return
                }
            }
        }
    }
    
    // MARK: - 触发动作执行与震动反馈
    private func triggerPageNav(isNext: Bool, label: String) {
        DispatchQueue.main.async {
            self.lastGestureName = "🪄 " + label
            self.lastGestureTimestamp = Date()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            self.onPageNavTriggered?(isNext)
        }
    }
    
    private func triggerScrollDelta(delta: Int, label: String) {
        DispatchQueue.main.async {
            self.lastGestureName = "📜 " + label
            self.lastGestureTimestamp = Date()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            self.onScrollDeltaTriggered?(delta)
        }
    }
}
