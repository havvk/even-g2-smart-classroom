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
    
    /// 向 Apple Watch 推送当前 Slide 页码与状态
    func syncStateToWatch(currentPage: Int, totalPages: Int, isServerConnected: Bool) {
        guard WCSession.isSupported(), WCSession.default.isReachable else { return }
        let message: [String: Any] = [
            "type": "STATE_SYNC",
            "current_page": currentPage,
            "total_pages": totalPages,
            "is_connected": isServerConnected
        ]
        WCSession.default.sendMessage(message, replyHandler: nil, completionHandler: nil)
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
    
    /// 接收 Apple Watch 发来的翻页、显示控制与 AI 对话指令
    func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        guard let type = message["type"] as? String, type == "PAGE_CONTROL" else { return }
        let action = message["action"] as? String ?? "NEXT"
        let source = message["source"] as? String ?? "WATCH_TAP"
        
        DispatchQueue.main.async {
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
