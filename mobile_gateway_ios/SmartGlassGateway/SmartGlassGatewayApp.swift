import SwiftUI

@main
struct SmartGlassGatewayApp: App {
    @StateObject private var bleManager = BLEManager()
    @StateObject private var speechEngine = SpeechFollowEngine()
    @StateObject private var webSocketClient = WebSocketClient()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(bleManager)
                .environmentObject(speechEngine)
                .environmentObject(webSocketClient)
                .onAppear {
                    bleManager.setupWebSocketTelemetryBinding(webSocketClient)
                    LectureSessionManager.shared.setup(webSocketClient: webSocketClient, bleManager: bleManager)
                    setupWatchSessionBinding()
                    setupPhoneMotionBinding()
                }
        }
    }
    
    /// 绑定 iPhone 自身陀螺仪体感挥动手势与视口微调
    private func setupPhoneMotionBinding() {
        let motionRemote = PhoneMotionRemoteService.shared
        motionRemote.onPageNavTriggered = { isNext in
            DispatchQueue.main.async {
                if isNext {
                    LectureSessionManager.shared.gotoNextSlide()
                } else {
                    LectureSessionManager.shared.gotoPrevSlide()
                }
            }
        }
        motionRemote.onScrollDeltaTriggered = { delta in
            DispatchQueue.main.async {
                LectureSessionManager.shared.scrollByLineDelta(delta)
            }
        }
    }
    
    /// 绑定 Apple Watch 姿态手势与物理操控消息
    private func setupWatchSessionBinding() {
        let watchManager = WatchSessionManager.shared
        
        // 1. HUD 显存休眠/激活控制 (Eye 按钮)
        watchManager.onDisplayToggleTriggered = { isWake in
            DispatchQueue.main.async {
                let action = isWake ? "WAKE_HUD" : "SLEEP_HUD"
                NSLog("📱 [iPhone App] Watch 显存控制收到: %@，下发 BLE 与 WebSocket", action)
                if isWake {
                    self.bleManager.wakeHUD()
                } else {
                    self.bleManager.sleepHUD()
                }
                self.bleManager.addLog("⌚️ [Watch] 显存控制: \(action)")
                self.webSocketClient.sendPageControl(sessionId: LectureSessionManager.shared.sessionId, action: action, source: "WATCH_POWER_TOGGLE")
            }
        }
        
        // 2. 双指捏合 / 表冠 / 甩手 / 触控板滑动与点击
        watchManager.onPageControlTriggered = { [weak bleManager] action, source in
            DispatchQueue.main.async {
                guard let bleManager = bleManager else { return }
                
                NSLog("📱 [iPhone App] Watch 触控/手势收到: %@来自 %@，100% 统一走 LectureSessionManager", action, source)
                
                // 🌟 100% 对齐界面翻页与滚动的标准调用通道：
                switch action {
                case "NEXT_PAGE", "NEXT", "SWIPE_LEFT":
                    LectureSessionManager.shared.gotoNextSlide()
                case "PREV_PAGE", "PREV", "SWIPE_RIGHT":
                    LectureSessionManager.shared.gotoPrevSlide()
                case "SCROLL_DOWN", "SWIPE_UP":
                    LectureSessionManager.shared.scrollByLineDelta(3)
                case "SCROLL_UP", "SWIPE_DOWN":
                    LectureSessionManager.shared.scrollByLineDelta(-3)
                case "SINGLE_TAP", "CROWN_DOWN":
                    LectureSessionManager.shared.scrollByLineDelta(1)
                case "CROWN_UP":
                    LectureSessionManager.shared.scrollByLineDelta(-1)
                default:
                    bleManager.handleWatchGesture(action: action, source: source)
                }
                
                // 实时同步最新页码与剧本至 Apple Watch
                LectureSessionManager.shared.syncStateToWatch()
            }
        }
        
        // 3. AI 对话快捷触发卡片
        watchManager.onAIChatTriggered = {
            DispatchQueue.main.async {
                NSLog("📱 [iPhone App] Watch AI对话触发收到，下发 WebSocket")
                self.bleManager.lastGestureReceived = "WATCH_AI_BUTTON: TRIGGER_AI_CHAT"
                self.bleManager.addLog("🤖 [Watch] 点击 AI 对话按钮")
                self.webSocketClient.sendPageControl(sessionId: LectureSessionManager.shared.sessionId, action: "TRIGGER_AI_CHAT", source: "WATCH_AI_BUTTON")
            }
        }
        
        // 4. 实时转录快捷触发卡片
        watchManager.onTranscribeTriggered = {
            DispatchQueue.main.async {
                NSLog("📱 [iPhone App] Watch 实时转录触发收到，下发 WebSocket")
                self.bleManager.lastGestureReceived = "WATCH_TRANSCRIBE_BUTTON: TOGGLE_TRANSCRIBE"
                self.bleManager.addLog("🎤 [Watch] 点击实时转录按钮")
                self.webSocketClient.sendPageControl(sessionId: LectureSessionManager.shared.sessionId, action: "TOGGLE_TRANSCRIBE", source: "WATCH_TRANSCRIBE_BUTTON")
            }
        }
    }
}
