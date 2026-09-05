import Foundation
import WatchConnectivity
import Combine

class WatchSessionManager: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchSessionManager()
    
    @Published var isWatchReachable = false
    @Published var lastWatchGesture = "None"
    
    // ⌚️ 手表姿态实时遥测监控数据 (供手机 APP 实时观察)
    @Published var motionTelemetrySummary: String = "手表姿态待命 (请戴表下垂)"
    @Published var motionGravityY: Double = 0.0
    @Published var motionGravityZ: Double = 0.0
    @Published var motionRotationRateY: Double = 0.0
    @Published var isWatchHangingArm: Bool = false
    @Published var lastMotionTag: String = ""
    
    var onPageControlTriggered: ((String, String) -> Void)? // (action, source)
    
    override init() {
        super.init()
        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()
        }
    }
    
    // MARK: - 手表状态与视口位置高频同步防抖机制
    private var lastWatchSyncTime: Date = Date.distantPast
    private var pendingWatchSyncWorkItem: DispatchWorkItem?
    
    /// 向 Apple Watch 推送当前 Slide 页码、状态、当前行号及视口提词文本
    func syncStateToWatch(
        currentPage: Int,
        totalPages: Int,
        currentLine: Int = 1,
        totalLines: Int = 1,
        currentText: String? = nil,
        fullText: String? = nil,
        isServerConnected: Bool,
        forceImmediate: Bool = false
    ) {
        guard WCSession.isSupported() else { return }
        
        let sendBlock = {
            var message: [String: Any] = [
                "type": "STATE_SYNC",
                "current_page": currentPage,
                "total_pages": totalPages,
                "current_line": currentLine,
                "total_lines": totalLines,
                "is_connected": isServerConnected
            ]
            if let currentText = currentText, !currentText.isEmpty {
                message["current_text"] = currentText
            }
            if let fullText = fullText, !fullText.isEmpty {
                message["full_text"] = fullText
            }
            
            if WCSession.default.isReachable {
                WCSession.default.sendMessage(message, replyHandler: nil) { err in
                    NSLog("⚠️ [WatchSession] syncState sendMessage error: %@", err.localizedDescription)
                }
            } else {
                try? WCSession.default.updateApplicationContext(message)
            }
            self.lastWatchSyncTime = Date()
        }
        
        if forceImmediate {
            pendingWatchSyncWorkItem?.cancel()
            sendBlock()
            return
        }
        
        // 120ms 动态节流，防止滑行过程中高频 sendMessage 引起系统阻塞
        let now = Date()
        if now.timeIntervalSince(lastWatchSyncTime) >= 0.120 {
            pendingWatchSyncWorkItem?.cancel()
            sendBlock()
        } else {
            pendingWatchSyncWorkItem?.cancel()
            let item = DispatchWorkItem {
                sendBlock()
            }
            pendingWatchSyncWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.120, execute: item)
        }
    }
    
    // MARK: - WCSessionDelegate
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            self.isWatchReachable = session.isReachable
        }
    }
    
    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.isWatchReachable = session.isReachable
        }
    }
    
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }
    
    var onDisplayToggleTriggered: ((Bool) -> Void)? // true: wake, false: sleep
    var onAIChatTriggered: (() -> Void)?
    var onTranscribeTriggered: (() -> Void)?
    
    // MARK: - WCSessionDelegate 消息/上下文 3 重可靠接收入口
    private var lastProcessedTimestamp: Int64 = 0
    // 🛡️ 幂等去重缓存：记录最近处理过的消息 msgId，避免手表重试导致的连跳/连翻
    private var processedMsgIds: Set<String> = []
    private var processedMsgIdQueue: [(id: String, time: Date)] = []
    private let msgIdLock = NSLock()
    
    func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        let msgId = message["msgId"] as? String ?? ""
        let action = message["action"] as? String ?? ""
        processIncomingWatchMessage(message)
        sendAckToWatch(msgId: msgId, action: action)
    }
    
    func session(_ session: WCSession, didReceiveMessage message: [String : Any], replyHandler: @escaping ([String : Any]) -> Void) {
        let msgId = message["msgId"] as? String ?? ""
        let action = message["action"] as? String ?? ""
        
        processIncomingWatchMessage(message)
        
        // ⚡️ 收到翻页或手势指令后，立即向 Apple Watch 返回携带 msgId 的同步 ACK 确认回执，驱动手表停止重试并播放物理震动！
        replyHandler([
            "status": "ACK",
            "type": "PAGE_CONTROL_ACK",
            "msgId": msgId,
            "action": action,
            "timestamp": Int64(Date().timeIntervalSince1970 * 1000)
        ])
        
        // 双保险：若手表使用的是单向监听，同时也广播一条 ACK
        if !msgId.isEmpty {
            sendAckToWatch(msgId: msgId, action: action)
        }
    }
    
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
        let msgId = applicationContext["msgId"] as? String ?? ""
        let action = applicationContext["action"] as? String ?? ""
        processIncomingWatchMessage(applicationContext)
        if !msgId.isEmpty || !action.isEmpty {
            sendAckToWatch(msgId: msgId, action: action)
        }
    }
    
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String : Any]) {
        let msgId = userInfo["msgId"] as? String ?? ""
        let action = userInfo["action"] as? String ?? ""
        processIncomingWatchMessage(userInfo)
        sendAckToWatch(msgId: msgId, action: action)
    }
    
    /// 向 Apple Watch 异步推送手势确认回执 (ACK，携带消息流水号 msgId)
    private func sendAckToWatch(msgId: String, action: String) {
        guard WCSession.default.activationState == .activated else { return }
        let ackPayload: [String: Any] = [
            "type": "PAGE_CONTROL_ACK",
            "status": "ACK",
            "msgId": msgId,
            "action": action,
            "timestamp": Int64(Date().timeIntervalSince1970 * 1000)
        ]
        
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(ackPayload, replyHandler: nil) { err in
                NSLog("⚠️ [WatchSessionManager] ACK sendMessage 穿透受阻，降级至 transferUserInfo: %@", err.localizedDescription)
                WCSession.default.transferUserInfo(ackPayload)
            }
        } else {
            WCSession.default.transferUserInfo(ackPayload)
        }
    }
    
    /// 统一解调 Apple Watch 发来的翻页、触控板模拟、显示控制与 AI 指令
    private func processIncomingWatchMessage(_ data: [String: Any]) {
        guard let type = data["type"] as? String else { return }
        
        // 1. 实时手表姿态遥测 (全景三轴展示，彻底消除轴向混淆)
        if type == "MOTION_TELEMETRY" {
            let gx = data["gx"] as? Double ?? 0.0
            let gy = data["gy"] as? Double ?? 0.0
            let gz = data["gz"] as? Double ?? 0.0
            let ry = data["ry"] as? Double ?? 0.0
            let rx = data["rx"] as? Double ?? 0.0
            let isHanging = data["isHanging"] as? Bool ?? false
            let tag = data["tag"] as? String ?? ""
            
            DispatchQueue.main.async {
                self.motionGravityY = gy
                self.motionGravityZ = gz
                self.motionRotationRateY = ry
                self.isWatchHangingArm = isHanging
                self.lastMotionTag = tag
                
                let postureLabel = isHanging ? "✅ 垂手" : "❌ 抬手"
                // 重点展示反映小臂下垂的 gx，以及绕小臂自转的 rx
                self.motionTelemetrySummary = String(
                    format: "%@ gx:%.2f gy:%.2f gz:%.2f | rx:%.1f",
                    postureLabel, gx, gy, gz, rx
                )
            }
            return
        }
        
        guard type == "PAGE_CONTROL" else { return }
        let action = data["action"] as? String ?? "NEXT"
        let source = data["source"] as? String ?? "WATCH_TAP"
        let timestamp = data["timestamp"] as? Int64 ?? 0
        let msgId = data["msgId"] as? String ?? ""
        
        // 🛡️ 严格基于 msgId 的幂等去重（多通道与超时重发自愈保障）：
        if !msgId.isEmpty {
            msgIdLock.lock()
            let alreadyProcessed = processedMsgIds.contains(msgId)
            if !alreadyProcessed {
                processedMsgIds.insert(msgId)
                processedMsgIdQueue.append((id: msgId, time: Date()))
                // 自动淘汰超过 60 秒的历史 msgId 缓存，防止内存膨胀
                let cutoff = Date().addingTimeInterval(-60)
                while let first = processedMsgIdQueue.first, first.time < cutoff {
                    processedMsgIds.remove(first.id)
                    processedMsgIdQueue.removeFirst()
                }
            }
            msgIdLock.unlock()
            
            if alreadyProcessed {
                NSLog("🛡️ [WatchSessionManager] 拦截已执行过的重发指令 (msgId: %@, action: %@)", msgId, action)
                return
            }
        } else {
            // 兼容无 msgId 的旧版逻辑：500ms 内同一时间戳拦截
            if timestamp > 0 && abs(timestamp - lastProcessedTimestamp) < 500 {
                NSLog("🛡️ [WatchSessionManager] 拦截同源重复手势消息 (timestamp: %lld)", timestamp)
                return
            }
            if timestamp > 0 {
                lastProcessedTimestamp = timestamp
            }
        }
        
        DispatchQueue.main.async {
            NSLog("⌚️ [WatchSessionManager] Received Watch Gesture: %@ from %@ (msgId: %@)", action, source, msgId)
            self.lastWatchGesture = "\(source): \(action)"
            
            // 🎯 若手势携带了转腕瞬时姿态，立即更新遥测显示条
            if let gx = data["gx"] as? Double, let rx = data["rx"] as? Double {
                let isDesk = data["isDesk"] as? Bool ?? false
                let postureLabel = isDesk ? "🪑 桌面平放" : ((gx > 0.70) ? "✅ 垂手" : "❌ 抬手")
                self.motionTelemetrySummary = String(
                    format: "🎯 %@ gx:%.2f rx:%.1f | %@",
                    postureLabel, gx, rx, action
                )
                self.lastMotionTag = isDesk ? "桌面转腕" : ((source == "WATCH_TOUCHPAD_SIMULATOR") ? "手腕转动" : source)
                self.isWatchHangingArm = (gx > 0.70) || isDesk
            }
            
            if action == "SLEEP_HUD" {
                self.onDisplayToggleTriggered?(false)
            } else if action == "WAKE_HUD" {
                self.onDisplayToggleTriggered?(true)
            } else if action == "TRIGGER_AI_CHAT" {
                self.onAIChatTriggered?()
            } else if action == "TOGGLE_TRANSCRIBE" {
                self.onTranscribeTriggered?()
            } else {
                self.onPageControlTriggered?(action, source)
            }
        }
    }
}
