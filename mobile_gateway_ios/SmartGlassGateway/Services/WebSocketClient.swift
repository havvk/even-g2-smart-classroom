import Foundation
import Combine

class WebSocketClient: ObservableObject {
    @Published var isConnected = false
    @Published var currentPayload: TeleprompterSyncPayload?
    @Published var serverAddress: String = "ws://192.168.1.100:8000/ws/session/sess_demo"
    
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession = URLSession(configuration: .default)
    
    var onTeleprompterSyncReceived: ((TeleprompterSyncPayload) -> Void)?
    
    /// 防弹级 WebSocket URL 正规化解析器
    static func normalizeWebSocketURL(from input: String) -> URL? {
        var raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 强行剥离所有协议头前缀
        raw = raw.replacingOccurrences(of: "ws://", with: "")
                 .replacingOccurrences(of: "wss://", with: "")
                 .replacingOccurrences(of: "http://", with: "")
                 .replacingOccurrences(of: "https://", with: "")
        
        let components = raw.components(separatedBy: "/")
        let hostAndPort = components.first ?? ""
        var pathComponents = Array(components.dropFirst()).filter { !$0.isEmpty }
        
        if pathComponents.isEmpty {
            pathComponents = ["ws", "session", "sess_demo"]
        }
        
        let cleanPath = pathComponents.joined(separator: "/")
        let fullURLStr = "ws://\(hostAndPort)/\(cleanPath)"
        return URL(string: fullURLStr)
    }
    
    func connect(urlString: String) {
        // 关键防护: 建立新连接前强行先断开并销毁旧的鬼魂 Socket 任务，确保全局 100% 独占单链接
        disconnect()
        
        guard let url = WebSocketClient.normalizeWebSocketURL(from: urlString) else {
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
    
    func sendG2TelemetryLog(direction: String, hexBytes: String, description: String) {
        guard isConnected else { return }
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
        let decoder = JSONDecoder()
        if let payload = try? decoder.decode(TeleprompterSyncPayload.self, from: data) {
            DispatchQueue.main.async {
                self.currentPayload = payload
                self.onTeleprompterSyncReceived?(payload)
            }
        }
    }
}
