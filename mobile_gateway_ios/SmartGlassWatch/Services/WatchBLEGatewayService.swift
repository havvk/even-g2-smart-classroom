import Foundation
import WatchConnectivity
import Combine

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
    
    @Published var isHUDDisplayActive: Bool = true
    
    func sendDisplayToggle() {
        isHUDDisplayActive.toggle()
        sendPageControl(action: isHUDDisplayActive ? "WAKE_HUD" : "SLEEP_HUD", source: "WATCH_POWER_TOGGLE")
    }
    
    func sendAIChatTrigger() {
        sendPageControl(action: "TRIGGER_AI_CHAT", source: "WATCH_AI_BUTTON")
    }
    
    func sendTranscribeTrigger() {
        sendPageControl(action: "TOGGLE_TRANSCRIBE", source: "WATCH_TRANSCRIBE_BUTTON")
    }
    
    func sendPageControl(action: String, source: String = "WATCH_TAP") {
        guard WCSession.isSupported() else { return }
        let message: [String: Any] = [
            "type": "PAGE_CONTROL",
            "action": action,
            "source": source,
            "timestamp": Int64(Date().timeIntervalSince1970)
        ]
        
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(message, replyHandler: nil, completionHandler: nil)
        } else {
            try? WCSession.default.updateApplicationContext(message)
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
        guard let type = message["type"] as? String, type == "STATE_SYNC" else { return }
        DispatchQueue.main.async {
            self.currentPage = message["current_page"] as? Int ?? 1
            self.totalPages = message["total_pages"] as? Int ?? 1
            self.isServerOnline = message["is_connected"] as? Bool ?? false
        }
    }
}
