import Foundation
import WatchConnectivity
import Combine
import WatchKit

class WatchBLEGatewayService: NSObject, ObservableObject, WCSessionDelegate {
    @Published var isPhoneReachable = false
    @Published var currentPage: Int = 1
    @Published var totalPages: Int = 1
    @Published var isServerOnline: Bool = false
    
    override init() {
        super.init()
        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()
        }
    }
    
    @Published var currentLine: Int = 1
    @Published var totalLines: Int = 1
    @Published var currentFocusLineText: String = ""
    @Published var remainingSnippet: String = ""
    
    @Published var isHUDDisplayActive: Bool = true
    @Published var currentTextSnippet: String = "眼镜提词器已准备就绪"
    @Published var isTranscribing: Bool = false
    
    func sendDisplayToggle() {
        isHUDDisplayActive.toggle()
        sendPageControl(action: isHUDDisplayActive ? "WAKE_HUD" : "SLEEP_HUD", source: "WATCH_POWER_TOGGLE")
    }
    
    func sendTouchpadEvent(gesture: String) {
        // 本地瞬时乐观行号预测（Even G2 物理视口为 9 行，最大顶端行严格受限于 totalLines - 9 + 1，杜绝反向滑动空转死区）
        let maxTopLine = max(self.totalLines - 9 + 1, 1)
        if gesture == "SINGLE_TAP" || gesture == "CROWN_DOWN" {
            self.currentLine = min(self.currentLine + 1, maxTopLine)
        } else if gesture == "SCROLL_DOWN" || gesture == "SWIPE_UP" {
            self.currentLine = min(self.currentLine + 3, maxTopLine)
        } else if gesture == "CROWN_UP" {
            self.currentLine = max(self.currentLine - 1, 1)
        } else if gesture == "SCROLL_UP" || gesture == "SWIPE_DOWN" {
            self.currentLine = max(self.currentLine - 3, 1)
        }
        sendPageControl(action: gesture, source: "WATCH_TOUCHPAD_SIMULATOR")
    }
    
    func sendAIChatTrigger() {
        sendPageControl(action: "TRIGGER_AI_CHAT", source: "WATCH_AI_BUTTON")
    }
    
    func sendTranscribeTrigger() {
        isTranscribing.toggle()
        sendPageControl(action: "TOGGLE_TRANSCRIBE", source: "WATCH_TRANSCRIBE_BUTTON")
    }
    
    // MARK: - 发送翻页与触控指令 (纯物理无声双震，免弹窗直通)
    private var lastPageControlSendTime: Date = Date.distantPast
    private var lastAckHapticTime: Date = Date.distantPast
    
    /// 触发纯物理无声机械双击震动 (绝无“叮叮”系统铃声，300ms 幂等防连震)
    func playSilentHapticFeedback() {
        let now = Date()
        guard now.timeIntervalSince(lastAckHapticTime) >= 0.300 else { return }
        lastAckHapticTime = now
        DispatchQueue.main.async {
            WKInterfaceDevice.current().play(.click)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                WKInterfaceDevice.current().play(.click)
            }
        }
    }
    
    func sendPageControl(action: String, source: String = "WATCH_TAP", postureInfo: [String: Any]? = nil) {
        let now = Date()
        guard now.timeIntervalSince(lastPageControlSendTime) >= 0.250 else { return }
        lastPageControlSendTime = now
        
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        
        let msgId = UUID().uuidString
        var message: [String: Any] = [
            "type": "PAGE_CONTROL",
            "action": action,
            "source": source,
            "msgId": msgId,
            "timestamp": Int64(now.timeIntervalSince1970 * 1000)
        ]
        
        if let posture = postureInfo {
            for (k, v) in posture {
                message[k] = v
            }
        }
        
        NSLog("⌚️ [SmartGlassWatch] 发射指令: %@ (msgId: %@, isReachable: %d)", action, msgId, session.isReachable)
        
        // 核心实时发送逻辑：优先走低延迟 sendMessage
        let attemptSendMessage: () -> Void = { [weak self] in
            session.sendMessage(message, replyHandler: { [weak self] reply in
                NSLog("🎯 [Watch] 手机端即时确认 ACK (msgId: %@)，播放纯物理静音震动！", msgId)
                self?.playSilentHapticFeedback()
            }) { [weak self] err in
                NSLog("⚠️ [Watch] sendMessage 穿透受阻: %@，降级至 updateApplicationContext", err.localizedDescription)
                try? session.updateApplicationContext(message)
            }
        }
        
        if session.isReachable {
            attemptSendMessage()
        } else {
            // 暗屏或连接从休眠唤醒时，立即尝试发送并设置 60ms、150ms 快速短周期唤醒重试
            attemptSendMessage()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.060) {
                if session.isReachable {
                    attemptSendMessage()
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.150) {
                if session.isReachable {
                    attemptSendMessage()
                } else {
                    try? session.updateApplicationContext(message)
                }
            }
        }
    }
    
    // MARK: - WCSessionDelegate
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            self.isPhoneReachable = session.isReachable
        }
    }
    
    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.isPhoneReachable = session.isReachable
        }
    }
    
    func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        handleIncomingMessage(message)
    }
    
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
        handleIncomingMessage(applicationContext)
    }
    
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String : Any]) {
        handleIncomingMessage(userInfo)
    }
    
    private func handleIncomingMessage(_ data: [String: Any]) {
        if data["type"] as? String == "PAGE_CONTROL_ACK" || data["status"] as? String == "ACK" {
            NSLog("🎯 [Watch] 收到手机端异步 ACK 回执，播放纯物理静音震动！")
            playSilentHapticFeedback()
            return
        }
        
        DispatchQueue.main.async {
            if let page = data["current_page"] as? Int {
                self.currentPage = page
            }
            if let total = data["total_pages"] as? Int {
                self.totalPages = total
            }
            if let line = data["current_line"] as? Int {
                self.currentLine = line
            }
            if let totalL = data["total_lines"] as? Int {
                self.totalLines = totalL
            }
            if let text = data["current_text"] as? String, !text.isEmpty {
                self.currentTextSnippet = text
                let lines = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                if let first = lines.first {
                    self.currentFocusLineText = first
                    // 保留后续充足的 8 行文本，填满手表纵向物理屏显
                    self.remainingSnippet = lines.dropFirst().prefix(8).joined(separator: "\n")
                } else {
                    self.currentFocusLineText = text
                    self.remainingSnippet = ""
                }
            }
            if let connected = data["is_connected"] as? Bool {
                self.isServerOnline = connected
            }
        }
    }
}
