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
        watchManager.onPageControlTriggered = { [weak bleManager, weak webSocketClient] action, source in
            DispatchQueue.main.async {
                guard let bleManager = bleManager, let webSocketClient = webSocketClient else { return }
                
                NSLog("📱 [iPhone App] Watch 触控/手势收到: %@来自 %@，分流处理", action, source)
                
                // 1. 宏观 Slide 幻灯片翻页 (联动大屏生产级 LectureSessionManager 与激光翻页笔)
                if action == "NEXT_PAGE" || action == "NEXT" || action == "SWIPE_LEFT" {
                    LectureSessionManager.shared.gotoNextSlide()
                } else if action == "PREV_PAGE" || action == "PREV" || action == "SWIPE_RIGHT" {
                    LectureSessionManager.shared.gotoPrevSlide()
                } else {
                    // 2. 微观页内视口平滑滚动 (当前 Slide 超长逐字稿上下滚行)
                    bleManager.handleWatchGesture(action: action, source: source)
                }
                
                // 向 WebSocket 广播 PAGE_CONTROL 兼容旧链路
                webSocketClient.sendPageControl(sessionId: LectureSessionManager.shared.sessionId, action: action, source: source)
                
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
