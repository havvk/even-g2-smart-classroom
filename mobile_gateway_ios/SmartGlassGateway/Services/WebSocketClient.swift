import Foundation
import Combine

class WebSocketClient: ObservableObject {
    @Published var isConnected = false
    @Published var currentPayload: TeleprompterSyncPayload?
    @Published var serverAddress: String = "ws://192.168.1.100:8000/ws/session/sess_demo"
    
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession = URLSession(configuration: .default)
    
    var onTeleprompterSyncReceived: ((TeleprompterSyncPayload) -> Void)?
    
    func connect(urlString: String) {
        var cleanURLStr = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanURLStr.hasPrefix("http://") {
            cleanURLStr = cleanURLStr.replacingOccurrences(of: "http://", with: "ws://")
        } else if cleanURLStr.hasPrefix("https://") {
            cleanURLStr = cleanURLStr.replacingOccurrences(of: "https://", with: "wss://")
        } else if !cleanURLStr.hasPrefix("ws://") && !cleanURLStr.hasPrefix("wss://") {
            cleanURLStr = "ws://" + cleanURLStr
        }
        guard let url = URL(string: cleanURLStr) else { return }
        serverAddress = cleanURLStr
        webSocketTask = urlSession.webSocketTask(with: url)
        webSocketTask?.resume()
        isConnected = true
        receiveMessage()
    }
    
    func disconnect() {
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        isConnected = false
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
