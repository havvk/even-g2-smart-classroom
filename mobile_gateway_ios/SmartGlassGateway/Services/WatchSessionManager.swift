import Foundation
import WatchConnectivity
import Combine

class WatchSessionManager: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchSessionManager()
    
    @Published var isWatchReachable = false
    @Published var lastWatchGesture = "None"
    
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
    
    func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        processIncomingWatchMessage(message)
    }
    
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
        processIncomingWatchMessage(applicationContext)
    }
    
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String : Any]) {
        processIncomingWatchMessage(userInfo)
    }
    
    /// 统一解调 Apple Watch 发来的翻页、触控板模拟、显示控制与 AI 指令
    private func processIncomingWatchMessage(_ data: [String: Any]) {
        guard let type = data["type"] as? String, type == "PAGE_CONTROL" else { return }
        let action = data["action"] as? String ?? "NEXT"
        let source = data["source"] as? String ?? "WATCH_TAP"
        let timestamp = data["timestamp"] as? Int64 ?? 0
        
        // 🛡️ 防重解调：同一毫秒时间戳的手势消息在 500ms 内绝对只响应一次
        if timestamp > 0 && abs(timestamp - lastProcessedTimestamp) < 500 {
            NSLog("🛡️ [WatchSessionManager] 拦截同源重复手势消息 (timestamp: %lld)", timestamp)
            return
        }
        if timestamp > 0 {
            lastProcessedTimestamp = timestamp
        }
        
        DispatchQueue.main.async {
            NSLog("⌚️ [WatchSessionManager] Received Watch Gesture: %@ from %@", action, source)
            self.lastWatchGesture = "\(source): \(action)"
            
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
