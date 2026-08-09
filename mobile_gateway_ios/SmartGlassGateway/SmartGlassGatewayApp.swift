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
                self.webSocketClient.sendPageControl(sessionId: "sess_demo", action: action, source: "WATCH_POWER_TOGGLE")
            }
        }
        
        // 2. 双指捏合 / 表冠 / 甩手 / 触控板滑动与点击
        watchManager.onPageControlTriggered = { [weak bleManager, weak webSocketClient] action, source in
            DispatchQueue.main.async {
                guard let bleManager = bleManager, let webSocketClient = webSocketClient else { return }
                
                NSLog("📱 [iPhone App] Watch 触控/手势收到: %@来自 %@，下发 BLE 与 WebSocket", action, source)
                bleManager.handleWatchGesture(action: action, source: source)
                
                // 向 WebSocket 广播 PAGE_CONTROL 消息
                webSocketClient.sendPageControl(sessionId: "sess_demo", action: action, source: source)
                
                // 将最新行号/页码与状态同步回 Apple Watch
                let calcPage = (bleManager.currentFocusPageLine / 10) + 1
                let calcTotalPages = max((bleManager.currentTotalLines + 9) / 10, 1)
                watchManager.syncStateToWatch(
                    currentPage: calcPage,
                    totalPages: calcTotalPages,
                    isServerConnected: webSocketClient.isConnected
                )
            }
        }
        
        // 3. AI 对话快捷触发卡片
        watchManager.onAIChatTriggered = {
            DispatchQueue.main.async {
                NSLog("📱 [iPhone App] Watch AI对话触发收到，下发 WebSocket")
                self.bleManager.lastGestureReceived = "WATCH_AI_BUTTON: TRIGGER_AI_CHAT"
                self.bleManager.addLog("🤖 [Watch] 点击 AI 对话按钮")
                self.webSocketClient.sendPageControl(sessionId: "sess_demo", action: "TRIGGER_AI_CHAT", source: "WATCH_AI_BUTTON")
            }
        }
        
        // 4. 实时转录快捷触发卡片
        watchManager.onTranscribeTriggered = {
            DispatchQueue.main.async {
                NSLog("📱 [iPhone App] Watch 实时转录触发收到，下发 WebSocket")
                self.bleManager.lastGestureReceived = "WATCH_TRANSCRIBE_BUTTON: TOGGLE_TRANSCRIBE"
                self.bleManager.addLog("🎤 [Watch] 点击实时转录按钮")
                self.webSocketClient.sendPageControl(sessionId: "sess_demo", action: "TOGGLE_TRANSCRIBE", source: "WATCH_TRANSCRIBE_BUTTON")
            }
        }
    }
}
