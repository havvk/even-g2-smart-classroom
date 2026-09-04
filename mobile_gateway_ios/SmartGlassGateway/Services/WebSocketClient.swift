import Foundation
import Combine

class WebSocketClient: ObservableObject {
    @Published var isConnected = false
    @Published var currentPayload: TeleprompterSyncPayload?
    @Published var currentPageIndex: Int = 0
    @Published var serverAddress: String = "wss://syb.ncu.edu.cn/smart-class/ws/session/c81431e6"
    
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession = URLSession(configuration: .default)
    
    var onTeleprompterSyncReceived: ((TeleprompterSyncPayload) -> Void)?
    var onSlidePageChanged: ((Int) -> Void)?
    var onTeleprompterScrollRequested: ((Int) -> Void)?
    var onActiveSessionChanged: ((String) -> Void)?
    
    /// 防弹级 WebSocket URL 正规化解析器 (支持生产前缀 /smart-class 与 ?token= 拼接，自适应 ws/wss)
    static func normalizeWebSocketURL(from input: String, token: String? = nil) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let isSecure = trimmed.lowercased().hasPrefix("https://") || 
                       trimmed.lowercased().hasPrefix("wss://") || 
                       trimmed.contains(".edu.cn") || 
                       trimmed.contains(":443")
        let scheme = isSecure ? "wss" : "ws"
        
        // 拆分可能存在的 query 字符串
        let urlParts = trimmed.components(separatedBy: "?")
        var baseRaw = urlParts.first ?? ""
        let existingQuery = urlParts.count > 1 ? urlParts[1] : ""
        
        // 强行剥离所有协议头前缀
        baseRaw = baseRaw.replacingOccurrences(of: "ws://", with: "")
                         .replacingOccurrences(of: "wss://", with: "")
                         .replacingOccurrences(of: "http://", with: "")
                         .replacingOccurrences(of: "https://", with: "")
        
        let components = baseRaw.components(separatedBy: "/")
        let hostAndPort = components.first ?? ""
        var pathComponents = Array(components.dropFirst()).filter { !$0.isEmpty }
        
        if pathComponents.isEmpty || (pathComponents.count == 1 && pathComponents[0] == "smart-class") {
            pathComponents = ["smart-class", "ws", "session", "c81431e6"]
        }
        
        let cleanPath = pathComponents.joined(separator: "/")
        
        // 组装最终 Query
        var queryItems: [String] = []
        if !existingQuery.isEmpty {
            queryItems.append(existingQuery)
        }
        if let token = token, !token.isEmpty, !existingQuery.contains("token=") {
            queryItems.append("token=\(token)")
        }
        
