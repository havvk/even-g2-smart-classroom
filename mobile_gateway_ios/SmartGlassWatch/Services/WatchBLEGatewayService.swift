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
    @Published var currentTextSnippet: String = "眼镜提词器已准备就绪"
    @Published var isTranscribing: Bool = false
    
    func sendDisplayToggle() {
        isHUDDisplayActive.toggle()
        sendPageControl(action: isHUDDisplayActive ? "WAKE_HUD" : "SLEEP_HUD", source: "WATCH_POWER_TOGGLE")
    }
    
    func sendTouchpadEvent(gesture: String) {
        sendPageControl(action: gesture, source: "WATCH_TOUCHPAD_SIMULATOR")
    }
    
    func sendAIChatTrigger() {
        sendPageControl(action: "TRIGGER_AI_CHAT", source: "WATCH_AI_BUTTON")
    }
    
    func sendTranscribeTrigger() {
        isTranscribing.toggle()
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
        
        NSLog("⌚️ [SmartGlassWatch] Sending gesture: %@ from %@", action, source)
        
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(message, replyHandler: nil) { err in
                NSLog("⚠️ sendMessage error: %@", err.localizedDescription)
            }
        }
        WCSession.default.transferUserInfo(message)
        try? WCSession.default.updateApplicationContext(message)
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
    
    private func handleIncomingMessage(_ data: [String: Any]) {
        DispatchQueue.main.async {
            if let page = data["current_page"] as? Int {
                self.currentPage = page
            }
            if let total = data["total_pages"] as? Int {
                self.totalPages = total
            }
            if let text = data["current_text"] as? String, !text.isEmpty {
                self.currentTextSnippet = text
            }
            if let connected = data["is_connected"] as? Bool {
                self.isServerOnline = connected
            }
        }
    }
}