        let queryString = queryItems.isEmpty ? "" : "?\(queryItems.joined(separator: "&"))"
        let fullURLStr = "\(scheme)://\(hostAndPort)/\(cleanPath)\(queryString)"
        return URL(string: fullURLStr)
    }
    
    func connect(urlString: String, token: String? = AuthService.shared.token) {
        // 关键防护: 建立新连接前强行先断开并销毁旧的鬼魂 Socket 任务，确保全局 100% 独占单链接
        disconnect()
        
        guard let url = WebSocketClient.normalizeWebSocketURL(from: urlString, token: token) else {
            print("❌ 无效的 WebSocket URL 输入: \(urlString)")
            return
        }
        
        serverAddress = url.absoluteString
        print("🔗 正在建立标准 100% 独占 WebSocket 连接: \(serverAddress)")
        webSocketTask = urlSession.webSocketTask(with: url)
        webSocketTask?.resume()
        isConnected = true
        receiveMessage()
        startPingTimer()
    }
    
    func disconnect() {
        stopPingTimer()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        isConnected = false
    }
    
    private var pingTimer: Timer?
    
    private func startPingTimer() {
        DispatchQueue.main.async { [weak self] in
            self?.pingTimer?.invalidate()
            self?.pingTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
                self?.sendPing()
            }
        }
    }
    
    private func stopPingTimer() {
        DispatchQueue.main.async { [weak self] in
            self?.pingTimer?.invalidate()
            self?.pingTimer = nil
        }
    }
    
    private func sendPing() {
        webSocketTask?.sendPing { error in
            if let error = error {
                print("⚠️ WebSocket Ping 心跳感知异常: \(error)")
            }
        }
    }
    
    func sendPageControl(sessionId: String, action: String, source: String) {
        guard isConnected else { return }
        let command = PageControlCommand(
            sessionId: sessionId,
            action: action,
            triggerSource: source,
            targetPage: nil,
            timestamp: Int64(Date().timeIntervalSince1970)
        )
        do {
            let data = try JSONEncoder().encode(command)
            if let jsonString = String(data: data, encoding: .utf8) {
                let message = URLSessionWebSocketTask.Message.string(jsonString)
                webSocketTask?.send(message) { error in
                    if let error = error {
                        print("WebSocket send error: \(error)")
                    }
                }
            }
        } catch {
            print("Encoding error: \(error)")
        }
    }
    
    @Published var isTelemetryBroadcastEnabled: Bool = false
    
    func sendG2TelemetryLog(direction: String, hexBytes: String, description: String) {
        // 避免将高频的底层 BLE 蓝牙字节流与心跳直接广播给智慧课堂大屏与导播台
        guard isConnected && isTelemetryBroadcastEnabled else { return }
        let logDict: [String: Any] = [
            "type": "G2_TELEMETRY_LOG",
            "direction": direction,
            "hex_bytes": hexBytes,
            "description": description,
            "timestamp": Int64(Date().timeIntervalSince1970)
        ]
        if let data = try? JSONSerialization.data(withJSONObject: logDict),
           let jsonString = String(data: data, encoding: .utf8) {
            let message = URLSessionWebSocketTask.Message.string(jsonString)
            webSocketTask?.send(message) { error in
                if let error = error {
                    print("G2 Telemetry log send error: \(error)")
                }
            }
        }
    }
    
    /// 发送极速 WebSocket 原生切页指令 (100% 物理时序保序，天然规避 HTTP 并发乱序与回波回环)
    func sendPageNav(targetPage: Int) {
        guard isConnected else { return }
        let dict: [String: Any] = [
            "type": "PAGE_NAV",
            "target_page": targetPage,
            "sender": "app"
        ]
        if let data = try? JSONSerialization.data(withJSONObject: dict),
           let jsonString = String(data: data, encoding: .utf8) {
            let message = URLSessionWebSocketTask.Message.string(jsonString)
            webSocketTask?.send(message) { error in
                if let error = error {
                    NSLog("❌ [WebSocket] 发送 PAGE_NAV 失败: %@", error.localizedDescription)
                } else {
                    NSLog("🚀 [WebSocket] 极速直发 PAGE_NAV (target_page: %ld)", targetPage)
                }
            }
        }
    }
    
    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                print("WebSocket receive error: \(error)")
                DispatchQueue.main.async { self.isConnected = false }
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleIncomingText(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleIncomingText(text)
                    }
                @unknown default:
                    break
                }
                self.receiveMessage()
            }
        }
    }
    
    private func handleIncomingText(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        
        // 1. 优先解析生产环境标准信令
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let type = json["type"] as? String {
            
            switch type {
            case "STATE_SYNC":
                if let payload = json["payload"] as? [String: Any],
                   let pageIndex = payload["currentPageIndex"] as? Int {
                    DispatchQueue.main.async {
                        self.currentPageIndex = pageIndex
                        self.onSlidePageChanged?(pageIndex)
                    }
                    return
                }
            case "PAGE_NAV":
                if let targetPage = json["target_page"] as? Int {
                    DispatchQueue.main.async {
                        self.currentPageIndex = targetPage
                        self.onSlidePageChanged?(targetPage)
                    }
                    return
                }
            case "TELEPROMPTER_SCROLL", "SCROLL_LINE":
                let direction = (json["direction"] as? String)?.lowercased() ?? "down"
                let delta = json["delta"] as? Int ?? (direction == "up" ? -1 : 1)
                DispatchQueue.main.async {
                    self.onTeleprompterScrollRequested?(delta)
                }
                return
            case "active_session_changed":
                if let activeSid = json["active_session_id"] as? String {
                    DispatchQueue.main.async {
                        self.onActiveSessionChanged?(activeSid)
                    }
                    return
                }
            default:
                break
            }
        }
        
        // 2. 兼容历史 Mock 服务端 TELEPROMPTER_SYNC 消息
        let decoder = JSONDecoder()
        if let payload = try? decoder.decode(TeleprompterSyncPayload.self, from: data) {
            DispatchQueue.main.async {
                self.currentPayload = payload
                self.currentPageIndex = max(0, payload.currentPage - 1)
                self.onTeleprompterSyncReceived?(payload)
                self.onSlidePageChanged?(self.currentPageIndex)
            }
        }
    }
}
